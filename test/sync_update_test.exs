defmodule Bonfire.WordPress.SyncUpdateTest do
  @moduledoc """
  A post edited on a WordPress site that was imported here: the site pings Bonfire, and the sync brings the edit in. The site always wins, so an edit made here is overwritten. An export import (or importing again) still leaves an imported post as it is.
  """
  use Bonfire.WordPress.DataCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo

  import Tesla.Mock

  alias Bonfire.WordPress.Posts
  alias Bonfire.WordPress.Sync

  @site "https://www.totnespulse.local"

  setup do
    importer = Bonfire.Me.Fake.fake_user!()

    # the site an earlier import configured, read with Config.get like Ghost's settings
    Process.put([:bonfire_wordpress, :site_url], @site)
    Process.put([:bonfire_wordpress, :auto_import_as], importer.id)

    {:ok, importer: importer}
  end

  defp import!(importer, link, title, html) do
    assert {:ok, %{id: _}} =
             Posts.import_post(
               %{title: title, link: link, published_at: nil, html: html, author: nil},
               current_user: importer
             )
  end

  defp content_of(link) do
    assert {:ok, %{id: id}} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(link)
    Bonfire.Common.Repo.get!(Bonfire.Data.Social.PostContent, id)
  end

  # runs a sync of the site with `posts` as the changed posts its REST API answers
  defp sync_with(posts) do
    mock_global(fn
      %{method: :get, url: "#{@site}/wp-json/wp/v2/posts" <> _} ->
        %Tesla.Env{status: 200, headers: [{"x-wp-totalpages", "1"}], body: Jason.encode!(posts)}

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)

    Sync.ping(@site)

    [job] =
      for job <- all_enqueued(worker: Bonfire.Common.Import),
          job.args["op"] == "wordpress_sync",
          do: job

    assert :ok = perform_job(Bonfire.Common.Import, job.args)
  end

  defp rest_post(id, link, title, html),
    do: %{
      "id" => id,
      "link" => link,
      "date_gmt" => "2026-11-20T10:00:00",
      "modified_gmt" => "2026-11-22T10:00:00",
      "title" => %{"rendered" => title},
      "content" => %{"rendered" => html, "protected" => false}
    }

  test "a post edited on the site gets its new title and body, sanitised", %{importer: importer} do
    link = "#{@site}/edited-on-the-site/"
    import!(importer, link, "Before", "<p>Before</p>")

    sync_with([
      rest_post(1, link, "After", "<p>After the edit</p><script>alert('x')</script>")
    ])

    content = content_of(link)
    assert content.name == "After"
    assert content.html_body =~ "After the edit"
    refute content.html_body =~ "Before"
    refute content.html_body =~ "<script"
  end

  test "an edit made here is overwritten by the site's", %{importer: importer} do
    link = "#{@site}/edited-here-too/"
    import!(importer, link, "From the site", "<p>From the site</p>")

    assert {:ok, _} =
             Bonfire.Social.PostContents.edit(importer, content_of(link).id, %{
               html_body: "<p>A local edit</p>"
             })

    assert content_of(link).html_body =~ "A local edit"

    sync_with([rest_post(2, link, "From the site", "<p>From the site, edited there</p>")])

    content = content_of(link)
    assert content.html_body =~ "From the site, edited there"
    refute content.html_body =~ "A local edit"
  end

  # the sync only fetches posts changed on the site, but one may be changed in a way that leaves its title and body as they are here (eg. only its tags), and editing it again would federate an Update for nothing
  test "a post the site sends unchanged isn't edited again, one it sends changed is",
       %{importer: importer} do
    same = "#{@site}/unchanged/"
    changed = "#{@site}/changed/"
    import!(importer, same, "Unchanged", "<p>Unchanged</p>")
    import!(importer, changed, "Changed", "<p>Changed</p>")

    as_synced = fn link, title, html ->
      Posts.import_post(
        %{title: title, link: link, published_at: nil, html: html, author: nil},
        current_user: importer,
        site: @site,
        update: true
      )
    end

    assert {:ok, :unchanged} = as_synced.(same, "Unchanged", "<p>Unchanged</p>")
    assert {:ok, %{id: _}} = as_synced.(changed, "Changed", "<p>Changed on the site</p>")
    assert content_of(changed).html_body =~ "Changed on the site"
  end

  # the control for the sync path: an export import (or importing the same post again) never touches a post already imported
  test "importing a post already imported leaves it as it is", %{importer: importer} do
    link = "#{@site}/imported-twice/"
    import!(importer, link, "First", "<p>First</p>")

    assert {:ok, :already_imported} =
             Posts.import_post(
               %{
                 title: "Second",
                 link: link,
                 published_at: nil,
                 html: "<p>Second</p>",
                 author: nil
               },
               current_user: importer
             )

    assert content_of(link).name == "First"
  end

  @cover "#{@site}/wp-content/uploads/cover.jpg"
  @new_cover "#{@site}/wp-content/uploads/new-cover.jpg"
  @episode "#{@site}/wp-content/uploads/episode.mp3"
  @new_episode "#{@site}/wp-content/uploads/episode-v2.mp3"

  defp image(url), do: %{url: url, media_type: "image/jpeg", alt: "The cover", primary?: true}
  defp audio(url), do: %{url: url, media_type: "audio/mpeg", alt: nil, primary?: false}

  defp synced_post(link, media, title \\ "With media"),
    do: %{
      title: title,
      link: link,
      published_at: nil,
      html: "<p>With media</p>",
      author: nil,
      media: media
    }

  # the post's media, by where each one is on the site
  defp media_of(link) do
    assert {:ok, %{id: id}} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(link)
    {:ok, post} = Bonfire.Common.Needles.get(id, skip_boundary_check: true)

    post
    |> Bonfire.Common.Repo.preload([files: :media], force: true)
    |> Map.get(:files)
    |> Map.new(&{&1.media.path, &1.media})
  end

  # the site may change a post's featured image or podcast file without touching its text
  test "a new featured image and audio file on the site replace the old ones", %{
    importer: importer
  } do
    link = "#{@site}/new-media/"

    assert {:ok, %{id: _}} =
             Posts.import_post(synced_post(link, [image(@cover), audio(@episode)]),
               current_user: importer
             )

    assert {:ok, _} =
             Posts.import_post(synced_post(link, [image(@new_cover), audio(@new_episode)]),
               current_user: importer,
               site: @site,
               update: true
             )

    media = media_of(link)
    assert Map.keys(media) |> Enum.sort() == Enum.sort([@new_cover, @new_episode])

    assert (media[@new_cover].metadata["primary_image"] ||
              media[@new_cover].metadata[:primary_image]) ==
             true
  end

  # the control for the test above: the same media sent again are kept, not made again
  test "media the site sends unchanged are left as they are", %{importer: importer} do
    link = "#{@site}/same-media/"

    assert {:ok, %{id: _}} =
             Posts.import_post(synced_post(link, [image(@cover), audio(@episode)]),
               current_user: importer
             )

    before = media_of(link) |> Map.new(fn {path, m} -> {path, m.id} end)

    assert {:ok, _} =
             Posts.import_post(
               synced_post(link, [image(@cover), audio(@episode)], "With media, retitled"),
               current_user: importer,
               site: @site,
               update: true
             )

    assert media_of(link) |> Map.new(fn {path, m} -> {path, m.id} end) == before
  end

  # an embedded player's preview is saved under the address its page names as canonical (eg. a video's watch page), not the player's address the post links to. Real-TLD hosts, since link detection ignores `.local` ones (mocked, so nothing leaves the machine)
  @player "https://video.example.com/embed/talk-1"
  @player_page "https://video.example.com/watch/talk-1"
  @other_player "https://video.example.com/embed/talk-2"

  defp with_player(link, player),
    do: %{
      synced_post(link, [image(@cover)])
      | html: ~s(<p>With media</p><iframe src="#{player}" title="A talk"></iframe>)
    }

  # a player's page answers with a preview naming its watch page as canonical, and every request for it is counted
  defp mock_players(requests) do
    mock_global(fn %{url: url} ->
      Agent.update(requests, &[url | &1])

      if String.starts_with?(url, "https://video.example.com/embed/") do
        talk = url |> String.split("/") |> List.last()

        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "text/html"}],
          body: """
          <html><head><title>A talk</title>
          <meta property="og:title" content="A talk">
          <link rel="canonical" href="https://video.example.com/watch/#{talk}">
          </head><body></body></html>
          """
        }
      else
        %Tesla.Env{status: 404, body: ""}
      end
    end)
  end

  defp player_requests(requests, player),
    do: Agent.get(requests, & &1) |> Enum.count(&String.starts_with?(&1, player))

  # the site sends every changed post with all its media, so media sent again as they were must be found as they were: not made again, and the player not fetched again, whatever address its preview is saved under
  test "a post sent unchanged keeps its media, its embedded player included, without fetching it again",
       %{importer: importer} do
    {:ok, requests} = Agent.start_link(fn -> [] end)
    mock_players(requests)

    link = "#{@site}/with-a-player/"

    assert {:ok, %{id: _}} = Posts.import_post(with_player(link, @player), current_user: importer)
    assert player_requests(requests, @player) > 0
    assert Map.has_key?(media_of(link), @player_page)

    before = media_of(link) |> Map.new(fn {path, m} -> {path, m.id} end)
    Agent.update(requests, fn _ -> [] end)

    assert {:ok, _} =
             Posts.import_post(with_player(link, @player),
               current_user: importer,
               site: @site,
               update: true
             )

    assert player_requests(requests, @player) == 0
    assert media_of(link) |> Map.new(fn {path, m} -> {path, m.id} end) == before
  end

  # the control for the test above: a post whose player changed on the site gets the new one
  test "a post whose embedded player changed gets the new one", %{importer: importer} do
    {:ok, requests} = Agent.start_link(fn -> [] end)
    mock_players(requests)

    link = "#{@site}/with-a-new-player/"

    assert {:ok, %{id: _}} = Posts.import_post(with_player(link, @player), current_user: importer)

    assert {:ok, _} =
             Posts.import_post(with_player(link, @other_player),
               current_user: importer,
               site: @site,
               update: true
             )

    media = media_of(link)
    assert Map.has_key?(media, "https://video.example.com/watch/talk-2")
    refute Map.has_key?(media, @player_page)
  end

  describe "into the configured group" do
    setup %{importer: importer} do
      group =
        Bonfire.Classify.Simulate.fake_group!(importer, %{
          membership: "local:members",
          visibility: "nonfederated",
          participation: "anyone"
        })

      Process.put([:bonfire_wordpress, :post_into_group], group.id)

      {:ok, group: group}
    end

    # as Ghost's sync does: an edit there also places the post where its categories now say, finding topics only
    test "a post given a category on the site goes into that category's topic", %{
      importer: importer,
      group: group
    } do
      news =
        Bonfire.Classify.Simulate.fake_category!(importer, group, %{type: :topic, name: "News"})

      link = "#{@site}/given-a-category/"

      import!(importer, link, "Uncategorised", "<p>Uncategorised</p>")

      sync_with([
        rest_post(3, link, "Now in News", "<p>Now in News</p>")
        |> Map.put("categories", [1])
        |> Map.put("_embedded", %{
          "wp:term" => [[%{"name" => "News", "slug" => "news", "taxonomy" => "category"}], []]
        })
      ])

      assert {:ok, %{id: id}} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(link)
      {:ok, post} = Bonfire.Common.Needles.get(id, skip_boundary_check: true)

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: news,
               current_user: importer
             )
    end
  end
end
