defmodule Bonfire.WordPress.Web.PingController do
  @moduledoc """
  Takes WordPress's "update services" ping (an XML-RPC `weblogUpdates.ping` or `extendedPing`) and hands its site's home URL to `Bonfire.WordPress.Sync.ping/1`. Every readable ping gets the same thanks, whether or not its site is the one configured, so the answer reveals nothing.
  """
  use Bonfire.UI.Common.Web, :controller

  alias Bonfire.WordPress.XMLRPC

  # a ping is a few hundred bytes
  @max_body 64_000

  def ping(conn, _params) do
    reply =
      with {:ok, body, _conn} <- Plug.Conn.read_body(conn, length: @max_body, read_length: @max_body),
           {:ok, %{home_url: home_url}} <- XMLRPC.parse_ping(body) do
        Bonfire.WordPress.Sync.ping(home_url)
        XMLRPC.thanks()
      else
        _ -> XMLRPC.fault()
      end

    conn
    |> Plug.Conn.put_resp_content_type("text/xml")
    |> Plug.Conn.send_resp(200, reply)
  end
end
