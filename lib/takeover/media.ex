defmodule Bonfire.WordPress.Takeover.Media do
  @moduledoc """
  Stores the files of a WordPress site's imported `Media` here, at takeover, from a copy of the site's uploads folder on the server (see `run/2`).

  An import makes a `Media` for each upload a post shows, pointing at the file on the site, with a locator in the site's `/files/redir` storage (see `Bonfire.WordPress.Posts.redir_storage/1`), which a lookup resolves to the site while it's up. This gives each of them its file, resized as an upload of its type is, in this instance's storage at its locator's path (`Bonfire.Files.store_at/3`), and only once all of them are stored makes the site's key an alias of this instance's storage, so the bodies' markers lead to the stored files with no lookup. Only the resized copy is kept, so the copied folder can be removed afterwards.

  Run when an instance admin decides, not at startup: it isn't registered as a migration.
  """
  use Bonfire.Common.Utils
  alias EctoSparkles.DataMigration
  use DataMigration

  alias Bonfire.Files

  @doc """
  Stores the files of `site`'s imported `Media` that aren't stored yet, each found in `folder` (the site's `wp-content/uploads` folder copied to this server, or the site's root folder holding it): from the upload's original when the folder has it, else the size the post shows. Never fetched from the site.

  Returns `{:ok, %{stored: count, not_stored: [%{id:, url:, reason:}]}}`. A `Media` whose file isn't in the folder (or can't be stored) is reported, and the others are still stored; the site's key becomes an alias of this instance's storage only when none of its `Media` is left to store, so a later run, once the missing files are added, finishes it.
  """
  def run(site, folder) when is_binary(folder) do
    with storage when is_binary(storage) <-
           Bonfire.WordPress.Posts.redir_storage(site) || {:error, :no_site},
         true <- File.dir?(folder) || {:error, :no_folder},
         {:ok, report} <- Agent.start_link(fn -> %{stored: 0, not_stored: []} end) do
      DataMigration.Runner.run(__MODULE__, storage: storage, folder: folder, report: report)

      %{stored: stored, not_stored: not_stored} = Agent.get(report, & &1)
      Agent.stop(report)

      # every one stored (not only those this run tried: a batch that failed as a whole isn't in the report)
      if not Bonfire.WordPress.repo().exists?(base_query(storage: storage)),
        do: alias_storage(storage)

      {:ok, %{stored: stored, not_stored: Enum.reverse(not_stored)}}
    end
  end

  # the site's markers now lead to the stored files with no lookup (see `Bonfire.Files.redir_url/2`): overwriting the lookup, which `Bonfire.WordPress.Posts.register_redir_storage/1` leaves as it is
  defp alias_storage(storage) do
    Bonfire.Common.Settings.put(
      [:bonfire_files, :redir_storages],
      Map.put(Files.redir_storages(), storage, {:alias, Files.default_storage_name()}),
      scope: :instance,
      skip_boundary_check: true
    )
  end

  # the site's `Media` not stored yet: their locator names the site's storage while their `path` is still elsewhere. One instance's takeover, run once, so a scan of the locators per batch is acceptable
  @impl DataMigration
  def base_query(opts) do
    from(m in Bonfire.Files.Media,
      where:
        fragment("?->>'storage'", m.file) == ^opts[:storage] and is_nil(m.deleted_at) and
          m.path != fragment("?->>'id'", m.file),
      select: %{id: m.id}
    )
  end

  @impl DataMigration
  def config(_opts) do
    %DataMigration.Config{
      # in the caller's process, which waits for the report
      async: false,
      batch_size: Config.get([__MODULE__, :batch_size], 50, :bonfire_wordpress),
      throttle_ms: Config.get([__MODULE__, :throttle_ms], 0, :bonfire_wordpress),
      repo: Bonfire.WordPress.repo(),
      first_id: "00000000000000000000000000"
    }
  end

  @impl DataMigration
  def migrate(rows, opts) do
    ids = Enum.map(rows, & &1.id)

    for media <- Bonfire.WordPress.repo().all(from(m in Bonfire.Files.Media, where: m.id in ^ids)) do
      result =
        case source_path(media, opts[:folder]) do
          nil -> {:error, :missing_file}
          path -> Files.store_at(media, path)
        end

      case result do
        {:ok, _} ->
          Agent.update(opts[:report], &Map.update!(&1, :stored, fn n -> n + 1 end))

        {:error, reason} ->
          warn(reason, "Could not store the file of #{media.path}")

          Agent.update(
            opts[:report],
            &Map.update!(&1, :not_stored, fn list ->
              [%{id: media.id, url: media.path, reason: reason} | list]
            end)
          )
      end
    end

    :ok
  end

  # the file in `folder` for one of the media's URLs on the site: an original (with no `-<width>x<height>` WordPress gives the sizes it makes) first, since only the resized copy is kept
  defp source_path(media, folder) do
    {originals, sizes} =
      [media.path | List.wrap(e(media, :metadata, "urls", []))]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.split_with(&(not Regex.match?(~r/-\d+x\d+\.\w+$/, &1)))

    Enum.find_value(originals ++ sizes, fn url ->
      with relative when is_binary(relative) <- uploads_relative(url) do
        Enum.find(
          [Path.join(folder, relative), Path.join([folder, "wp-content", "uploads", relative])],
          &File.regular?/1
        )
      end
    end)
  end

  # the path of an upload's URL within the site's uploads folder, eg. `2018/12/a.jpg`; nil for anything else, or a path that climbs out of it
  defp uploads_relative(url) do
    with %{path: "/" <> _ = path} <- URI.parse(url),
         [_, relative] <- String.split(path, "/wp-content/uploads/", parts: 2),
         relative = URI.decode(relative),
         false <- relative == "" or ".." in Path.split(relative) do
      relative
    else
      _ -> nil
    end
  end
end
