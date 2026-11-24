defmodule Bonfire.WordPress.SettingsTest do
  @moduledoc """
  An instance admin sees the WordPress site this instance keeps in sync in the instance settings: the site's address, who its posts come in as, when it last synced, and the address to paste into the site's Settings > Writing so it pings Bonfire. The admin can change the site and the user. Nobody else can see or change them.
  """
  use Bonfire.WordPress.ConnCase, async: false
  import PhoenixTest
  import Phoenix.LiveViewTest, only: [live: 2, render_hook: 3]

  @moduletag :ui

  @page "/settings/instance/bonfire_wordpress"
  @site "https://blog.example.local"

  setup do
    # instance settings also go into the app's config, which outlives each test's database rollback
    for key <- [:site_url, :auto_import_as, :last_sync, :post_into_group],
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
