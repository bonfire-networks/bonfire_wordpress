defmodule Bonfire.WordPress.SyncTest do
  @moduledoc """
  A WordPress site that was imported pings Bonfire through WordPress's "update services" (an XML-RPC `weblogUpdates` ping, sent when a post is published or edited), and Bonfire fetches what changed through the site's REST API.
  """
  use Bonfire.WordPress.DataCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo

  import Tesla.Mock

  alias Bonfire.WordPress.Sync
  alias Bonfire.WordPress.XMLRPC

  @site "https://www.totnespulse.local"

  setup do
    importer = Bonfire.Me.Fake.fake_user!()

    # the site an earlier import configured, read with Config.get like Ghost's settings
    Process.put([:bonfire_wordpress, :site_url], @site)
    Process.put([:bonfire_wordpress, :auto_import_as], importer.id)

    {:ok, importer: importer}
  end

  defp sync_jobs,
    do:
      for(
        job <- all_enqueued(worker: Bonfire.Common.Import),
        job.args["op"] == "wordpress_sync",
        do: job
      )

  test "a ping for the configured site queues one sync, however many pings come before it runs" do
    assert :queued = Sync.ping("http://www.totnespulse.local/")
    assert [job] = sync_jobs()
    assert job.args["identifier"] == @site

    Sync.ping(@site)
    assert length(sync_jobs()) == 1
  end

  test "a ping for another site queues nothing" do
    assert :ignored = Sync.ping("https://elsewhere.local")
    assert sync_jobs() == []
  end

  test "a sync imports the posts changed on the site since the last one, and remembers when it ran",
       %{importer: importer} do
    old = "#{@site}/an-old-post/"
    new = "#{@site}/a-new-post/"

    # imported before, so the sync updates it rather than importing it again (see sync_update_test.exs)
    {:ok, _} =
      Bonfire.WordPress.Posts.import_post(
        %{title: "An old post", link: old, published_at: nil, html: "<p>Old</p>", author: nil},
        current_user: importer
      )

    mock_global(fn
      %{method: :get, url: "#{@site}/wp-json/wp/v2/posts" <> _} ->
        %Tesla.Env{
          status: 200,
          headers: [{"x-wp-totalpages", "1"}],
          body:
            Jason.encode!([
              rest_post(1, old, "An old post"),
              rest_post(2, new, "A new post")
            ])
        }

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)

    Sync.ping(@site)
    [job] = sync_jobs()
    assert :ok = perform_job(Bonfire.Common.Import, job.args)

    assert {:ok, _} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(new)
    assert Bonfire.WordPress.Posts.imported_links([old, new]) == MapSet.new([old, new])

    assert %DateTime{} = Sync.last_sync()
  end

  # runs a sync of the site with `posts` as the changed posts the REST API answers, and returns the media files requested (there should be none)
  defp sync_with(posts) do
    {:ok, media_requests} = Agent.start_link(fn -> [] end)

    mock_global(fn
      %{method: :get, url: "#{@site}/wp-json/wp/v2/posts" <> _} ->
        %Tesla.Env{status: 200, headers: [{"x-wp-totalpages", "1"}], body: Jason.encode!(posts)}

      %{url: url} ->
        if String.contains?(url, "/wp-content/uploads/"),
          do: Agent.update(media_requests, &[url | &1])

        %Tesla.Env{status: 404, body: ""}
    end)

    Sync.ping(@site)
    [job] = sync_jobs()
    assert :ok = perform_job(Bonfire.Common.Import, job.args)

    Agent.get(media_requests, & &1)
  end

  defp media_of(link) do
    assert {:ok, %{id: id}} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(link)
    assert {:ok, post} = Bonfire.Common.Needles.get(id, skip_boundary_check: true)

    post
    |> Bonfire.Common.Repo.preload([files: :media], force: true)
    |> Map.get(:files)
    |> Enum.map(& &1.media)
  end

  # media metadata is stored as JSON, so read back with string keys
  defp primary_image?(%{metadata: metadata}) when is_map(metadata),
    do: (metadata["primary_image"] || metadata[:primary_image]) == true

  defp primary_image?(_), do: false

  test "a synced post's featured image is attached as its primary image, at its address on the site, with its alt text" do
    link = "#{@site}/a-post-with-a-cover/"
    image = "#{@site}/wp-content/uploads/2026/10/a-cover.png"

    post =
      rest_post(3, link, "A post with a cover")
      |> Map.put("_embedded", %{
        "wp:featuredmedia" => [
          %{
            "id" => 30,
            "source_url" => image,
            "mime_type" => "image/png",
            "alt_text" => "A consultant with a carpet"
          }
        ]
      })

    assert sync_with([post]) == []

    assert [media] = media_of(link)
    assert media.path == image
    assert primary_image?(media)
    assert Bonfire.Files.Media.media_alt(media, false) == "A consultant with a carpet"
  end

  test "a synced post whose featured image the site won't show comes in without it" do
    link = "#{@site}/a-post-with-a-private-cover/"

    post =
      rest_post(4, link, "A post with a private cover")
      |> Map.put("_embedded", %{
        "wp:featuredmedia" => [
          %{
            "code" => "rest_forbidden",
            "message" => "Sorry, you are not allowed to do that.",
            "data" => %{"status" => 401}
          }
        ]
      })

    assert sync_with([post]) == []
    assert media_of(link) == []
  end

  test "a synced podcast episode gets its audio file, and its cover as primary image, from the podcast plugin's fields" do
    link = "#{@site}/podcast/an-episode/"
    audio = "#{@site}/wp-content/uploads/2024/11/an-episode.mp3"
    cover = "#{@site}/wp-content/uploads/2024/11/an-episode-cover.jpg"

    episode =
      rest_post(5, link, "An episode")
      |> Map.put("featured_media", 0)
      |> Map.put("meta", %{"audio_file" => audio, "cover_image" => cover})

    {:ok, media_requests} = Agent.start_link(fn -> [] end)

    mock_global(fn
      %{method: :get, url: "#{@site}/wp-json/wp/v2/podcast" <> _} ->
        %Tesla.Env{
          status: 200,
          headers: [{"x-wp-totalpages", "1"}],
          body: Jason.encode!([episode])
        }

      %{method: :get, url: "#{@site}/wp-json/wp/v2/posts" <> _} ->
        %Tesla.Env{status: 200, headers: [{"x-wp-totalpages", "1"}], body: Jason.encode!([])}

      %{url: url} ->
        if String.contains?(url, "/wp-content/uploads/"),
          do: Agent.update(media_requests, &[url | &1])

        %Tesla.Env{status: 404, body: ""}
    end)

    Sync.ping(@site)
    [job] = sync_jobs()
    assert :ok = perform_job(Bonfire.Common.Import, job.args)
    assert Agent.get(media_requests, & &1) == []

    media = media_of(link)

    assert Enum.any?(
             media,
             &(&1.path == audio and String.starts_with?(&1.media_type || "", "audio"))
           )

    assert Enum.any?(media, &(&1.path == cover and primary_image?(&1)))
  end

  # the categories as the REST API embeds them (`_embed=wp:term`): one list per taxonomy, categories first, then tags
  defp with_terms(post, categories, tags \\ []) do
    terms = fn list, taxonomy ->
      for {name, slug} <- list, do: %{"name" => name, "slug" => slug, "taxonomy" => taxonomy}
    end

    post
    |> Map.put("categories", Enum.map(Enum.with_index(categories, 1), &elem(&1, 1)))
    |> Map.put("_embedded", %{
      "wp:term" => [terms.(categories, "category"), terms.(tags, "post_tag")]
    })
  end

  defp creator_of(link) do
    assert {:ok, %{id: id}} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(link)
    Bonfire.Common.Repo.get!(Bonfire.Data.Social.Created, id).creator_id
  end

  # the site's REST API names a post's author by id: an author an import made a user for comes in as that user
  test "a synced post by an author the import linked to a user is by that user, and the request asks for its author" do
    author = Bonfire.Me.Fake.fake_user!()
    {:ok, _} = Bonfire.WordPress.Identities.link(@site, "149", author)

    link = "#{@site}/a-post-by-a-known-author/"
    {:ok, urls} = Agent.start_link(fn -> [] end)
    post = rest_post(8, link, "A post by a known author") |> Map.put("author", 149)

    mock_global(fn
      %{method: :get, url: "#{@site}/wp-json/wp/v2/posts" <> _ = url} ->
        Agent.update(urls, &[url | &1])
        %Tesla.Env{status: 200, headers: [{"x-wp-totalpages", "1"}], body: Jason.encode!([post])}

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)

    Sync.ping(@site)
    [job] = sync_jobs()
    assert :ok = perform_job(Bonfire.Common.Import, job.args)

    assert creator_of(link) == author.id

    [url] = Agent.get(urls, & &1)
    query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    assert "author" in String.split(query["_fields"], ",")
  end

  # the control for the test above: an author nobody linked (eg. a new writer on the site) comes in as the user whose import the site is
  test "a synced post by an author no import linked is by the user whose import the site is",
       %{importer: importer} do
    other = Bonfire.Me.Fake.fake_user!()
    {:ok, _} = Bonfire.WordPress.Identities.link(@site, "149", other)

    link = "#{@site}/a-post-by-a-new-writer/"
    sync_with([rest_post(9, link, "A post by a new writer") |> Map.put("author", 7)])

    assert creator_of(link) == importer.id
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

    defp in_feed_of?(link, category, viewer) do
      {:ok, %{id: id}} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(link)
      {:ok, post} = Bonfire.Common.Needles.get(id, skip_boundary_check: true)

      Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
        by: category,
        current_user: viewer
      )
    end

    defp topics_in(group),
      do:
        Bonfire.Classify.Categories.list(
          [:default, parent_category: group.id, type: :topic],
          skip_boundary_check: true,
          limit: 50
        )
        |> Map.get(:edges, [])

    test "a synced post goes into the topics its categories have in the group, and the request asks for its categories",
         %{importer: importer, group: group} do
      news =
        Bonfire.Classify.Simulate.fake_category!(importer, group, %{type: :topic, name: "News"})

      town =
        Bonfire.Classify.Simulate.fake_category!(importer, group, %{
          type: :topic,
          name: "Totnes Town"
        })

      link = "#{@site}/a-categorised-post/"
      {:ok, urls} = Agent.start_link(fn -> [] end)

      post =
        rest_post(6, link, "A categorised post")
        |> with_terms([{"News", "news"}, {"Totnes Town", "totnes-town"}], [{"Ukraine", "ukraine"}])

      mock_global(fn
        %{method: :get, url: "#{@site}/wp-json/wp/v2/posts" <> _ = url} ->
          Agent.update(urls, &[url | &1])

          %Tesla.Env{
            status: 200,
            headers: [{"x-wp-totalpages", "1"}],
            body: Jason.encode!([post])
          }

        _ ->
          %Tesla.Env{status: 404, body: ""}
      end)

      Sync.ping(@site)
      [job] = sync_jobs()
      assert :ok = perform_job(Bonfire.Common.Import, job.args)

      assert in_feed_of?(link, news, importer)
      assert in_feed_of?(link, town, importer)

      [url] = Agent.get(urls, & &1)
      query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert "wp:term" in String.split(query["_embed"], ",")
      assert "categories" in String.split(query["_fields"], ",")
    end

    # WordPress stores a term's name HTML-encoded and its REST API sends it as stored (`News &amp; Views`); a site's slugs can be edited, so the topic is found by the name as it reads, not as it's encoded
    test "a synced post goes into the topic named as its category reads, when the site sends the name HTML-encoded",
         %{importer: importer, group: group} do
      topic =
        Bonfire.Classify.Simulate.fake_category!(importer, group, %{
          type: :topic,
          name: "News & Views"
        })

      link = "#{@site}/a-post-in-an-encoded-category/"

      post =
        rest_post(10, link, "A post in an encoded category")
        |> with_terms([{"News &amp; Views", "news-and-views"}])

      sync_with([post])

      assert in_feed_of?(link, topic, importer)
    end

    # a sync finds topics, it never makes them: that's for an import, when someone asks for it
    test "a synced post whose categories have no topic in the group goes into the group, and no topic is made",
         %{importer: importer, group: group} do
      link = "#{@site}/a-post-in-a-new-category/"

      post =
        rest_post(7, link, "A post in a new category") |> with_terms([{"Brand New", "brand-new"}])

      assert sync_with([post]) == []

      assert topics_in(group) == []
      assert in_feed_of?(link, group, importer)
    end
  end

  test "a ping body with a DTD is refused, never expanded" do
    secret = Path.join(System.tmp_dir!(), "wp-ping-secret-#{System.unique_integer([:positive])}")
    File.write!(secret, "SECRET-CONTENT")
    on_exit(fn -> File.rm(secret) end)

    body = """
    <?xml version="1.0"?>
    <!DOCTYPE methodCall [<!ENTITY xxe SYSTEM "file://#{secret}">]>
    <methodCall><methodName>weblogUpdates.ping</methodName>
    <params><param><value><string>&xxe;</string></value></param>
    <param><value><string>#{@site}</string></value></param></params></methodCall>
    """

    assert {:error, :dtd} = XMLRPC.parse_ping(body)
  end

  test "an extendedPing gives its site's home URL" do
    body = """
    <?xml version="1.0"?>
    <methodCall><methodName>weblogUpdates.extendedPing</methodName>
    <params>
    <param><value><string>Totnes Pulse</string></value></param>
    <param><value><string>#{@site}</string></value></param>
    <param><value><string>#{@site}/a-new-post/</string></value></param>
    <param><value><string>#{@site}/feed/</string></value></param>
    </params></methodCall>
    """

    assert {:ok, %{method: "weblogUpdates.extendedPing", home_url: @site}} =
             XMLRPC.parse_ping(body)
  end

  defp rest_post(id, link, title),
    do: %{
      "id" => id,
      "link" => link,
      "date_gmt" => "2026-11-20T10:00:00",
      "modified_gmt" => "2026-11-22T10:00:00",
      "title" => %{"rendered" => title},
      "content" => %{"rendered" => "<p>#{title}</p>", "protected" => false}
    }
end
