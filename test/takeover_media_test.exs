defmodule Bonfire.WordPress.Takeover.MediaTest do
  @moduledoc """
  At takeover, the files of a WordPress site's imported `Media` are stored here, from a copy of the site's uploads folder: each `Media` gets its file resized in this instance's storage, at the path its body markers (`/files/redir/<site key>/…`) already name. Only once all of them are stored does the site's key become an alias of this instance's storage, so the markers lead to the stored files with no lookup. A file missing from the folder is reported, and the key stays a lookup, so every marker still leads to a file until a later run stores the rest.
  """
  use Bonfire.WordPress.DataCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo
  @moduletag :backend

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]
  import Bonfire.Me.Fake
  import Ecto.Query, only: [from: 2]
  require Bonfire.Common.Config
  @endpoint Application.compile_env!(:bonfire, :endpoint_module)

  alias Bonfire.Files
  alias Bonfire.WordPress.Posts
  alias Bonfire.WordPress.Takeover

  @site "https://blog.example.local"
  @uploads "#{@site}/wp-content/uploads"

  setup do
    Process.put([:bonfire_files, :storage], :local)

    previous = Application.get_env(:bonfire_files, :redir_storages)
    on_exit(fn -> Application.put_env(:bonfire_files, :redir_storages, previous) end)

    key = Posts.redir_storage(@site)
    Posts.register_redir_storage(@site)

    me = fake_user!()

    # two uploads as an import makes them: one shown at a size WordPress made of it, one as it was uploaded
    resized = imported_media(me, "2018/12/a-300x400.png", ["2018/12/a.png"], key)
    original = imported_media(me, "2019/01/b.png", [], key)

    # the copy of the site's `wp-content/uploads` folder an admin puts on the server
    folder = Path.join(System.tmp_dir!(), "takeover-#{System.unique_integer([:positive])}")
    uploads = Path.join([folder, "wp-content", "uploads"])
    on_exit(fn -> File.rm_rf(folder) end)

    for media <- [resized, original] do
      on_exit(fn -> File.rm(Entrepot.Storages.Disk.path(media.file.id)) end)
    end

    {:ok,
     key: key, resized: resized, original: original, uploads: uploads, folder: folder, me: me}
  end

  defp imported_media(me, path, other_sizes, key) do
    url = "#{@uploads}/#{path}"

    {:ok, media} = Files.save_url_as_media(me, url, %{media_type: "image/png"})

    {:ok, media} =
      Bonfire.Files.Media.update(
        nil,
        media,
        %{metadata: %{"urls" => [url | Enum.map(other_sizes, &"#{@uploads}/#{&1}")]}},
        skip_boundary_check: true
      )

    {:ok, media} = Files.put_storage_locator(media, key)
    media
  end

  defp copy_upload(uploads, path) do
    destination = Path.join(uploads, path)
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(Bonfire.Files.Simulation.image_file().path, destination)
  end

  defp marker(key, media), do: "/files/redir/#{key}/#{media.file.id}"

  defp location(conn), do: List.first(get_resp_header(conn, "location"))

  test "with every file in the folder, each is stored here and the site's markers lead to the stored files",
       %{key: key, resized: resized, original: original, uploads: uploads} do
    # the original of the resized one is in the folder, as WordPress keeps it next to its sizes
    copy_upload(uploads, "2018/12/a.png")
    copy_upload(uploads, "2019/01/b.png")

    assert {:ok, %{stored: 2, not_stored: []}} = Takeover.Media.run(@site, uploads)

    assert Files.redir_storages()[key] == {:alias, Files.default_storage_name()}

    for media <- [resized, original] do
      assert File.exists?(Entrepot.Storages.Disk.path(media.file.id))

      conn = get(build_conn(), marker(key, media))
      assert conn.status == 302
      assert location(conn) =~ media.file.id
      refute location(conn) =~ "blog.example.local"
    end
  end

  test "a file missing from the folder is reported, the others are stored, and the site's key stays a lookup until a run stores it",
       %{key: key, resized: resized, original: original, uploads: uploads, folder: folder} do
    copy_upload(uploads, "2019/01/b.png")

    # the folder given as the site's root works too
    assert {:ok, %{stored: 1, not_stored: [missing]}} = Takeover.Media.run(@site, folder)
    assert missing.id == resized.id
    assert missing.url == resized.path

    assert Files.redir_storages()[key] == :lookup

    # the missing one still leads to the site, the stored one to its file here
    assert location(get(build_conn(), marker(key, resized))) == resized.path
    assert location(get(build_conn(), marker(key, original))) =~ original.file.id

    # added to the folder, at the size the post shows it
    copy_upload(uploads, "2018/12/a-300x400.png")

    assert {:ok, %{stored: 1, not_stored: []}} = Takeover.Media.run(@site, uploads)
    assert Files.redir_storages()[key] == {:alias, Files.default_storage_name()}
  end

  # a public subset of a real export and the site's REST answers for its posts, as `wxr_import_test.exs` imports them
  @sample_site "https://www.totnespulse.local"
  @sample_export Path.expand("fixtures/totnespulse_subset.xml", __DIR__)
  @sample_rest Path.expand("fixtures/totnespulse_subset_rest.json", __DIR__)
  @synced_link "#{@sample_site}/synced-after-the-import/"

  test "a site imported from its export and synced since has every media its posts show stored here, and every marker in their bodies leads to a stored file",
       %{me: me, folder: folder} do
    # the import and the sync also put these in the instance's settings, which go into the app's config and outlive each test's database rollback
    previous =
      for key <- [:imported_sites, :last_sync],
          do: {key, Bonfire.Common.Config.get([:bonfire_wordpress, key])}

    on_exit(fn ->
      for {key, value} <- previous,
          do: Bonfire.Common.Config.put([:bonfire_wordpress, key], value)
    end)

    # the import: bodies from the site's API, no media file ever fetched
    rest = @sample_rest |> File.read!() |> Jason.decode!()

    Tesla.Mock.mock_global(fn
      %{method: :get, url: url} ->
        case Regex.run(~r{^https://www\.totnespulse\.local/wp-json/wp/v2/(posts|podcast)\b}, url) do
          [_, type] -> Tesla.Mock.json(rest[type])
          _ -> %Tesla.Env{status: 404, body: ""}
        end

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)

    assert {:ok, staged} = Bonfire.WordPress.Import.WXR.stage(@sample_export)
    on_exit(fn -> File.rm_rf(staged.dir) end)
    assert {:ok, _} = Bonfire.Common.Import.import_staged(me, staged, only: [:posts])

    for job <- all_enqueued(worker: Bonfire.Common.Import),
        job.args["op"] == "wordpress_import" do
      assert {:ok, _} = Bonfire.Common.Import.perform(job)
    end

    # then a post published on the site since, synced: one image new to us, one the import already brought in
    Process.put([:bonfire_wordpress, :site_url], @sample_site)
    Process.put([:bonfire_wordpress, :auto_import_as], me.id)

    synced = %{
      "id" => 99_001,
      "link" => @synced_link,
      "date_gmt" => "2026-11-20T10:00:00",
      "modified_gmt" => "2026-11-22T10:00:00",
      "title" => %{"rendered" => "Synced after the import"},
      "content" => %{
        "rendered" =>
          ~s(<p>New</p><p><img src="#{@sample_site}/wp-content/uploads/2026/11/new-photo-300x200.jpg" alt="A new photo"></p><p>Known</p><p><img src="#{@sample_site}/wp-content/uploads/2019/01/TotnesXX-300x128.png" alt="Totnes XX"></p>),
        "protected" => false
      }
    }

    Tesla.Mock.mock_global(fn
      %{method: :get, url: "#{@sample_site}/wp-json/wp/v2/posts" <> _} ->
        %Tesla.Env{
          status: 200,
          headers: [{"x-wp-totalpages", "1"}],
          body: Jason.encode!([synced])
        }

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)

    Bonfire.WordPress.Sync.ping(@sample_site)

    [job] =
      for job <- all_enqueued(worker: Bonfire.Common.Import),
          job.args["op"] == "wordpress_sync",
          do: job

    assert :ok = perform_job(Bonfire.Common.Import, job.args)

    key = Posts.redir_storage(@sample_site)

    site_media = fn ->
      Bonfire.Common.Repo.all(
        from(m in Bonfire.Files.Media, where: fragment("?->>'storage'", m.file) == ^key)
      )
    end

    imported = site_media.()
    assert imported != []
    assert Enum.any?(imported, &(&1.path =~ "new-photo-300x200.jpg"))

    for media <- imported do
      on_exit(fn -> File.rm(Entrepot.Storages.Disk.path(media.file.id)) end)
    end

    # the site's uploads folder copied here: a file of the right kind at each path the imported media name on the site
    for media <- imported do
      [_, relative] = String.split(URI.parse(media.path).path, "/wp-content/uploads/", parts: 2)
      destination = Path.join([folder, "wp-content", "uploads", URI.decode(relative)])
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(sample_file(relative).path, destination)
    end

    count = length(imported)
    assert {:ok, %{stored: ^count, not_stored: []}} = Takeover.Media.run(@sample_site, folder)

    assert Files.redir_storages()[key] == {:alias, Files.default_storage_name()}

    stored_ids = for media <- site_media.(), do: media.file.id
    assert Enum.all?(site_media.(), &(&1.path == &1.file.id))

    # every marker the imported and synced bodies hold
    bodies =
      for link <- [@synced_link | sample_links(@sample_export)],
          {:ok, %{id: id}} <- [Bonfire.Federate.ActivityPub.Peered.get_by_uri(link)],
          do: Bonfire.Common.Repo.get!(Bonfire.Data.Social.PostContent, id).html_body

    markers =
      bodies
      |> Enum.flat_map(&Regex.scan(~r{/files/redir/#{key}/[^"'\s<>?#]+}, &1))
      |> List.flatten()
      |> Enum.uniq()

    assert markers != []

    for marker <- markers do
      conn = get(build_conn(), marker)
      assert conn.status == 302, "#{marker} gave #{conn.status}"
      refute location(conn) =~ "totnespulse", "#{marker} still leads to the site"

      assert Enum.any?(stored_ids, &String.contains?(location(conn), &1)),
             "#{marker} leads to #{location(conn)}"
    end
  end

  # a file of the kind the site's path names
  defp sample_file(relative) do
    case relative |> Path.extname() |> String.downcase() do
      ext when ext in [".jpg", ".jpeg"] -> Bonfire.Files.Simulation.image_with_exif_file()
      ".mp3" -> Bonfire.Files.Simulation.audio_file()
      ".mp4" -> Bonfire.Files.Simulation.video_file()
      ".pdf" -> Bonfire.Files.Simulation.pdf_file()
      _ -> Bonfire.Files.Simulation.image_file()
    end
  end

  # the posts' links in the export, read as the import reads them
  defp sample_links(export) do
    ~r{<link>(https://www\.totnespulse\.local/[^<]+)</link>}
    |> Regex.scan(File.read!(export))
    |> Enum.map(fn [_, link] -> link end)
  end

  test "another site's media are left alone", %{me: me, uploads: uploads} do
    other_key = Posts.redir_storage("https://other.example.local")
    Posts.register_redir_storage("https://other.example.local")

    {:ok, other} =
      Files.save_url_as_media(
        me,
        "https://other.example.local/wp-content/uploads/2019/01/b.png",
        %{media_type: "image/png"}
      )

    {:ok, other} = Files.put_storage_locator(other, other_key)

    copy_upload(uploads, "2018/12/a.png")
    copy_upload(uploads, "2019/01/b.png")

    assert {:ok, %{stored: 2}} = Takeover.Media.run(@site, uploads)

    assert Bonfire.Common.Repo.reload!(other).path == other.path
    assert Files.redir_storages()[other_key] == :lookup
  end
end
