defmodule Bonfire.WordPress.Web.PingControllerTest do
  @moduledoc """
  WordPress's "update services" ping (Settings > Writing on the site) reaches `POST /wordpress/ping` as XML-RPC, with no session or CSRF token, and gets the XML-RPC answer WordPress expects.
  """
  use Bonfire.WordPress.ConnCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo

  @moduletag :ui

  @site "https://www.totnespulse.local"

  setup do
    importer = Bonfire.Me.Fake.fake_user!()
    Process.put([:bonfire_wordpress, :site_url], @site)
    Process.put([:bonfire_wordpress, :auto_import_as], importer.id)
    :ok
  end

  defp ping(body) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("content-type", "text/xml")
    |> post("/wordpress/ping", body)
  end

  defp sync_jobs,
    do: for(job <- all_enqueued(worker: Bonfire.Common.Import), job.args["op"] == "wordpress_sync", do: job)

  defp extended_ping(home),
    do: """
    <?xml version="1.0"?>
    <methodCall><methodName>weblogUpdates.extendedPing</methodName>
    <params>
    <param><value><string>Totnes Pulse</string></value></param>
    <param><value><string>#{home}</string></value></param>
    <param><value><string>#{home}/a-new-post/</string></value></param>
    <param><value><string>#{home}/feed/</string></value></param>
    </params></methodCall>
    """

  test "a ping from the configured site is thanked and queues a sync" do
    conn = ping(extended_ping(@site))

    assert conn.status == 200
    assert response(conn, 200) =~ "<methodResponse>"
    assert response(conn, 200) =~ "<name>flerror</name><value><boolean>0</boolean></value>"
    assert [_] = sync_jobs()
  end

  test "a ping from another site is thanked the same way, and queues nothing" do
    conn = ping(extended_ping("https://elsewhere.local"))

    assert response(conn, 200) =~ "<boolean>0</boolean>"
    assert sync_jobs() == []
  end

  test "a ping with a DTD gets a fault and queues nothing" do
    conn =
      ping("""
      <?xml version="1.0"?>
      <!DOCTYPE methodCall [<!ENTITY x "y">]>
      <methodCall><methodName>weblogUpdates.ping</methodName>
      <params><param><value><string>&x;</string></value></param>
      <param><value><string>#{@site}</string></value></param></params></methodCall>
      """)

    assert response(conn, 200) =~ "<fault>"
    assert sync_jobs() == []
  end
end
