defmodule Bonfire.WordPress.Web.SettingsLive do
  @moduledoc """
  The instance settings of the WordPress site this instance keeps in sync (`Bonfire.WordPress.Sync`): its address, the user its posts come in as, when it last synced, and the address the site pings (its Settings > Writing, "Update Services").

  Only an instance admin sees the settings: they show on the instance settings page, which checks that too, and the component checks it again in case it is rendered elsewhere.
  """
  use Bonfire.UI.Common.Web, :stateful_component

  declare_settings_component(l("WordPress"),
    icon: "bi:wordpress",
    description: l("The WordPress site this instance keeps in sync"),
    scope: :instance,
    data: %{}
  )

  prop scope, :any, default: nil

  # fail closed: only set once the viewer is confirmed to be an instance admin
  data authorized, :boolean, default: false
  data site_url, :string, default: nil
  data auto_import_as, :string, default: nil
  data import_author, :any, default: nil
  data last_sync, :any, default: nil
  data ping_url, :string, default: nil
  data post_into_group, :string, default: nil
  data group_options, :list, default: []

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if Bonfire.Boundaries.can?(current_user(socket), :configure, :instance) == true do
      auto_import_as = Bonfire.WordPress.Sync.auto_import_as()
      post_into_group = Bonfire.WordPress.Sync.post_into_group()

      {:ok,
       assign(socket,
         authorized: true,
         site_url: Bonfire.WordPress.Sync.site_url(),
         auto_import_as: auto_import_as,
         import_author: import_author(auto_import_as),
         last_sync: Bonfire.WordPress.Sync.last_sync(),
         ping_url: ping_url(),
         post_into_group: post_into_group,
         # one query listing this instance's groups on every update
         group_options:
           Bonfire.Classify.Categories.local_group_options(post_into_group,
             current_user: current_user(socket),
             no_value_label: l("No group")
           )
       )}
    else
      {:ok, assign(socket, authorized: false)}
    end
  end

  # `Bonfire.WordPress.Sync.takeover_media/2` checks again that it's an instance admin
  def handle_event("takeover_media", %{"folder" => folder}, socket) do
    case Bonfire.WordPress.Sync.takeover_media(current_user(socket), folder) do
      {:error, :no_folder} ->
        {:noreply, assign_error(socket, l("Please give the path of the copied uploads folder"))}

      {:error, _} = e ->
        {:noreply, assign_error(socket, Bonfire.Common.Errors.error_msg(e))}

      _ ->
        {:noreply,
         assign_flash(
           socket,
           :info,
           l("Started storing the site's media: see the background jobs for its progress")
         )}
    end
  end

  @doc "The address the site pings when a post is published or edited, to paste into its Settings > Writing."
  def ping_url, do: Bonfire.Common.URIs.base_url() <> "/wordpress/ping"

  @doc "When the site last synced, as a date, or nil if it never has."
  def format_last_sync(nil), do: nil

  def format_last_sync(last_sync) do
    case Bonfire.Common.DatesTimes.to_date_time(last_sync) do
      %DateTime{} = dt -> Bonfire.Common.DatesTimes.format_date(dt)
      _ -> nil
    end
  end

  defp import_author(id) when is_binary(id) and id != "" do
    case Bonfire.Me.Users.by_id(id) do
      {:ok, user} -> user
      _ -> nil
    end
  end

  defp import_author(_), do: nil
end
