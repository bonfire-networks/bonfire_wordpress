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
    {fixture, opts} = Keyword.pop(opts, :fixture, @fixture)
    assert {:ok, staged} = WXR.stage(fixture)
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

  # the site's REST API names authors by id, not email, so the import records which user each author id became, for a sync to find
  test "an import that makes users for the site's authors records which user each author id is, once" do
    me = Bonfire.UI.Common.Testing.Helpers.fake_admin!()
    import_posts(me, create_author_users: true)

    # the authors of the imported posts, by their id in the export
    for {author_id, email} <- [
          {"16", "john-anderson@totnespulse.local"},
          {"11", "the-totnes-pulse@totnespulse.local"},
          {"104", "tony-gee@totnespulse.local"}
        ] do
      [%{id: user_id}] = Bonfire.Me.Users.by_account!(Bonfire.Me.Accounts.get_by_email(email))

      assert %{id: ^user_id} =
               Bonfire.WordPress.Identities.user_for("https://www.totnespulse.local", author_id)
    end

    # importing again records nothing more
    import_posts(me, create_author_users: true)

    assert Repo.aggregate(Bonfire.WordPress.Identities.AuthorIdentity, :count) == 3
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

    assert image,
           "expected the featured image attached, got #{inspect(Enum.map(media_of(id), & &1.path))}"

    assert primary_image?(image)

    assert Bonfire.Files.Media.media_alt(image, false) ==
             "Latest plans for the Totnes Market Square"

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

    assert audio,
           "expected the episode's audio attached, got #{inspect(Enum.map(media_of(id), & &1.path))}"

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

  describe "into a group" do
    # the categories of the fixture's posts, by post: 27531 is in four, 3264 in three, 3060 in two, and the podcast episode in none
    @topic_names ["News", "People", "Perspectives", "Pulse", "Totnes Town"]

    setup do
      admin = Bonfire.UI.Common.Testing.Helpers.fake_admin!()
      creator = fake_user!()

      group =
        Bonfire.Classify.Simulate.fake_group!(creator, %{
          membership: "local:members",
          visibility: "nonfederated",
          participation: "anyone"
        })

      {:ok, admin: admin, creator: creator, group: group}
    end

    defp topics_in(group) do
      Bonfire.Classify.Categories.list(
        [:default, parent_category: group.id, type: :topic],
        skip_boundary_check: true,
        limit: 50
      )
      |> Map.get(:edges, [])
    end

    defp topic_named(group, name), do: Enum.find(topics_in(group), &(&1.name == name))

    defp in_feed_of?(post_id, category, viewer) do
      {:ok, post} = Bonfire.Common.Needles.get(post_id, skip_boundary_check: true)

      Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
        by: category,
        current_user: viewer
      )
    end

    test "each post goes into the topic for its first category, made in the group when it isn't there, and is boosted into its other categories' topics",
         %{admin: admin, creator: creator, group: group} do
      report = import_posts(admin, post_into_group: group.id)

      assert Enum.sort(Enum.map(topics_in(group), & &1.name)) == @topic_names
      assert Enum.any?(report.notes, &(&1.reason =~ "5 created"))

      %{id: id} = imported(Enum.find(@posts, &(&1.id == 27531)).link)
      assert in_feed_of?(id, topic_named(group, "People"), creator)

      for name <- ["Perspectives", "Pulse", "Totnes Town"],
          do: assert(in_feed_of?(id, topic_named(group, name), creator), "not in #{name}")

      # a post with no category goes into the group itself
      %{id: podcast_id} = imported(Enum.find(@posts, &(&1.id == 16404)).link)
      assert in_feed_of?(podcast_id, group, creator)
    end

    # a topic is found by its name, as the category is named on the site, not by its address here (which may differ)
    test "a topic already in the group is used, not made again", %{
      admin: admin,
      creator: creator,
      group: group
    } do
      existing =
        Bonfire.Classify.Simulate.fake_category!(creator, group, %{
          type: :topic,
          name: "Totnes Town"
        })

      report = import_posts(admin, post_into_group: group.id)

      assert Enum.count(topics_in(group), &(&1.name == "Totnes Town")) == 1
      assert Enum.any?(report.notes, &(&1.reason =~ "4 created"))

      %{id: id} = imported(Enum.find(@posts, &(&1.id == 3060)).link)
      assert in_feed_of?(id, existing, creator)
    end

    # an instance moderator (not an admin, not in the group) importing as themselves is made a member and allowed to post in the group's existing topics, as an admin is; they may not make topics, so the others aren't made
    test "an instance moderator who isn't an admin is put in the group's existing topics", %{
      me: me,
      creator: creator,
      group: group
    } do
      moderator = Bonfire.Me.Fake.instance_moderator!(me)
      refute Bonfire.Me.Accounts.is_admin?(moderator)

      existing =
        Bonfire.Classify.Simulate.fake_category!(creator, group, %{
          type: :topic,
          name: "Totnes Town"
        })

      import_posts(moderator, post_into_group: group.id)

      # its first category ("News") has no topic, and none is made, so it goes in the next one's
      %{id: id} = imported(Enum.find(@posts, &(&1.id == 3060)).link)
      assert in_feed_of?(id, existing, creator)
      assert Enum.map(topics_in(group), & &1.id) == [existing.id]
    end

    test "a topic with the same name in another group isn't used", %{
      admin: admin,
      creator: creator,
      group: group
    } do
      other_group =
        Bonfire.Classify.Simulate.fake_group!(creator, %{
          membership: "local:members",
          visibility: "nonfederated",
          participation: "anyone"
        })

      elsewhere =
        Bonfire.Classify.Simulate.fake_category!(creator, other_group, %{
          type: :topic,
          name: "News"
        })

      import_posts(admin, post_into_group: group.id)

      assert %{} = news = topic_named(group, "News")
      refute news.id == elsewhere.id

      %{id: id} = imported(Enum.find(@posts, &(&1.id == 3264)).link)
      assert in_feed_of?(id, news, creator)
      refute in_feed_of?(id, elsewhere, creator)
    end

    # the group the instance's WordPress site posts into, as its sync does, unless the import names another
    test "with no group asked for, an admin's import goes into the configured group", %{
      admin: admin,
      creator: creator,
      group: group
    } do
      Process.put([:bonfire_wordpress, :post_into_group], group.id)
      import_posts(admin)

      assert length(topics_in(group)) == 5
      %{id: id} = imported(Enum.find(@posts, &(&1.id == 16404)).link)
      assert in_feed_of?(id, group, creator)
    end

    test "a group asked for wins over the configured one", %{admin: admin, group: group} do
      configured =
        Bonfire.Classify.Simulate.fake_group!(fake_user!(), %{
          membership: "local:members",
          visibility: "nonfederated",
          participation: "anyone"
        })

      Process.put([:bonfire_wordpress, :post_into_group], configured.id)
      import_posts(admin, post_into_group: group.id)

      assert length(topics_in(group)) == 5
      assert topics_in(configured) == []
    end

    # a group only its members may post in, so who imports decides whether posts go there
    defp members_group(creator),
      do:
        Bonfire.Classify.Simulate.fake_group!(creator, %{
          membership: "local:members",
          visibility: "nonfederated",
          participation: "group_members"
        })

    # anyone who can post in the group can import into it, but only those who may make topics there get them made: a member's posts go into the group itself
    test "a member who can't make topics imports into the group, and the report says why no topics were made",
         %{me: me, creator: creator} do
      group = members_group(creator)
      assert {:ok, _} = Bonfire.Classify.Categories.join_group(me, group)

      report = import_posts(me, post_into_group: group.id)

      assert topics_in(group) == []
      assert Enum.any?(report.notes, &(&1.key =~ "Topics" and &1.reason =~ "5 not created"))

      for %{link: link} <- @posts do
        %{id: id} = imported(link)
        assert in_feed_of?(id, group, creator)
      end
    end

    # the control for the test below: the same group, imported into by its creator, who may make topics (and isn't an admin)
    test "the group's creator imports into it, with its topics made", %{creator: creator} do
      group = members_group(creator)

      report = import_posts(creator, post_into_group: group.id)

      assert length(topics_in(group)) == 5
      assert Enum.any?(report.notes, &(&1.key =~ "Topics" and &1.reason =~ "5 created"))

      %{id: id} = imported(Enum.find(@posts, &(&1.id == 27531)).link)
      assert in_feed_of?(id, topic_named(group, "People"), creator)
    end

    test "someone who can't post in the group still gets their posts, but not in the group, and the report says why",
         %{me: me, creator: creator} do
      group = members_group(creator)

      report = import_posts(me, post_into_group: group.id)

      assert topics_in(group) == []
      assert Enum.any?(report.notes, &(&1.reason =~ "no permission to post"))

      for %{link: link} <- @posts do
        %{id: id} = imported(link)
        refute in_feed_of?(id, group, creator)
      end
    end

    # WordPress stores a term's name HTML-encoded and exports it as stored (`<![CDATA[Totnes &amp; Town]]>`), and a site's slugs can be edited: the group's topic with the name as it reads is used, not made again
    test "a category whose name the export holds HTML-encoded goes into the topic named as it reads",
         %{admin: admin, creator: creator, group: group} do
      existing =
        Bonfire.Classify.Simulate.fake_category!(creator, group, %{
          type: :topic,
          name: "Totnes & Town"
        })

      encoded =
        Path.join(System.tmp_dir!(), "wxr-encoded-#{System.unique_integer([:positive])}.xml")

      File.write!(
        encoded,
        @fixture
        |> File.read!()
        |> String.replace(
          ~s(nicename="totnes-town"><![CDATA[Totnes Town]]>),
          ~s(nicename="town-matters"><![CDATA[Totnes &amp; Town]]>)
        )
      )

      on_exit(fn -> File.rm(encoded) end)

      import_posts(admin, post_into_group: group.id, fixture: encoded)

      names = Enum.map(topics_in(group), & &1.name)
      assert Enum.count(names, &(&1 == "Totnes & Town")) == 1
      refute Enum.any?(names, &(&1 =~ "&amp;"))

      # 3060's categories are News, then Totnes Town: boosted into the existing topic
      %{id: id} = imported(Enum.find(@posts, &(&1.id == 3060)).link)
      assert in_feed_of?(id, existing, creator)
    end

    test "importing again makes no more topics", %{admin: admin, group: group} do
      import_posts(admin, post_into_group: group.id)
      second = import_posts(admin, post_into_group: group.id)

      assert length(topics_in(group)) == 5
      refute Enum.any?(second.notes, &(&1.reason =~ "created" and &1.key =~ "Topics"))
    end

    # without a group, the same import makes no topics and places nothing (the first test in this block shows the same checks passing with a group)
    test "without a group, no topics are made and posts go in no group", %{
      admin: admin,
      creator: creator,
      group: group
    } do
      import_posts(admin)

      assert topics_in(group) == []
      %{id: id} = imported(Enum.find(@posts, &(&1.id == 16404)).link)
      refute in_feed_of?(id, group, creator)
    end
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
