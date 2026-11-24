defmodule Bonfire.WordPress.Import.WXRAttachmentsTest do
  @moduledoc """
  The images a WordPress post shows in its body come in as `Media`: one per upload on the site, whatever sizes the posts show it in, attached to each post that shows it, with its alt text, caption and description. Each image in the body points at its `Media` through `/files/redir/<site key>/…`, so the post shows it once, where it is, and the same URL keeps working once the files are stored here.
  """
  use Bonfire.WordPress.ConnCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo
  import PhoenixTest

  alias Bonfire.Common.Repo
  alias Bonfire.Common.Import
  alias Bonfire.WordPress.Import.WXR

  @moduletag :backend

  require Bonfire.Common.Config

  @site "https://blog.example.local"
  @uploads "#{@site}/wp-content/uploads"

  # one upload in three sizes (the original and two WordPress made), as `_wp_attachment_metadata` lists them
  @pic_meta ~s(a:5:{s:5:"width";i:2000;s:6:"height";i:1333;s:4:"file";s:15:"2020/01/pic.jpg";s:5:"sizes";a:2:{s:6:"medium";a:4:{s:4:"file";s:15:"pic-300x200.jpg";s:5:"width";i:300;s:6:"height";i:200;s:9:"mime-type";s:10:"image/jpeg";}s:5:"large";a:4:{s:4:"file";s:16:"pic-1024x683.jpg";s:5:"width";i:1024;s:6:"height";i:683;s:9:"mime-type";s:10:"image/jpeg";}}s:10:"image_meta";a:0:{}})

  defp attachment(id, url, fields) do
    meta =
      for {key, value} <- fields[:meta] || [] do
        "<wp:postmeta><wp:meta_key><![CDATA[#{key}]]></wp:meta_key><wp:meta_value><![CDATA[#{value}]]></wp:meta_value></wp:postmeta>"
      end

    """
    <item>
      <title><![CDATA[#{fields[:title] || "file name"}]]></title>
      <link>#{@site}/?attachment_id=#{id}</link>
      <content:encoded><![CDATA[#{fields[:description]}]]></content:encoded>
      <excerpt:encoded><![CDATA[#{fields[:caption]}]]></excerpt:encoded>
      <wp:post_id>#{id}</wp:post_id>
      <wp:status><![CDATA[inherit]]></wp:status>
      <wp:post_type><![CDATA[attachment]]></wp:post_type>
      <wp:attachment_url><![CDATA[#{url}]]></wp:attachment_url>
      #{Enum.join(meta)}
    </item>
    """
  end

  defp wp_post(id, slug, body, meta \\ []) do
    meta =
      for {key, value} <- meta do
        "<wp:postmeta><wp:meta_key><![CDATA[#{key}]]></wp:meta_key><wp:meta_value><![CDATA[#{value}]]></wp:meta_value></wp:postmeta>"
      end

    """
    <item>
      <title><![CDATA[Post #{slug}]]></title>
      <link>#{@site}/#{slug}/</link>
      <content:encoded><![CDATA[#{body}]]></content:encoded>
      <wp:post_id>#{id}</wp:post_id>
      <wp:post_date_gmt><![CDATA[2020-01-0#{rem(id, 9) + 1} 10:00:00]]></wp:post_date_gmt>
      <wp:status><![CDATA[publish]]></wp:status>
      <wp:post_type><![CDATA[post]]></wp:post_type>
      #{Enum.join(meta)}
    </item>
    """
  end

  defp export do
    """
    <?xml version="1.0" encoding="UTF-8" ?>
    <rss version="2.0" xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:wp="http://wordpress.org/export/1.2/">
    <channel>
      <wp:base_site_url>#{@site}</wp:base_site_url>
      #{attachment(900, "#{@uploads}/2020/01/pic.jpg", title: "pic", caption: "Photo by Jo", description: "A longer description of the cover.", meta: [{"_wp_attachment_image_alt", "The cover"}, {"_wp_attachment_metadata", @pic_meta}])}
      #{attachment(901, "#{@uploads}/2021/02/dup.png", title: "dup", caption: "a square at noon", description: "A Square at noon", meta: [{"_wp_attachment_image_alt", "A Square, at noon."}])}
      #{attachment(902, "#{@uploads}/2022/03/cover.png", title: "Cover", caption: "The featured one", description: "Cover", meta: [{"_wp_attachment_image_alt", "A featured cover"}])}
      #{wp_post(101, "small", ~s(<p>a</p><p><img src="http://blog.example.local/wp-content/uploads/2020/01/pic-300x200.jpg" alt="small"></p><p>b</p><p><img src="#{@uploads}/2020/01/pic-300x200.jpg"></p>))}
      #{wp_post(102, "large", ~s(<p>c</p><p><img src="#{@uploads}/2020/01/pic-1024x683.jpg"></p><p><img src="https://elsewhere.example.local/x.png"></p><p><img src="#{@uploads}/2021/02/dup-640x480.png"></p><p>d</p>))}
      #{wp_post(103, "featured", ~s(<p>e</p><p><img src="#{@uploads}/2022/03/cover-300x200.png"></p>), [{"_thumbnail_id", "902"}])}
      #{attachment(903, "#{@uploads}/2023/04/moved.jpg", title: "moved", meta: [{"_wp_attachment_image_alt", "Moved elsewhere"}])}
      #{wp_post(104, "by-id", ~s(<p>f</p><p><img class="aligncenter wp-image-903 size-full" src="https://cdn.example.local/abc123.jpg"></p><p>g</p>))}
    </channel>
    </rss>
    """
  end

  setup do
    # the site's API isn't reachable, so each post comes in with the export's own body; no media file is ever fetched
    Tesla.Mock.mock_global(fn _ -> %Tesla.Env{status: 500, body: ""} end)

    # the import adds the site's key to the instance's settings, which also go into the app's config, which outlives each test's database rollback
    previous = Bonfire.Common.Config.get([:bonfire_files, :redir_storages], %{})
    on_exit(fn -> Bonfire.Common.Config.put([:bonfire_files, :redir_storages], previous) end)

    path =
      Path.join(System.tmp_dir!(), "wxr-attachments-#{System.unique_integer([:positive])}.xml")

    File.write!(path, export())
    on_exit(fn -> File.rm(path) end)

    account = fake_account!()
    me = fake_user!(account)

    assert {:ok, staged} = WXR.stage(path)
    on_exit(fn -> File.rm_rf(staged.dir) end)
    assert {:ok, _report} = Import.import_staged(me, staged, only: [:posts])

    for job <- all_enqueued(worker: Import), job.args["op"] == "wordpress_import" do
      assert {:ok, _} = Import.perform(job)
    end

    {:ok, me: me, conn: conn(user: me, account: account)}
  end

  defp imported(slug) do
    assert {:ok, %{id: id}} = Bonfire.Federate.ActivityPub.Peered.get_by_uri("#{@site}/#{slug}/")
    %{id: id, body: Repo.get!(Bonfire.Data.Social.PostContent, id).html_body}
  end

  defp media_of(id) do
    assert {:ok, post} = Bonfire.Common.Needles.get(id, skip_boundary_check: true)

    post
    |> Repo.preload([files: :media], force: true)
    |> Map.get(:files)
    |> Enum.map(& &1.media)
  end

  defp marker(media),
    do: URI.parse(Bonfire.Files.inline_url(media)).path

  defp count(html, text), do: length(String.split(html, text)) - 1

  test "an upload shown in two sizes by two posts is one Media, attached to both, at the larger size" do
    small = imported("small")
    large = imported("large")

    assert [pic] = media_of(small.id)
    assert pic.id in Enum.map(media_of(large.id), & &1.id)
    assert pic.path == "#{@uploads}/2020/01/pic-1024x683.jpg"
  end

  # so a sync finds the upload from whichever size a post shows, without asking the site
  test "an upload's Media keeps every URL of its sizes, and the site counts as imported" do
    assert [pic] = media_of(imported("small").id)

    for size <- ["pic.jpg", "pic-300x200.jpg", "pic-1024x683.jpg"] do
      assert "#{@uploads}/2020/01/#{size}" in List.wrap(pic.metadata["urls"])
    end

    assert Bonfire.WordPress.Sync.imported?(@site)
  end

  test "an image a post shows twice is attached once, and each place points at its Media" do
    %{id: id, body: body} = imported("small")

    assert [pic] = media_of(id)
    assert count(body, marker(pic)) == 2
    refute body =~ "pic-300x200"
  end

  test "an image from another site isn't attached and stays as it is, and one with no size list is matched by its name" do
    %{id: id, body: body} = imported("large")

    assert body =~ ~s(src="https://elsewhere.example.local/x.png")

    paths = Enum.map(media_of(id), & &1.path)
    refute "https://elsewhere.example.local/x.png" in paths
    assert "#{@uploads}/2021/02/dup-640x480.png" in paths

    dup = Enum.find(media_of(id), &(&1.path =~ "dup-640x480"))
    assert body =~ marker(dup)
  end

  test "the marker URL redirects to where the Media's file is", %{conn: conn} do
    %{id: id} = imported("small")
    assert [pic] = media_of(id)

    conn = get(conn, marker(pic))

    assert conn.status == 302
    assert List.first(get_resp_header(conn, "location")) == pic.path
  end

  test "the post shows each image once, in place", %{conn: conn} do
    %{id: id} = imported("large")
    image = "#{@uploads}/2021/02/dup-640x480.png"

    html =
      conn
      |> visit("/post/#{id}")
      |> PhoenixTest.unwrap(fn view ->
        html = Phoenix.LiveViewTest.render(view)
        send(self(), {:rendered, html})
        html
      end)
      |> then(fn _ ->
        assert_received {:rendered, html}
        html
      end)

    assert html =~ ~r/c<\/p>.*data-role="inline_media".*#{Regex.escape(image)}.*d<\/p>/s

    assert count(html, image) ==
             count(
               html
               |> LazyHTML.from_document()
               |> LazyHTML.query("[data-role=inline_media]")
               |> LazyHTML.to_html(),
               image
             )
  end

  # WordPress marks each image it inserts with the class `wp-image-<id>`, naming its upload even where its URL doesn't (eg. served from elsewhere)
  test "an image whose URL matches no upload is found by its `wp-image` class" do
    %{id: id, body: body} = imported("by-id")

    assert [moved] = media_of(id)
    assert moved.metadata["alt"] == "Moved elsewhere"
    assert body =~ marker(moved)
    refute body =~ "abc123"
  end

  describe "alt text, caption and description" do
    test "each different one is kept, and the title isn't" do
      assert [pic] = media_of(imported("small").id)

      assert pic.metadata["alt"] == "The cover"
      assert pic.metadata["label"] == "Photo by Jo"
      assert pic.metadata["description"] == "A longer description of the cover."
      refute pic.metadata["title"]
    end

    test "a caption that only repeats the alt text, or a description that only repeats the caption, isn't kept" do
      dup = Enum.find(media_of(imported("large").id), &(&1.path =~ "dup-640x480"))

      assert dup.metadata["alt"] == "A Square, at noon."
      refute dup.metadata["label"]
      refute dup.metadata["description"]
    end

    test "a featured image shown in its post's body is one Media, the post's main image, with its caption" do
      %{id: id, body: body} = imported("featured")

      assert [cover] = media_of(id)
      assert cover.metadata["primary_image"] == true
      assert cover.metadata["alt"] == "A featured cover"
      assert cover.metadata["label"] == "The featured one"
      # its description only repeats its title
      refute cover.metadata["description"]
      assert body =~ marker(cover)
    end
  end
end
