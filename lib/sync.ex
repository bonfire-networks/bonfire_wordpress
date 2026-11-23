defmodule Bonfire.WordPress.Sync do
  @moduledoc """
  Keeps an imported WordPress site in sync: the site pings Bonfire through WordPress's "update services" (Settings > Writing), on publishing or editing a post, and Bonfire fetches what changed since its last sync through the site's REST API (`Bonfire.WordPress.API`), importing each post with `Bonfire.WordPress.Posts.import_post/2`.

  One site per instance, like Ghost's (`Bonfire.Ghost`), in config read with `Config.get`: `site_url`, `auto_import_as` (the user whose import it is, who the posts come in as) and `last_sync`. The export import fills in the first two (see `remember_site/2`), and the sync job updates the last.

  The ping isn't authenticated, but all it can do is make Bonfire fetch from the configured site, from the site itself.
  """
  @behaviour Bonfire.Common.ImportModule

  use Bonfire.Common.Config
  use Bonfire.Common.Localise
  import Untangle

  alias Bonfire.Common.Import

  @op "wordpress_sync"

  # a sync already waiting isn't queued again, however many pings come in before it runs (one running doesn't count, since posts may change after it started)
  @unique [keys: [:op, :identifier], states: [:available, :scheduled], period: :infinity]

  @doc "The configured WordPress site's URL, or nil."
  def site_url, do: Config.get([:bonfire_wordpress, :site_url])

  @doc "The id of the user whose import the configured site is, or nil."
  def auto_import_as, do: Config.get([:bonfire_wordpress, :auto_import_as])

  @doc "When the last sync started, as a `DateTime`, or nil."
  def last_sync do
    case Config.get([:bonfire_wordpress, :last_sync]) do
      at when is_binary(at) ->
        case DateTime.from_iso8601(at) do
          {:ok, at, _} -> at
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Configures `site` as the instance's WordPress site, imported by `user`, if no site is configured yet or it's the same site. A different configured site is left as it is (returns `{:error, :other_site}`), so one import can't silently replace another's sync.
  """
  def remember_site(site, user) when is_binary(site) do
    case site_url() do
      nil -> put(site_url: site, auto_import_as: Bonfire.Common.Enums.id(user))
      configured -> if same_site?(configured, site), do: :ok, else: {:error, :other_site}
    end
  end

  def remember_site(_, _), do: {:error, :no_site}

  @doc """
  Takes a ping from a site: queues a sync when `home_url` is the configured site's (`:queued`), else does nothing (`:ignored`).
  """
  def ping(home_url) do
    site = site_url()
    user_id = auto_import_as()

    if is_binary(site) and is_binary(user_id) and same_site?(site, home_url) do
      Import.enqueue_many(@op, user_id, site, %{}, unique: @unique)
      :queued
    else
      :ignored
    end
  end

  # the same site whatever the scheme, `www.` aside, and trailing slash
  defp same_site?(a, b) when is_binary(a) and is_binary(b), do: site_key(a) == site_key(b)
  defp same_site?(_, _), do: false

  defp site_key(url) do
    uri = URI.parse(String.trim(url))
    {String.downcase(uri.host || ""), String.trim_trailing(uri.path || "", "/")}
  end

  @impl true
  def import_ops, do: [@op]

  @impl true
  def import_op_label(@op), do: l("WordPress sync")
  def import_op_label(_), do: nil

  @impl true
  def import_op_phrase(@op), do: l("Fetching changes from WordPress")
  def import_op_phrase(_), do: nil

  @doc """
  Syncs the configured site (the job's identifier): every post and podcast episode changed there since the last sync, imported as the user whose import the site is. Posts already imported are left as they are (`Bonfire.WordPress.Posts.import_post/2` says so). Remembers when it started, so the next sync starts there.
  """
  @impl true
  def perform_import(@op, site, opts) do
    started = DateTime.utc_now() |> DateTime.truncate(:second)

    with true <- same_site?(site_url(), site) || {:error, :not_the_configured_site},
         {:ok, posts} <- Bonfire.WordPress.API.changed_posts(site, last_sync()) do
      for post <- posts do
        Bonfire.WordPress.Posts.import_post(post, current_user: opts[:current_user])
      end

      put(last_sync: DateTime.to_iso8601(started))
      :ok
    else
      {:error, _} = e -> e
      other -> error(other, "Could not sync the WordPress site")
    end
  end

  defp put(settings) do
    Enum.each(settings, fn {key, value} ->
      Bonfire.Common.Settings.put([:bonfire_wordpress, key], value,
        scope: :instance,
        skip_boundary_check: true
      )
    end)

    :ok
  end
end
