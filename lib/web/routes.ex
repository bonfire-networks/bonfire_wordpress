defmodule Bonfire.WordPress.Web.Routes do
  @moduledoc "Routes for the WordPress extension."
  @behaviour Bonfire.UI.Common.RoutesModule

  defmacro __using__(_) do
    quote do
      # WordPress's "update services" ping (Settings > Writing on the site): server to server, so outside the :browser pipeline (no CSRF token, no content negotiation, since it's XML-RPC)
      scope "/wordpress", Bonfire.WordPress.Web do
        pipe_through(:basic)

        post("/ping", PingController, :ping)
      end
    end
  end
end
