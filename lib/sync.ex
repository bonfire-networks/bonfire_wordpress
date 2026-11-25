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
  @check_op "wordpress_removal_check"
  @takeover_media_op "wordpress_takeover_media"

  # a sync already waiting isn't queued again, however many pings come in before it runs (one running doesn't count, since posts may change after it started)
  @unique [keys: [:op, :identifier], states: [:available, :scheduled], period: :infinity]

  @doc "The configured WordPress site's URL, or nil."
  def site_url, do: Config.get([:bonfire_wordpress, :site_url])

  @doc "The id of the user whose import the configured site is, or nil."
  def auto_import_as, do: Config.get([:bonfire_wordpress, :auto_import_as])

  @doc "The id of the group (or topic) the site's posts go into, or nil when unset or blank, like Ghost's `post_into_group`."
  def post_into_group do
    case Config.get([:bonfire_wordpress, :post_into_group]) do
      id when is_binary(id) and id != "" -> String.trim(id)
      _ -> nil
    end
  end

  @doc "How the body of a post imported from the site is sanitised (see `Bonfire.Common.Text.maybe_sane_html/2`): `:imported` (the default) keeps its figures, captions and block classes, `:strict` keeps only basic formatting, `:unsafe` keeps the HTML as it came."
  def sanitise do
    case Config.get([:bonfire_wordpress, :sanitise]) do
      value when value in [:strict, "strict"] -> :strict
      value when value in [:unsafe, "unsafe"] -> :unsafe
      _ -> :imported
    end
  end

  @doc "When the last sync started, as a `DateTime`, or nil."
  def last_sync, do: datetime(Config.get([:bonfire_wordpress, :last_sync]))

  defp datetime(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp datetime(_), do: nil

  @doc "When the last check for posts gone from the site ran, as a `DateTime`, or nil (see `check_removals/0`)."
  def last_removal_check, do: datetime(Config.get([:bonfire_wordpress, :last_removal_check]))

  @doc "How long after one check for posts gone from the site the next is due, in milliseconds: a day unless configured."
  def removal_check_every,
    do: Config.get([:bonfire_wordpress, :removal_check_every]) || to_timeout(day: 1)

  @doc """
  Queues a check for posts gone from the configured site (unpublished or deleted there, which sends no ping) when one is due: never checked, or checked longer than `removal_check_every/0` ago. Called on a schedule (see `Bonfire.WordPress.RemovalCheck`). Returns whether one was queued.
  """
  def check_removals do
    site = site_url()
    user_id = auto_import_as()

    if is_binary(site) and is_binary(user_id) and removal_check_due?() do
      Import.enqueue_many(@check_op, user_id, site, %{}, unique: @unique)
      true
    else
      false
    end
  end

  defp removal_check_due? do
    case last_removal_check() do
      nil -> true
      at -> DateTime.diff(DateTime.utc_now(), at, :millisecond) >= removal_check_every()
    end
  end

  @doc "Whether `site` was imported from an export, so a sync finds its uploads here and needn't ask its media API (see `mark_imported/1`)."
  def imported?(site) do
    case site_key(site) do
      key when is_binary(key) ->
        key in List.wrap(Config.get([:bonfire_wordpress, :imported_sites]))

      _ ->
        false
    end
  end

  @doc "Records that `site` was imported from an export (see `imported?/1`)."
  def mark_imported(site) do
    with key when is_binary(key) <- site_key(site),
         sites = List.wrap(Config.get([:bonfire_wordpress, :imported_sites])),
         false <- key in sites do
      put(imported_sites: [key | sites])
    end

    :ok
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

  # the same site whatever the scheme and trailing slash
  defp same_site?(a, b) when is_binary(a) and is_binary(b), do: site_key(a) == site_key(b)
  defp same_site?(_, _), do: false

  @doc "A site's URL as a key that doesn't depend on its scheme or a trailing slash, eg. `www.example.com/blog`, or nil."
  def site_key(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    case String.downcase(uri.host || "") do
      "" -> nil
      host -> host <> String.trim_trailing(uri.path || "", "/")
    end
  end

  def site_key(_), do: nil

  @impl true
  def import_ops, do: [@op, @check_op, @takeover_media_op]

  @impl true
  def import_op_label(@op), do: l("WordPress sync")
  def import_op_label(@check_op), do: l("WordPress removals check")
  def import_op_label(@takeover_media_op), do: l("WordPress media takeover")
  def import_op_label(_), do: nil

  @impl true
  def import_op_phrase(@op), do: l("Fetching changes from WordPress")
  def import_op_phrase(@check_op), do: l("Checking for posts removed from WordPress")
  def import_op_phrase(@takeover_media_op), do: l("Storing the WordPress site's media here")
  def import_op_phrase(_), do: nil

  @doc """
  Queues storing the configured site's imported media here, from `folder` (its uploads folder copied to this server, see `Bonfire.WordPress.Takeover.Media.run/2`), as `user`, who must be an instance admin. It shows in their background jobs, with what it couldn't store.
  """
  def takeover_media(user, folder) when is_binary(folder) do
    folder = String.trim(folder)

    cond do
      not Import.instance_admin?(user) -> {:error, :unauthorized}
      is_nil(site_url()) -> {:error, :no_site}
      folder == "" -> {:error, :no_folder}
      true -> Import.enqueue_many(@takeover_media_op, Bonfire.Common.Enums.id(user), folder)
    end
  end

  @doc """
  Syncs the configured site (the job's identifier): every post and podcast episode changed there since the last sync, imported as the user whose import the site is. A post already imported gets the site's edit: the site wins, so an edit made here is overwritten (see `Bonfire.WordPress.Posts.import_post/2` with `update: true`). Remembers when it started, so the next sync starts there.
  """
  @impl true
  def perform_import(@op, site, opts) do
    started = DateTime.utc_now() |> DateTime.truncate(:second)

    with true <- same_site?(site_url(), site) || {:error, :not_the_configured_site},
         {:ok, posts} <- Bonfire.WordPress.API.changed_posts(site, last_sync()) do
      # into the configured group, in the topics its categories already have there: a sync never makes topics
      group_id = post_into_group()

      # the images the posts show point at the site through this instance, as an import's do
      Bonfire.WordPress.Posts.register_redir_storage(site)

      for post <- posts do
        # as the user an import recorded for its author on this site, else as the user whose import the site is
        Bonfire.WordPress.Posts.import_post(post,
          current_user: opts[:current_user],
          post_into_group: group_id,
          site: site,
          update: true
        )
      end

      put(last_sync: DateTime.to_iso8601(started))
      :ok
    else
      {:error, _} = e -> e
      other -> error(other, "Could not sync the WordPress site")
    end
  end

  # The configured site's imported media stored here from the folder (the job's identifier), checked again to be run by an instance admin, since a job can be queued by other means. What couldn't be stored is the job's error, so it shows in the admin's background jobs, and a later run stores the rest
  def perform_import(@takeover_media_op, folder, opts) do
    with true <- Import.instance_admin?(opts[:current_user]) || {:error, :unauthorized},
         site when is_binary(site) <- site_url() || {:error, :no_site},
         {:ok, %{not_stored: []}} <- Bonfire.WordPress.Takeover.Media.run(site, folder) do
      :ok
    else
      {:ok, %{stored: stored, not_stored: not_stored}} ->
        {:error,
         l("%{stored} stored, %{count} not stored:", stored: stored, count: length(not_stored)) <>
           "\n" <>
           Enum.map_join(not_stored, "\n", &"#{&1.url} (#{inspect(&1.reason)})")}

      {:error, _} = e ->
        e
    end
  end

  # The configured site (the job's identifier) checked for posts gone from it: the imported posts it no longer publishes are hidden (see `Bonfire.WordPress.Posts.hide_gone/2`). A list the site can't give whole hides nothing, and the check stays due, so the next scheduled run tries again
  def perform_import(@check_op, site, _opts) do
    started = DateTime.utc_now() |> DateTime.truncate(:second)

    with true <- same_site?(site_url(), site) || {:error, :not_the_configured_site},
         {:ok, links} <- Bonfire.WordPress.API.published_links(site),
         {:ok, hidden} <- Bonfire.WordPress.Posts.hide_gone(site, links) do
      info(hidden, "Imported posts hidden, gone from the WordPress site")
      put(last_removal_check: DateTime.to_iso8601(started))
    else
      {:error, :not_the_configured_site} = e ->
        e

      other ->
        warn(other, "Could not list the WordPress site's posts, so none is hidden")
        :ok
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
