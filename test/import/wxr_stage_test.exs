defmodule Bonfire.WordPress.Import.WXRStageTest do
  use Bonfire.WordPress.DataCase, async: true

  alias Bonfire.WordPress.Import.WXR

  # a public subset of a real export (host and emails rewritten), plus hand-written items the import must skip
  @fixture Path.expand("../fixtures/totnespulse_subset.xml", __DIR__)

  test "the export is a source a file can be staged from, found among the extensions, not registered in config" do
    Process.put([:bonfire_common, Bonfire.Common.Import, :archive_sources], [])

    assert Bonfire.Common.Import.archive_sources()[:wordpress] == WXR

    # a form sends the key as a string, matched without making an atom
    assert Bonfire.Common.Import.archive_source("wordpress") == WXR
  end

  test "staging an export lists its published posts, and counts what it won't import" do
    assert {:ok, staged} = WXR.stage(@fixture)
    on_exit(fn -> File.rm_rf(staged.dir) end)

    assert staged.source == WXR
    assert staged.base_site_url == "https://www.totnespulse.local"

    items = Map.new(staged.items, &{&1.key, &1})

    # three posts and one podcast episode, which imports as a post
    assert %{count: 4, importable?: true} = items[:posts]
    assert %{count: 1, importable?: false} = items[:pages]

    # by post type for the types not imported, by status for a post that isn't published, and a published post behind a password
    assert staged.skipped == %{
             "ajde_events" => 1,
             "shop_order" => 1,
             "draft" => 1,
             "trash" => 1,
             "password-protected" => 1
           }
  end

  # a post's categories place it in topics; its tags, a podcast's series and a file's media categories don't
  test "a staged post keeps its categories, by name and slug, in the file's order" do
    assert {:ok, staged} = WXR.stage(@fixture)
    on_exit(fn -> File.rm_rf(staged.dir) end)

    post = staged.dir |> Path.join("posts/27531.json") |> File.read!() |> Jason.decode!()

    assert post["categories"] == [
             %{"name" => "People", "slug" => "people"},
             %{"name" => "Perspectives", "slug" => "perspectives"},
             %{"name" => "Pulse", "slug" => "totnes-pulse"},
             %{"name" => "Totnes Town", "slug" => "totnes-town"}
           ]

    # a podcast episode with only tags and a series has no categories
    podcast = staged.dir |> Path.join("posts/16404.json") |> File.read!() |> Jason.decode!()
    assert podcast["categories"] in [nil, []]
  end

  # the site's REST API names a post's author by this id, so a sync can find the user an import made for them
  test "staged authors keep their id on the site" do
    assert {:ok, staged} = WXR.stage(@fixture)
    on_exit(fn -> File.rm_rf(staged.dir) end)

    authors = staged.dir |> Path.join("authors.json") |> File.read!() |> Jason.decode!()

    assert Map.new(authors, fn {login, author} -> {login, author["wp:author_id"]} end) == %{
             "The Totnes Pulse" => "11",
             "JoBob" => "149",
             "Tony Gee" => "104",
             "John Anderson" => "16"
           }
  end

  test "a DTD in the file is never expanded, so an entity can't pull in a local file" do
    secret = Path.join(System.tmp_dir!(), "wxr-secret-#{System.unique_integer([:positive])}.txt")
    File.write!(secret, "SECRET-CONTENT")

    path = Path.join(System.tmp_dir!(), "wxr-xxe-#{System.unique_integer([:positive])}.xml")

    File.write!(path, """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE rss [<!ENTITY xxe SYSTEM "file://#{secret}">]>
    <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:wp="http://wordpress.org/export/1.2/">
    <channel>
      <wp:base_site_url>https://example.local</wp:base_site_url>
      <item>
        <title>&xxe;</title>
        <link>https://example.local/a-post/</link>
        <dc:creator><![CDATA[someone]]></dc:creator>
        <content:encoded><![CDATA[<p>&xxe;</p>]]></content:encoded>
        <wp:post_id>1</wp:post_id>
        <wp:post_date_gmt><![CDATA[2025-01-01 10:00:00]]></wp:post_date_gmt>
        <wp:status><![CDATA[publish]]></wp:status>
        <wp:post_type><![CDATA[post]]></wp:post_type>
      </item>
    </channel>
    </rss>
    """)

    on_exit(fn -> File.rm(secret) && File.rm(path) end)

    assert {:ok, staged} = WXR.stage(path)
    on_exit(fn -> File.rm_rf(staged.dir) end)

    assert %{count: 1} = Enum.find(staged.items, &(&1.key == :posts))

    for file <- Path.wildcard(Path.join(staged.dir, "**")), File.regular?(file) do
      refute File.read!(file) =~ "SECRET-CONTENT"
    end
  end
end
