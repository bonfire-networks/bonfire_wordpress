defmodule Bonfire.WordPress.ImportFormTest do
  @moduledoc """
  A person picks "WordPress export" as the import type in the import settings, uploads the export file, and sees what it holds and what importing it will do before importing anything. Importing then starts in the background.

  Anyone can import an export into their own account, and every post comes in as theirs. Only an instance admin is offered a user for each of the site's authors.
  """
  use Bonfire.WordPress.ConnCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo
  import Swoosh.TestAssertions

  alias Bonfire.Common.Import

  @moduletag :ui

  # the upload form, the only multipart one on the page
  @import_form "form[enctype='multipart/form-data']"
  @archive_form "#archive_import_form"
  @fixture Path.expand("../fixtures/totnespulse_subset.xml", __DIR__)

  # the fixture's published posts and podcast episode, and the emails of their authors in the export (the last one has no author)
  @posts [
    {"https://www.totnespulse.local/s-h-d-c-flies-in-the-face-of-best-practice/",
     "john-anderson@totnespulse.local"},
    {"https://www.totnespulse.local/totnes-gives-you-xxtra/",
     "the-totnes-pulse@totnespulse.local"},
    {"https://www.totnespulse.local/podcast/totnes-talks-finlay-porter/",
     "tony-gee@totnespulse.local"},
    {"https://www.totnespulse.local/totnes-market-square-from-major-renovation-to-patch-repairs/",
     nil}
  ]

  setup do
    # the outbox and archive import types are offered only when federating
    Process.put(:federating, true)
    # no request should reach a real site
    Tesla.Mock.mock_global(fn _ -> %Tesla.Env{status: 404, body: ""} end)

    account = fake_account!()
    me = fake_user!(account)

    admin_account = fake_account!()
    admin = fake_admin!(admin_account)

    {:ok,
     conn: conn(user: me, account: account),
     me: me,
     admin_conn: conn(user: admin, account: admin_account),
     admin: admin}
  end

  defp upload_export(conn, type) do
    {:ok, view, _html} = live(conn, "/settings/user/import")

    view
    |> form(@import_form, %{"type" => type})
    |> render_change()

    view
    |> file_input(@import_form, :file, [
      %{name: "export.xml", content: File.read!(@fixture), type: "text/xml"}
    ])
    |> render_upload("export.xml")

    # staging reads the file in the background
    {view, render_async(view)}
  end

  # the import jobs queued, leaving out the staged dir's cleanup, which staging always queues
  defp queued_ops,
    do:
      for(
        job <- all_enqueued(worker: Import),
        job.args["op"] != "archive_cleanup",
        do: job.args["op"]
      )

  # runs the queued jobs of `op` here (tests queue them without running them, unless federating)
  defp run_jobs(op),
    do: for(job <- all_enqueued(worker: Import), job.args["op"] == op, do: Import.perform(job))

  # submits the checklist, then runs the import as the background would: its preparing job, then the post jobs that queues
  defp import_posts(view, params \\ %{"keys" => ["posts"]}) do
    html = view |> form(@archive_form) |> render_submit(params)

    run_jobs("import_materialize")
    run_jobs("wordpress_import")

    html
  end

  defp creator_of(link) do
    assert {:ok, %{id: id}} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(link)
    Bonfire.Common.Repo.get!(Bonfire.Data.Social.Created, id).creator_id
  end

  defp no_account_for_authors! do
    for {_link, email} <- @posts, email do
      refute Bonfire.Me.Accounts.get_by_email(email), "expected no account for #{email}"
    end
  end

  test "the import type dropdown offers a WordPress export", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/settings/user/import")

    assert has_element?(view, "#{@import_form} select option[value=wordpress]")
  end

  test "a WordPress export lists its posts to import, pages greyed as not imported yet, and what it leaves out",
       %{conn: conn} do
    {view, html} = upload_export(conn, "wordpress")

    assert html =~ "What to import"
    assert has_element?(view, "#{@archive_form} input[type=checkbox][value=posts][checked]")
    assert has_element?(view, "#{@archive_form} label", "Posts (4)")
    assert has_element?(view, "#{@archive_form} input[type=checkbox][value=pages][disabled]")
    assert has_element?(view, "#{@archive_form} label", "Pages aren't imported yet")
    # what the export holds that won't come in, said before importing
    assert has_element?(view, @archive_form, "Drafts: skipping 1")
    assert has_element?(view, @archive_form, "Password-protected posts: skipping 1")
    # boosts are a Mastodon archive's, a WordPress site has none
    refute has_element?(view, "#{@archive_form} input[value=include_boosts]")
  end

  test "someone who isn't an instance admin isn't offered a user for each author",
       %{conn: conn} do
    {view, _html} = upload_export(conn, "wordpress")

    refute has_element?(view, "#{@archive_form} input[value=create_author_users]")
    refute has_element?(view, @archive_form, "Create a user for each author")
  end

  test "an instance admin is offered a user for each author, ticked, with how many are new",
       %{admin_conn: conn} do
    {view, _html} = upload_export(conn, "wordpress")

    assert has_element?(
             view,
             "#{@archive_form} input[type=checkbox][value=create_author_users][checked]"
           )

    assert has_element?(
             view,
             "#{@archive_form} label",
             "Create a user for each author (3 new, 0 existing accounts)"
           )
  end

  test "importing starts in the background: the click queues one job preparing the import, which queues the posts",
       %{admin_conn: conn} do
    {view, _html} = upload_export(conn, "wordpress")

    html = view |> form(@archive_form) |> render_submit(%{"keys" => ["posts"]})

    assert html =~ "Import started"
    assert queued_ops() == ["import_materialize"]

    run_jobs("import_materialize")

    assert Enum.count(queued_ops(), &(&1 == "wordpress_import")) == 4
  end

  test "an admin importing with a user for each author gets each author's posts by their own user",
       %{admin_conn: conn, admin: admin} do
    {view, _html} = upload_export(conn, "wordpress")
    import_posts(view)

    creators =
      for {link, email} <- @posts, email do
        assert %{} = account = Bonfire.Me.Accounts.get_by_email(email)
        assert [%{id: user_id}] = Bonfire.Me.Users.by_account!(account)
        assert creator_of(link) == user_id
        user_id
      end

    assert length(Enum.uniq(creators)) == 3
    # the post with no author is the importer's
    assert creator_of(elem(List.last(@posts), 0)) == admin.id
    # the authors' accounts are made quietly, for them to claim later
    assert_no_email_sent()
  end

  test "an admin unticking it gets every post as their own, and no accounts are made",
       %{admin_conn: conn, admin: admin} do
    {view, _html} = upload_export(conn, "wordpress")
    # no option ticked (an empty value matches none)
    import_posts(view, %{"keys" => ["posts"], "options" => [""]})

    for {link, _email} <- @posts, do: assert(creator_of(link) == admin.id)
    no_account_for_authors!()
  end

  test "someone who isn't an instance admin gets every post as their own, and no accounts are made",
       %{conn: conn, me: me} do
    {view, _html} = upload_export(conn, "wordpress")
    import_posts(view)

    for {link, _email} <- @posts, do: assert(creator_of(link) == me.id)
    no_account_for_authors!()
  end

  test "the option sent anyway by someone who isn't an instance admin is ignored",
       %{conn: conn, me: me} do
    {view, _html} = upload_export(conn, "wordpress")
    import_posts(view, %{"keys" => ["posts"], "options" => ["create_author_users"]})

    for {link, _email} <- @posts, do: assert(creator_of(link) == me.id)
    no_account_for_authors!()
  end

  test "uploading an export already imported says so before importing again", %{conn: conn} do
    {view, _html} = upload_export(conn, "wordpress")
    import_posts(view)

    {view, _html} = upload_export(conn, "wordpress")

    assert has_element?(view, @archive_form, "Posts: 4 already imported")
  end

  test "a WordPress export uploaded as an account archive is refused, with nothing staged",
       %{conn: conn} do
    {view, html} = upload_export(conn, "archive")

    refute has_element?(view, @archive_form)
    assert html =~ "not a zip archive"
  end
end
