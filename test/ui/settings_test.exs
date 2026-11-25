defmodule Bonfire.WordPress.SettingsTest do
  @moduledoc """
  An instance admin sees the WordPress site this instance keeps in sync in the instance settings: the site's address, who its posts come in as, when it last synced, and the address to paste into the site's Settings > Writing so it pings Bonfire. The admin can change the site and the user. Nobody else can see or change them.
  """
  use Bonfire.WordPress.ConnCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo
  import PhoenixTest
  import Phoenix.LiveViewTest, only: [live: 2, render_hook: 3]

  @moduletag :ui

  @page "/settings/instance/bonfire_wordpress"
  @site "https://blog.example.local"

  setup do
    # instance settings also go into the app's config, which outlives each test's database rollback
    for key <- [:site_url, :auto_import_as, :last_sync, :post_into_group, :sanitise],
        do: put_setting(key, nil)

    admin_account = fake_account!()
    admin = fake_admin!(admin_account)

    account = fake_account!()
    me = fake_user!(account)

    {:ok,
     admin: admin,
     admin_conn: conn(user: admin, account: admin_account),
     me: me,
     conn: conn(user: me, account: account)}
  end

  defp put_setting(key, value) do
    Bonfire.Common.Settings.put([:bonfire_wordpress, key], value,
      scope: :instance,
      skip_boundary_check: true
    )
  end

  # read as the sync reads them
  defp stored(:site_url), do: Bonfire.WordPress.Sync.site_url()
  defp stored(:auto_import_as), do: Bonfire.WordPress.Sync.auto_import_as()

  defp ping_url, do: Bonfire.Common.URIs.base_url() <> "/wordpress/ping"

  # sends the settings form's save event, as the form does, from a page the person can open
  defp save_site_url(conn, value) do
    {:ok, view, _html} = live(conn, "/feed/my")

    render_hook(view, "Bonfire.Common.Settings:save", %{
      "bonfire_wordpress" => %{"site_url" => value},
      "scope" => "instance"
    })
  catch
    :exit, _ -> :ok
  end

  test "an admin sees the site, the user its posts come in as, the last sync, and the ping address",
       %{admin_conn: admin_conn} do
    importer = fake_user!(%{}, %{username: "wp_importer"})
    put_setting(:site_url, @site)
    put_setting(:auto_import_as, importer.id)
    put_setting(:last_sync, "2020-05-04T10:00:00Z")

    admin_conn
    |> visit(@page)
    |> wait_async()
    |> assert_has("input[value='#{@site}']")
    |> assert_has("[data-role=import_author]", text: "@wp_importer")
    |> assert_has("[data-role=last_sync]", text: "2020")
    |> assert_has("[data-role=ping_url]", text: ping_url())
  end

  test "before any import, the page says the site hasn't synced and still shows the ping address",
       %{admin_conn: admin_conn} do
    admin_conn
    |> visit(@page)
    |> wait_async()
    |> assert_has("[data-role=last_sync]", text: "Never")
    |> assert_has("[data-role=ping_url]", text: ping_url())
  end

  test "an admin changes the site and the user its posts come in as", %{admin_conn: admin_conn} do
    importer = fake_user!(%{}, %{username: "wp_new_importer"})

    admin_conn
    |> visit(@page)
    |> wait_async()
    |> within("[data-role=site_url_form]", fn session ->
      session
      |> fill_in("Site address", with: @site)
      |> submit()
    end)
    |> within("[data-role=import_author_form]", fn session ->
      session
      |> fill_in("Import as", with: importer.id)
      |> submit()
    end)

    assert stored(:site_url) == @site
    assert stored(:auto_import_as) == importer.id
  end

  describe "the group the site's posts go into" do
    setup %{admin: admin} do
      group = Bonfire.Classify.Simulate.fake_group!(admin)
      {:ok, group: group, group_name: group.profile.name}
    end

    test "an admin picks one of this instance's groups, and it's stored", %{
      admin_conn: admin_conn,
      group: group,
      group_name: group_name
    } do
      admin_conn
      |> visit(@page)
      |> wait_async()
      |> within("[data-role=group_form]", fn session ->
        select(session, group_name, from: "Post into group")
      end)

      assert Bonfire.WordPress.Sync.post_into_group() == group.id
    end

    test "the page shows the stored group as picked", %{
      admin_conn: admin_conn,
      group: group,
      group_name: group_name
    } do
      put_setting(:post_into_group, group.id)

      admin_conn
      |> visit(@page)
      |> wait_async()
      |> assert_has("[data-role=group_form] option[selected]", text: group_name)
    end

    # a value not among this instance's groups (here a topic, set before this page offered a list) stays picked, so saving the page doesn't drop it
    test "a stored value that isn't one of the listed groups shows as picked, and saving another field keeps it",
         %{admin: admin, admin_conn: admin_conn, group: group} do
      topic =
        Bonfire.Classify.Simulate.fake_category!(admin, group, %{type: :topic})

      put_setting(:post_into_group, topic.id)

      admin_conn
      |> visit(@page)
      |> wait_async()
      |> assert_has("[data-role=group_form] option[selected]", text: topic.profile.name)
      |> within("[data-role=site_url_form]", fn session ->
        session
        |> fill_in("Site address", with: @site)
        |> submit()
      end)

      assert Bonfire.WordPress.Sync.site_url() == @site
      assert Bonfire.WordPress.Sync.post_into_group() == topic.id
    end

    test "picking no group unsets it", %{admin_conn: admin_conn, group: group} do
      put_setting(:post_into_group, group.id)

      admin_conn
      |> visit(@page)
      |> wait_async()
      # an option with no value attribute would send its text ("No group") instead
      |> assert_has("[data-role=group_form] option[value='']", text: "No group")
      |> within("[data-role=group_form]", fn session ->
        select(session, "No group", from: "Post into group")
      end)

      assert Bonfire.WordPress.Sync.post_into_group() == nil
    end
  end

  describe "how the site's posts are sanitised" do
    test "keeping their structure is picked unless another choice was made", %{
      admin_conn: admin_conn
    } do
      admin_conn
      |> visit(@page)
      |> wait_async()
      |> assert_has("[data-role=sanitise_form] option[selected]", text: "Keep their structure")
    end

    test "an admin picks another choice, and it's stored", %{admin_conn: admin_conn} do
      admin_conn
      |> visit(@page)
      |> wait_async()
      |> within("[data-role=sanitise_form]", fn session ->
        select(session, "Strict: basic formatting only", from: "Sanitising")
      end)

      assert Bonfire.WordPress.Sync.sanitise() == :strict
    end

    # unsafe is only settable in config, so the form doesn't offer it
    test "unsafe isn't offered", %{admin_conn: admin_conn} do
      admin_conn
      |> visit(@page)
      |> wait_async()
      |> assert_has("[data-role=sanitise_form] option", text: "Strict: basic formatting only")
      |> refute_has("[data-role=sanitise_form] option", text: "Unsafe (no sanitising)")
      |> refute_has("[data-role=sanitise_form]", text: "could run script")
    end

    # the control is the test above it: the same event from an admin stores the choice
    test "someone who isn't an instance admin can't change it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/feed/my")

      try do
        render_hook(view, "Bonfire.Common.Settings:set", %{
          "bonfire_wordpress" => %{"sanitise" => "unsafe"},
          "scope" => "instance"
        })
      catch
        :exit, _ -> :ok
      end

      assert Bonfire.WordPress.Sync.sanitise() == :imported
    end
  end

  describe "storing the site's media here, at takeover" do
    setup %{admin: admin} do
      put_setting(:site_url, @site)
      Process.put([:bonfire_files, :storage], :local)

      previous = Application.get_env(:bonfire_files, :redir_storages)
      on_exit(fn -> Application.put_env(:bonfire_files, :redir_storages, previous) end)

      # an upload as the import makes it: pointing at the site, with a locator in the site's storage
      key = Bonfire.WordPress.Posts.redir_storage(@site)
      Bonfire.WordPress.Posts.register_redir_storage(@site)

      {:ok, media} =
        Bonfire.Files.save_url_as_media(admin, "#{@site}/wp-content/uploads/2019/01/b.png", %{
          media_type: "image/png"
        })

      {:ok, media} = Bonfire.Files.put_storage_locator(media, key)
      on_exit(fn -> File.rm(Entrepot.Storages.Disk.path(media.file.id)) end)

      folder = Path.join(System.tmp_dir!(), "takeover-#{System.unique_integer([:positive])}")
      File.mkdir_p!(folder)
      on_exit(fn -> File.rm_rf(folder) end)

      {:ok, key: key, media: media, folder: folder}
    end

    defp takeover_jobs,
      do:
        for(
          job <- all_enqueued(worker: Bonfire.Common.Import),
          job.args["op"] == "wordpress_takeover_media",
          do: job
        )

    test "an admin starts it with the copied uploads folder; a run missing a file reports it, and once the file is added a run stores it",
         %{admin_conn: admin_conn, key: key, media: media, folder: folder} do
      admin_conn
      |> visit(@page)
      |> wait_async()
      |> within("[data-role=takeover_media_form]", fn session ->
        session
        |> fill_in("Uploads folder", with: folder)
        |> submit()
      end)

      assert [job] = takeover_jobs()
      assert {:error, report} = Bonfire.Common.Import.perform(job)
      assert report =~ media.path
      assert Bonfire.Files.redir_storages()[key] == :lookup

      destination = Path.join(folder, "2019/01/b.png")
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(Bonfire.Files.Simulation.image_file().path, destination)

      assert :ok = Bonfire.Common.Import.perform(job)
      assert Bonfire.Files.redir_storages()[key] == {:alias, Bonfire.Files.default_storage_name()}
    end

    test "someone who isn't an instance admin isn't offered it, and a run queued as them stores nothing",
         %{conn: conn, me: me, media: media, folder: folder} do
      File.mkdir_p!(Path.join(folder, "2019/01"))
      File.cp!(Bonfire.Files.Simulation.image_file().path, Path.join(folder, "2019/01/b.png"))

      conn
      |> visit(@page)
      |> wait_async()
      |> refute_has("[data-role=takeover_media_form]")

      assert {:error, _} =
               Bonfire.Common.Import.perform(%Oban.Job{
                 args: %{
                   "op" => "wordpress_takeover_media",
                   "user_id" => me.id,
                   "identifier" => folder
                 }
               })

      assert Bonfire.Common.Repo.reload!(media).path == media.path
    end
  end

  # the control for the test below: the same save event, sent by an admin, stores the site
  test "the save event from an admin stores the site", %{admin_conn: admin_conn} do
    save_site_url(admin_conn, @site)

    assert stored(:site_url) == @site
  end

  test "someone who isn't an instance admin can't see the settings or change the site", %{
    conn: conn
  } do
    put_setting(:site_url, @site)

    conn
    |> visit(@page)
    |> wait_async()
    |> refute_has("[data-role=ping_url]")

    save_site_url(conn, "https://elsewhere.example.local")

    assert stored(:site_url) == @site
  end
end
