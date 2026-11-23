defmodule Bonfire.WordPress.Import.WXRImportTest do
  @moduledoc """
  Importing a WordPress export's posts: each published post (a podcast episode too) becomes a post by its author's user here, with its body as the site shows it (from the site's REST API), dated when it was published there, and linked to where it came from.
  """
  use Bonfire.WordPress.DataCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo
  import Swoosh.TestAssertions
  import Bonfire.Me.Fake
  alias Bonfire.Common.Repo

  alias Bonfire.Common.Import
  alias Bonfire.Common.DatesTimes
  alias Bonfire.WordPress.Import.WXR

  # a public subset of a real export (host and emails rewritten), and the site's REST answers for its posts
  @fixture Path.expand("../fixtures/totnespulse_subset.xml", __DIR__)
  @rest Path.expand("../fixtures/totnespulse_subset_rest.json", __DIR__)

  # the published posts and podcast episode in the fixture, as the export has them
  @posts [
    %{
      id: 3060,
      title: "Totnes Town Council Flies in the Face of Best Practice",
      link: "https://www.totnespulse.local/s-h-d-c-flies-in-the-face-of-best-practice/",
      email: "john-anderson@totnespulse.local",
      date: ~U[2018-12-18 10:39:28Z]
    },
    %{
      id: 3264,
      title: "Totnes Gives You XXtra",
      link: "https://www.totnespulse.local/totnes-gives-you-xxtra/",
      email: "the-totnes-pulse@totnespulse.local",
      date: ~U[2019-01-19 11:32:00Z]
    },
    %{
      id: 16404,
      title: "Totnes Talks - Finlay Porter",
      link: "https://www.totnespulse.local/podcast/totnes-talks-finlay-porter/",
      email: "tony-gee@totnespulse.local",
      date: ~U[2024-11-21 11:17:41Z]
    },
    # no author in the export (their account was deleted on the site), so it comes in as the importing person's
    %{
      id: 27531,
      title: "Totnes Market Square: From major renovation to patch repairs",
      link:
        "https://www.totnespulse.local/totnes-market-square-from-major-renovation-to-patch-repairs/",
      email: nil,
      date: ~U[2025-09-26 08:31:00Z]
    }
  ]

  setup do
    rest = @rest |> File.read!() |> Jason.decode!()
    {:ok, requests} = Agent.start_link(fn -> [] end)
    {:ok, media_requests} = Agent.start_link(fn -> [] end)

    Tesla.Mock.mock_global(fn
      %{method: method, url: url} ->
        cond do
          # a media file on the site: never downloaded, since the media stays where it is
          String.contains?(url, "/wp-content/uploads/") ->
            Agent.update(media_requests, &[{method, url} | &1])
            %Tesla.Env{status: 404, body: ""}

          method == :get ->
            case Regex.run(
                   ~r{^https://www\.totnespulse\.local/wp-json/wp/v2/(posts|podcast)\b},
                   url
                 ) do
              [_, type] ->
                Agent.update(requests, &[type | &1])
                Tesla.Mock.json(rest[type] |> with_script() |> with_embed())

              _ ->
                %Tesla.Env{status: 404, body: ""}
            end

          true ->
            %Tesla.Env{status: 404, body: ""}
        end
    end)

    {:ok, me: fake_user!(), requests: requests, media_requests: media_requests}
  end

  # a site's HTML can't be trusted: one body carries a script, which must not come in
  defp with_script(items),
    do:
      Enum.map(items, fn
        %{"id" => 27531} = item ->
          update_in(item, ["content", "rendered"], &(&1 <> "<script>alert('x')</script>"))

        item ->
          item
      end)

  # an embedded player, as a site's `[embed]` or embed block renders it
  @embed "https://www.youtube-nocookie.com/embed/abc123"
  @embed_post 3264

  defp with_embed(items),
    do:
      Enum.map(items, fn
        %{"id" => @embed_post} = item ->
          update_in(
            item,
            ["content", "rendered"],
            &(&1 <> ~s(<iframe src="#{@embed}" title="A talk" width="560" height="315"></iframe>))
          )

        item ->
          item
      end)

  # a post's attachments, each a `files` row with its media (the post is an Article or a Post, so it's loaded by its pointer)
  defp media_of(id) do
    assert {:ok, post} = Bonfire.Common.Needles.get(id, skip_boundary_check: true)

    post
    |> Repo.preload([files: :media], force: true)
    |> Map.get(:files)
    |> Enum.map(& &1.media)
  end

  # media metadata is stored as JSON, so read back with string keys
  defp primary_image?(%{metadata: metadata}) when is_map(metadata),
    do: (metadata["primary_image"] || metadata[:primary_image]) == true

  defp primary_image?(_), do: false

  defp import_posts(me, opts \\ []) do
    assert {:ok, staged} = WXR.stage(@fixture)
    on_exit(fn -> File.rm_rf(staged.dir) end)

    assert {:ok, report} = Import.import_staged(me, staged, [only: [:posts]] ++ opts)

    # the queued jobs, run here (tests queue them without running them, unless federating)
    for job <- all_enqueued(worker: Import), job.args["op"] == "wordpress_import" do
      assert {:ok, _} = Import.perform(job)
    end

    report
  end

  defp imported(link) do
    assert {:ok, %{id: id}} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(link)

    %{
      id: id,
      content: Repo.get!(Bonfire.Data.Social.PostContent, id),
      creator_id: Repo.get!(Bonfire.Data.Social.Created, id).creator_id
    }
  end

  test "each published post becomes a post with its title, and its body as the site shows it",
       %{me: me} do
    assert %{posts: %{ok: 4}} = import_posts(me)

    for %{link: link, title: title} <- @posts do
      %{content: content} = imported(link)
      assert content.name == title
      assert is_binary(content.html_body) and content.html_body != ""
      refute content.html_body =~ "<script"
    end

    assert imported(Enum.find(@posts, &(&1.id == 27531)).link).content.html_body =~
             "Totnes Market Square (aka Civic Square)"
  end

  test "each post is dated when it was published on the site", %{me: me} do
    import_posts(me)

    for %{link: link, date: date} <- @posts do
      %{id: id} = imported(link)
      assert DateTime.compare(DatesTimes.to_date_time(%{id: id}), date) == :eq
    end
  end

  test "by default every post is the importer's, and no accounts are made for the site's authors",
       %{me: me} do
    import_posts(me)

    for %{link: link, email: email} <- @posts do
      assert imported(link).creator_id == me.id
      if email, do: refute(Bonfire.Me.Accounts.get_by_email(email))
    end
  end

  test "an instance admin asking for a user for each author gets each author's posts by a user of their own, and a post with no author is theirs" do
    me = Bonfire.UI.Common.Testing.Helpers.fake_admin!()
    import_posts(me, create_author_users: true)

    creators =
      for %{link: link, email: email} <- @posts, email do
        assert %{} = account = Bonfire.Me.Accounts.get_by_email(email)
        assert [%{id: user_id}] = Bonfire.Me.Users.by_account!(account)
        assert imported(link).creator_id == user_id
        user_id
      end

    assert length(Enum.uniq(creators)) == 3
    assert imported(Enum.find(@posts, &is_nil(&1.email)).link).creator_id == me.id

    # the authors' new accounts are made quietly, for them to claim later
    assert_no_email_sent()
  end

  # an iframe can't come in (the sanitiser drops it), so the player is kept as a link in the body and as a link attached to the post, which shows as a preview or player here
  test "an embedded player becomes a link in the body and a link attached to the post",
       %{me: me} do
    import_posts(me)

    %{id: id, content: content} = imported(Enum.find(@posts, &(&1.id == @embed_post)).link)

    refute content.html_body =~ "<iframe"
    assert content.html_body =~ ~s(href="#{@embed}")
    assert content.html_body =~ "A talk"
    assert @embed in Enum.map(media_of(id), & &1.path)
  end

  # posts counted by title, since a duplicate would share its link with the first
  defp count_posts_titled(titles),
    do:
      Repo.aggregate(
        from(pc in Bonfire.Data.Social.PostContent, where: pc.name in ^titles),
        :count
      )

  test "importing the same export again leaves one post for each, and says they were already imported",
       %{me: me} do
    first = import_posts(me)
    refute Enum.any?(List.wrap(first[:skipped]), &(&1.reason =~ "already imported"))

    second = import_posts(me)

    assert count_posts_titled(Enum.map(@posts, & &1.title)) == 4
    assert Enum.any?(second.skipped, &(&1.reason =~ "4 already imported"))
  end

  # the hand-written items at the end of the fixture: what an export holds that must not come in
  @not_imported [
    "A draft that was never published",
    "A post that was deleted",
    "Open mic night",
    "A members-only post",
    "Order &ndash; September 4, 2025 @ 10:00 AM"
  ]

  test "drafts, deleted posts, other kinds of items and posts behind a password create nothing, and the report counts them",
       %{me: me} do
    report = import_posts(me)

    assert count_posts_titled(@not_imported) == 0

    # an order's note (a comment on a shop order) comes in as nothing either
    assert Repo.aggregate(
             from(pc in Bonfire.Data.Social.PostContent,
               where: like(pc.html_body, "%Order status changed%")
             ),
             :count
           ) == 0

    for {label, count} <- [
          {"Drafts", 1},
          {"Deleted posts", 1},
          {"Password-protected posts", 1},
          {"ajde_events", 1},
          {"shop_order", 1}
        ] do
      assert Enum.any?(report.skipped, &(&1.key == label and &1.reason =~ "skipping #{count}")),
             "expected a report line for #{label}, got #{inspect(report.skipped)}"
    end
  end

  test "the bodies come from the site's API in one request per kind of post",
       %{me: me, requests: requests} do
    import_posts(me)

    assert Enum.sort(Agent.get(requests, & &1)) == ["podcast", "posts"]
  end

  # by default the media stays on the site: each is attached as a link to its file there, nothing is downloaded
  test "a post's featured image is attached as its primary image, at its address on the site, with its alt text",
       %{me: me, media_requests: media_requests} do
    import_posts(me)

    %{id: id} = imported(Enum.find(@posts, &(&1.id == 3060)).link)

    image =
      Enum.find(
        media_of(id),
        &(&1.path == "https://www.totnespulse.local/wp-content/uploads/2018/12/Untitled-2.png")
      )

    assert image, "expected the featured image attached, got #{inspect(Enum.map(media_of(id), & &1.path))}"
    assert primary_image?(image)
    assert Bonfire.Files.Media.media_alt(image, false) == "Latest plans for the Totnes Market Square"

    assert Agent.get(media_requests, & &1) == []
  end

  test "a podcast episode has its audio attached, at its address on the site",
       %{me: me, media_requests: media_requests} do
    import_posts(me)

    %{id: id} = imported(Enum.find(@posts, &(&1.id == 16404)).link)

    audio =
      Enum.find(
        media_of(id),
        &(&1.path ==
            "https://www.totnespulse.local/wp-content/uploads/2024/11/Tony-Gee-Finley-Porter-Mix.mp3")
      )

    assert audio, "expected the episode's audio attached, got #{inspect(Enum.map(media_of(id), & &1.path))}"
    assert audio.media_type =~ "audio"

    # and its cover image as the primary image
    assert Enum.any?(
             media_of(id),
             &(&1.path ==
                 "https://www.totnespulse.local/wp-content/uploads/2024/11/Finlay-Porter-Talks.jpg" and
                 primary_image?(&1))
           )

    assert Agent.get(media_requests, & &1) == []
  end

  # the site is down or its API blocked: each post still comes in, with the body the export holds (as stored, so block comments go and shortcodes stay as text), and the failed request isn't repeated for every post of its chunk
  test "when the site's API can't be reached, posts come in with the export's own body",
       %{me: me} do
    {:ok, api_requests} = Agent.start_link(fn -> [] end)

    Tesla.Mock.mock_global(fn %{url: url} ->
      if String.contains?(url, "/wp-json/"), do: Agent.update(api_requests, &[url | &1])
      %Tesla.Env{status: 500, body: ""}
    end)

    assert %{posts: %{ok: 4}} = import_posts(me)

    for %{link: link} <- @posts do
      body = imported(link).content.html_body
      assert is_binary(body) and body != ""
      refute body =~ "<!-- wp:"
    end

    assert imported(Enum.find(@posts, &(&1.id == 3060)).link).content.html_body =~
             "interesting sense of timing"

    assert imported(Enum.find(@posts, &(&1.id == 27531)).link).content.html_body =~ "[caption"

    # one request per chunk (posts, podcast), not one per post
    assert length(Agent.get(api_requests, & &1)) == 2
  end
end
