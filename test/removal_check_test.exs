defmodule Bonfire.WordPress.RemovalCheckTest do
  @moduledoc """
  A post unpublished or deleted on a WordPress site sends no ping, so a scheduled check lists the site's published posts and hides the imported posts it no longer has, as Ghost does when an article is unpublished or deleted: out of the feeds, kept with its replies, and back when the site publishes it again.
  """
  use Bonfire.WordPress.DataCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo

  import Tesla.Mock

  alias Bonfire.Social.FeedLoader
  alias Bonfire.WordPress.Posts
  alias Bonfire.WordPress.RemovalCheck

  @site "https://www.totnespulse.local"
  @op "wordpress_removal_check"

  setup do
    importer = Bonfire.Me.Fake.fake_user!()
    viewer = Bonfire.Me.Fake.fake_user!()

    # a check stores when it ran as an instance setting, which also goes into the app's config and outlives each test's database rollback
    Bonfire.Common.Settings.put([:bonfire_wordpress, :last_removal_check], nil,
      scope: :instance,
      skip_boundary_check: true
    )

    # the site an earlier import configured, read with Config.get like Ghost's settings
    Process.put([:bonfire_wordpress, :site_url], @site)
    Process.put([:bonfire_wordpress, :auto_import_as], importer.id)

    {:ok, importer: importer, viewer: viewer}
  end

  defp import!(importer, link) do
    assert {:ok, %{id: _} = post} =
             Posts.import_post(
               %{
                 title: "A post",
                 link: link,
                 published_at: nil,
                 html: "<p>A post</p>",
                 author: nil
               },
               current_user: importer
             )

    post
  end

  # the site's published posts, as its REST API lists them, or what it answers instead
  defp mock_listing(answer) do
    mock_global(fn
      %{method: :get, url: "#{@site}/wp-json/wp/v2/posts" <> _} ->
        case answer do
          links when is_list(links) ->
            %Tesla.Env{
              status: 200,
              headers: [{"x-wp-totalpages", "1"}],
              body:
                links
                |> Enum.with_index(1)
                |> Enum.map(fn {link, id} -> %{"id" => id, "link" => link} end)
                |> Jason.encode!()
            }

          status ->
            %Tesla.Env{status: status, body: ""}
        end

      # a site without the podcast plugin has no such route
      _ ->
        %Tesla.Env{status: 404, body: ~s({"code":"rest_no_route"})}
    end)
  end

  defp check!(importer) do
    assert :ok =
             perform_job(Bonfire.Common.Import, %{
               "op" => @op,
               "user_id" => importer.id,
               "identifier" => @site
             })
  end

  defp visible?(post, viewer), do: FeedLoader.feed_contains?(:local, post, viewer)

  defp still_there?(post),
    do:
      match?(
        {:ok, _},
        Bonfire.Posts.read(post.id,
          skip_boundary_check: true,
          schema: Bonfire.Common.Types.object_type(post)
        )
      )

  test "a post gone from the site is hidden but kept; one still there, or from another site, is left as it is",
       %{importer: importer, viewer: viewer} do
    gone = import!(importer, "#{@site}/gone/")
    kept = import!(importer, "#{@site}/still-there/")
    elsewhere = import!(importer, "https://another-blog.local/not-this-site/")

    assert visible?(gone, viewer)

    mock_listing(["#{@site}/still-there/"])
    check!(importer)

    refute visible?(gone, viewer)
    assert still_there?(gone)
    assert visible?(kept, viewer)
    assert visible?(elsewhere, viewer)
  end

  test "a post the site publishes again comes back with the next sync", %{
    importer: importer,
    viewer: viewer
  } do
    link = "#{@site}/back-again/"
    post = import!(importer, link)

    mock_listing(["#{@site}/some-other-post/"])
    check!(importer)
    refute visible?(post, viewer)

    # republished on the site, so it pings and the sync brings the post in again
    assert {:ok, _} =
             Posts.import_post(
               %{
                 title: "A post",
                 link: link,
                 published_at: nil,
                 html: "<p>A post</p>",
                 author: nil
               },
               current_user: importer,
               site: @site,
               update: true
             )

    assert visible?(post, viewer)
  end

  # a site that's down, or answers with nothing, must not make every imported post disappear
  test "when the site's list of posts can't be had, nothing is hidden", %{
    importer: importer,
    viewer: viewer
  } do
    post = import!(importer, "#{@site}/during-an-outage/")

    mock_listing(500)
    check!(importer)
    assert visible?(post, viewer)

    mock_listing([])
    check!(importer)
    assert visible?(post, viewer)
  end

  describe "scheduling" do
    defp queued_checks,
      do: for(job <- all_enqueued(worker: Bonfire.Common.Import), job.args["op"] == @op, do: job)

    test "the check is queued when it's due, by the configured interval", %{importer: importer} do
      # never checked: due
      assert :ok = perform_job(RemovalCheck, %{})
      assert [%{args: %{"identifier" => @site, "user_id" => user_id}}] = queued_checks()
      assert user_id == importer.id

      # checked an hour ago, with the default of once a day: not due
      Process.put(
        [:bonfire_wordpress, :last_removal_check],
        DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.to_iso8601()
      )

      Bonfire.Common.Repo.delete_all(Oban.Job)
      assert :ok = perform_job(RemovalCheck, %{})
      assert [] = queued_checks()

      # the same, with the interval configured shorter than an hour: due
      Process.put([:bonfire_wordpress, :removal_check_every], to_timeout(minute: 30))
      assert :ok = perform_job(RemovalCheck, %{})
      assert [_] = queued_checks()
    end

    test "the check runs from Oban's cron, more often than any interval it can be set to" do
      crontab =
        Application.get_env(:bonfire, Oban)[:plugins]
        |> List.wrap()
        |> Enum.find_value(fn
          {Oban.Plugins.Cron, opts} -> opts[:crontab]
          _ -> nil
        end)

      assert Enum.any?(List.wrap(crontab), &match?({_, RemovalCheck, _}, &1))
    end
  end
end
