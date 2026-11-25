defmodule Bonfire.WordPress.Import.WXRImportIntegrationTest do
  @moduledoc """
  Imports a whole WordPress export, to try the import on a real site before running it for real: opt-in, since it needs a real export file, which never goes in the repo (it holds people's emails).

  Run with `WXR_FULL_EXPORT=/path/to/export.xml just test extensions/bonfire_wordpress/test/import/wxr_import_integration_test.exs --include integration`. Bodies come from each post's own export text, as when the site's REST API is unavailable, unless `WXR_FULL_LIVE=1` lets the import ask the live site. Media files are never fetched.

  It checks that staging keeps memory in check, that the checklist's counts match the file's, and that every post's job succeeds, and prints the timings. It prints only ids, counts and timings, never post content or emails.

  Then, as a site is brought over for real, it imports the export first with the strict sanitiser, re-imports it with the `imported` one and updates on (`update_imported`), and takes the site over: each imported `Media` gets its file from a copy of the site's uploads folder (`Bonfire.WordPress.Takeover.Media`). The copy is `WXR_FULL_UPLOADS` (the site's `wp-content/uploads`, or its root folder) when set; else, live only, this test downloads each media's file from the site into a temporary folder first, which takeover itself never does. Without either, takeover is skipped.
  """
  use Bonfire.WordPress.DataCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]
  import Ecto.Query, only: [from: 2]
  require Bonfire.Common.Config

  alias Bonfire.Common.Import
  alias Bonfire.WordPress.Import.WXR
  alias Bonfire.WordPress.Takeover

  @endpoint Application.compile_env!(:bonfire, :endpoint_module)

  # a file this big isn't downloaded for the takeover (podcast episodes are 12-74 MB)
  @max_download 100 * 1024 * 1024

  @moduletag :integration
  @moduletag timeout: :infinity

  if not File.regular?(System.get_env("WXR_FULL_EXPORT") || "") do
    @moduletag skip: "set WXR_FULL_EXPORT to a WordPress export file to run this"
  end

  # a generous bound for staging a big export, which streams it one item at a time
  @max_staging_growth 300 * 1024 * 1024

  defp export_path, do: System.get_env("WXR_FULL_EXPORT")
  defp live?, do: System.get_env("WXR_FULL_LIVE") in ["1", "true", "yes"]
  defp uploads_copy, do: System.get_env("WXR_FULL_UPLOADS")

  # a real GET of a REST API URL, with OTP's own HTTP client, verifying the site's certificate, answered as the Tesla env the import expects
  defp live_get(%Tesla.Env{url: url, query: query}) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    full_url = if query in [nil, []], do: url, else: url <> "?" <> URI.encode_query(query)

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(:get, {String.to_charlist(full_url), []}, [ssl: ssl, timeout: 60_000],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, headers, body}} ->
        %Tesla.Env{
          url: url,
          status: status,
          headers: for({k, v} <- headers, do: {to_string(k), to_string(v)}),
          body: body
        }

      {:error, reason} ->
        flunk("live REST request failed: #{inspect(reason)}")
    end
  end

  setup do
    # a whole export takes longer than the test sandbox lets a test own its connection (`ownership_timeout`, 100 s), so this test owns one for as long as it runs, shared with the processes it spawns as usual
    repo = Bonfire.Common.Repo
    Ecto.Adapters.SQL.Sandbox.checkin(repo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo, sandbox: true, ownership_timeout: :infinity)
    Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})

    {:ok, media_requests} = Agent.start_link(fn -> [] end)
    {:ok, rest_statuses} = Agent.start_link(fn -> [] end)

    # every request goes through this mock, also when live: tests can't reach the network through Tesla (its adapter is the mock, and the SSRF guard's test resolver points every host at a placeholder address)
    Tesla.Mock.mock_global(fn
      %{url: url} = env ->
        cond do
          # a media file on the site: never downloaded, the media stays where it is
          String.contains?(url, "/wp-content/uploads/") ->
            Agent.update(media_requests, &[url | &1])
            %Tesla.Env{status: 404, body: ""}

          # the site's REST API: fetched for real when live, else unavailable, so each body comes from the export
          String.contains?(url, "/wp-json/") ->
            response = if live?(), do: live_get(env), else: %Tesla.Env{status: 500, body: ""}
            Agent.update(rest_statuses, &[response.status | &1])
            response

          # anything else, eg. unfurling an embedded player: no network, so it falls back to a bare link
          true ->
            %Tesla.Env{status: 404, body: ""}
        end
    end)

    {:ok, media_requests: media_requests, rest_statuses: rest_statuses}
  end

  test "a whole export imports every published post, with memory in check, then re-imports with updates, and is taken over",
       %{
         media_requests: media_requests,
         rest_statuses: rest_statuses
       } do
    # the import and the takeover put these in the instance's settings, which go into the app's config and outlive the test's database rollback
    previous_wordpress =
      for key <- [:imported_sites, :last_sync, :site_url, :auto_import_as],
          do: {key, Bonfire.Common.Config.get([:bonfire_wordpress, key])}

    previous_redir = Application.get_env(:bonfire_files, :redir_storages)

    on_exit(fn ->
      for {key, value} <- previous_wordpress,
          do: Bonfire.Common.Config.put([:bonfire_wordpress, key], value)

      Application.put_env(:bonfire_files, :redir_storages, previous_redir)
    end)

    # the first import with the strict sanitiser, as before the `imported` one existed
    Process.put([:bonfire_wordpress, :sanitise], :strict)

    path = export_path()
    expected = scan(path)

    report("expected from the file", %{
      posts: expected.posts,
      pages: expected.pages,
      skipped: expected.skipped
    })

    memory_before = :erlang.memory(:total)
    {stage_us, {:ok, staged}} = :timer.tc(fn -> WXR.stage(path) end)
    on_exit(fn -> File.rm_rf(staged.dir) end)
    memory_after = :erlang.memory(:total)
    {:memory, process_memory} = Process.info(self(), :memory)

    report("staging", %{
      seconds: seconds(stage_us),
      beam_memory_growth_mb: mb(memory_after - memory_before),
      test_process_memory_mb: mb(process_memory)
    })

    assert memory_after - memory_before < @max_staging_growth

    # the checklist says what the file holds
    items = Map.new(staged.items, &{&1.key, &1})
    assert %{count: posts} = items[:posts]
    assert posts == expected.posts
    assert ((items[:pages] && items[:pages].count) || 0) == expected.pages
    assert staged.skipped == expected.skipped

    # as an instance admin, with a user for each author
    admin = Bonfire.UI.Common.Testing.Helpers.fake_admin!()

    assert {:ok, _} = Import.queue_import(admin, staged, [:posts], ["create_author_users"])

    {post_jobs, failures} = run_jobs("importing (strict sanitiser)", staged.dir)

    assert length(post_jobs) == expected.posts
    assert failures == []

    assert Agent.get(media_requests, & &1) == []

    if live?(), do: assert_bodies_from_the_site(staged.dir, Agent.get(rest_statuses, & &1))

    # From here on, what goes wrong is collected and asserted at the end, so one run reports on every pass
    site = staged.base_site_url
    posts_before = site_posts(site)
    report("imported posts on record", %{posts: map_size(posts_before)})

    problems =
      reimport(admin, path, site, posts_before, expected, media_requests, rest_statuses) ++
        takeover(site)

    Enum.each(problems, &IO.puts("  problem: #{&1}"))
    assert problems == []
  end

  # the queued materialize job for the staged `dir`, then its post jobs, each run here (tests queue them without running them); earlier passes' jobs stay enqueued, so jobs are picked by their staged dir
  defp run_jobs(label, dir) do
    {prepare_us, _} =
      :timer.tc(fn ->
        for job <- all_enqueued(worker: Import),
            job.args["op"] == "import_materialize",
            job.args["dir"] == dir do
          result = Import.perform(job)
          assert result == :ok or match?({:ok, _}, result)
        end
      end)

    post_jobs =
      for job <- all_enqueued(worker: Import),
          job.args["op"] == "wordpress_import",
          job.args["dir"] == dir,
          do: job

    {jobs_us, failures} =
      :timer.tc(fn ->
        for job <- post_jobs, reduce: [] do
          failures ->
            case Import.perform(job) do
              {:ok, _} -> failures
              :ok -> failures
              other -> [{job.args["wp_id"], describe(other)} | failures]
            end
        end
      end)

    report(label, %{
      prepare_seconds: seconds(prepare_us),
      post_jobs: length(post_jobs),
      jobs_seconds: seconds(jobs_us),
      failed: length(failures)
    })

    failures
    |> Enum.group_by(fn {_id, error} -> error end, fn {id, _} -> id end)
    |> Enum.each(fn {error, ids} ->
      IO.puts(
        "  #{length(ids)} failed with #{error} (eg. post ids #{ids |> Enum.take(5) |> Enum.join(", ")})"
      )
    end)

    {post_jobs, failures}
  end

  # The same export again, with the `imported` sanitiser and updates on, staged afresh since the option is only offered once some posts are imported: no post made twice, every job succeeds, and how many posts it edited
  defp reimport(admin, path, site, posts_before, expected, media_requests, rest_statuses) do
    Process.put([:bonfire_wordpress, :sanitise], :imported)
    Agent.update(rest_statuses, fn _ -> [] end)

    {:ok, staged} = WXR.stage(path)
    on_exit(fn -> File.rm_rf(staged.dir) end)

    posts_item = Enum.find(Import.staged_items(staged), &(&1.key == :posts))

    offered? =
      posts_item != nil and
        :update_imported in Enum.map(Import.offered_options(posts_item, admin), & &1.key)

    {:ok, _} =
      Import.queue_import(admin, staged, [:posts], ["create_author_users", "update_imported"])

    {post_jobs, failures} = run_jobs("re-importing (imported sanitiser, updates on)", staged.dir)

    posts_after = site_posts(site)
    edited = Enum.count(posts_before, fn {id, hash} -> posts_after[id] != hash end)

    report("re-import", %{
      posts_before: map_size(posts_before),
      posts_after: map_size(posts_after),
      edited: edited,
      unchanged: map_size(posts_before) - edited
    })

    bodies_problems =
      if live?() do
        try do
          assert_bodies_from_the_site(staged.dir, Agent.get(rest_statuses, & &1))
          []
        rescue
          e in ExUnit.AssertionError -> ["re-import REST bodies: #{e.message}"]
        end
      else
        []
      end

    [
      if(!offered?, do: "updating imported posts wasn't offered to the admin on re-import"),
      if(length(post_jobs) != expected.posts,
        do: "re-import queued #{length(post_jobs)} post jobs, not #{expected.posts}"
      ),
      if(failures != [], do: "#{length(failures)} re-import jobs failed"),
      if(map_size(posts_after) != map_size(posts_before),
        do: "#{map_size(posts_before)} posts before the re-import, #{map_size(posts_after)} after"
      ),
      if(Agent.get(media_requests, & &1) != [], do: "the re-import requested media files")
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(bodies_problems)
  end

  # The site's imported posts, by id, each with a hash of its title, summary and body
  defp site_posts(site) do
    pattern = "%//#{URI.parse(site).host}/%"

    from(pc in Bonfire.Data.Social.PostContent,
      join: p in Bonfire.Data.ActivityPub.Peered,
      on: p.id == pc.id,
      where: like(p.canonical_uri, ^pattern),
      select: {pc.id, pc.name, pc.summary, pc.html_body}
    )
    |> Bonfire.Common.Repo.all()
    |> Map.new(fn {id, name, summary, body} -> {id, :erlang.phash2({name, summary, body})} end)
  end

  # The site taken over: each of its imported `Media` gets its file from a copy of the site's uploads folder, then the bodies' markers are checked against what was stored
  defp takeover(site) do
    key = Bonfire.WordPress.Posts.redir_storage(site)
    Process.put([:bonfire_files, :storage], :local)

    site_media = fn ->
      Bonfire.Common.Repo.all(
        from(m in Bonfire.Files.Media, where: fragment("?->>'storage'", m.file) == ^key)
      )
    end

    media = site_media.()
    report("site media", %{count: length(media), redir_storage: key})

    # the stored files are removed afterwards, wherever they got to
    on_exit(fn ->
      for m <- media, id = locator_id(m), is_binary(id), do: File.rm(Entrepot.Storages.Disk.path(id))
    end)

    case uploads_folder(media) do
      nil ->
        report("takeover", %{skipped: "set WXR_FULL_UPLOADS, or WXR_FULL_LIVE to download"})
        []

      folder ->
        {us, result} = :timer.tc(fn -> Takeover.Media.run(site, folder) end)
        check_takeover(site, key, result, us, site_media.())
    end
  end

  defp check_takeover(site, key, {:ok, %{stored: stored, not_stored: not_stored}}, us, media) do
    aliased? = Bonfire.Files.redir_storages()[key] == {:alias, Bonfire.Files.default_storage_name()}

    reasons =
      not_stored |> Enum.frequencies_by(&describe(&1.reason)) |> Enum.sort_by(&(-elem(&1, 1)))

    report("takeover", %{
      seconds: seconds(us),
      stored: stored,
      not_stored: length(not_stored),
      not_stored_reasons: reasons,
      key_now_alias: aliased?
    })

    stored_ids = for m <- media, m.path == locator_id(m), into: MapSet.new(), do: locator_id(m)
    marker_problems = check_markers(site, key, stored_ids)

    [
      if(not_stored == [] and not aliased?,
        do: "every media stored, but the site's key isn't an alias"
      ),
      if(not_stored != [] and aliased?,
        do: "#{length(not_stored)} media not stored, but the site's key became an alias"
      ),
      if(MapSet.size(stored_ids) < stored,
        do: "#{stored} reported stored, but only #{MapSet.size(stored_ids)} have their path set"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(marker_problems)
  end

  defp check_takeover(_site, _key, other, _us, _media), do: ["takeover failed: #{describe(other)}"]

  # A sample of the markers in the site's bodies: one of a stored media leads to the file here, one of a media not stored still leads to the site
  defp check_markers(site, key, stored_ids) do
    host = URI.parse(site).host
    prefix = "/files/redir/#{key}/"
    pattern = "%//#{host}/%"

    markers =
      from(pc in Bonfire.Data.Social.PostContent,
        join: p in Bonfire.Data.ActivityPub.Peered,
        on: p.id == pc.id,
        where: like(p.canonical_uri, ^pattern),
        select: pc.html_body
      )
      |> Bonfire.Common.Repo.all()
      |> Enum.flat_map(&Regex.scan(~r{#{Regex.escape(prefix)}[^"'\s<>?#]+}, &1 || ""))
      |> List.flatten()
      |> Enum.uniq()

    {stored_markers, other_markers} =
      Enum.split_with(markers, &MapSet.member?(stored_ids, String.replace_prefix(&1, prefix, "")))

    sample = Enum.take_random(stored_markers, 50) ++ Enum.take_random(other_markers, 10)

    results =
      for marker <- sample do
        conn = get(build_conn(), marker)
        location = List.first(get_resp_header(conn, "location")) || ""
        stored? = MapSet.member?(stored_ids, String.replace_prefix(marker, prefix, ""))

        cond do
          conn.status != 302 -> {:bad, "a marker gave #{conn.status}"}
          stored? and location =~ host -> {:bad, "a stored media's marker still leads to the site"}
          stored? and not String.contains?(location, String.replace_prefix(marker, prefix, "")) -> {:bad, "a stored media's marker leads elsewhere than its file"}
          not stored? and not (location =~ host) -> {:bad, "a media not stored leads somewhere other than the site"}
          true -> :ok
        end
      end

    report("markers", %{
      in_bodies: length(markers),
      of_stored_media: length(stored_markers),
      checked: length(sample),
      ok: Enum.count(results, &(&1 == :ok))
    })

    results
    |> Enum.reject(&(&1 == :ok))
    |> Enum.frequencies_by(&elem(&1, 1))
    |> Enum.map(fn {problem, count} -> "#{count}x #{problem}" end)
  end

  defp locator_id(%{file: %{id: id}}), do: id
  defp locator_id(%{file: %{"id" => id}}), do: id
  defp locator_id(_), do: nil

  # the copy of the site's uploads folder: the one given, else (live) downloaded from the site into a temporary folder, one file per media, the original before a size as takeover prefers it
  defp uploads_folder(media) do
    cond do
      is_binary(uploads_copy()) and File.dir?(uploads_copy()) ->
        uploads_copy()

      live?() ->
        {:ok, _} = Application.ensure_all_started([:inets, :ssl])
        folder = Path.join(System.tmp_dir!(), "wxr-takeover-#{System.unique_integer([:positive])}")
        on_exit(fn -> File.rm_rf(folder) end)

        {us, outcomes} =
          :timer.tc(fn ->
            media
            |> Task.async_stream(&download_media(&1, folder),
              max_concurrency: 4,
              timeout: :infinity,
              ordered: false
            )
            |> Enum.map(fn {:ok, outcome} -> outcome end)
          end)

        report("downloading the site's uploads", %{
          seconds: seconds(us),
          outcomes: outcomes |> Enum.frequencies() |> Enum.sort_by(&(-elem(&1, 1)))
        })

        folder

      true ->
        nil
    end
  end

  defp download_media(media, folder) do
    {originals, sizes} =
      [media.path | List.wrap(get_in(media.metadata || %{}, ["urls"]))]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.split_with(&(not Regex.match?(~r/-\d+x\d+\.\w+$/, &1)))

    Enum.reduce_while(originals ++ sizes, :no_upload_url, fn url, last ->
      case download(url, folder) do
        :ok -> {:halt, :ok}
        :too_large -> {:halt, :too_large}
        :not_an_upload -> {:cont, if(last == :no_upload_url, do: :no_upload_url, else: last)}
        failed -> {:cont, failed}
      end
    end)
  end

  defp download(url, folder) do
    with %{path: "/" <> _ = path} <- URI.parse(url),
         [_, relative] <- String.split(path, "/wp-content/uploads/", parts: 2),
         relative = URI.decode(relative),
         false <- relative == "" or ".." in Path.split(relative) do
      destination = Path.join([folder, "wp-content", "uploads", relative])
      File.mkdir_p!(Path.dirname(destination))

      ssl = [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]

      request_url = url |> URI.encode() |> String.replace("%25", "%")

      case :httpc.request(:get, {String.to_charlist(request_url), []}, [ssl: ssl, timeout: 300_000],
             stream: String.to_charlist(destination)
           ) do
        {:ok, :saved_to_file} ->
          if File.stat!(destination).size > @max_download do
            File.rm(destination)
            :too_large
          else
            :ok
          end

        {:ok, {{_, status, _}, _, _}} ->
          File.rm(destination)
          {:http, status}

        {:error, reason} ->
          File.rm(destination)
          {:error, reason |> inspect(limit: 3) |> String.slice(0, 80)}
      end
    else
      _ -> :not_an_upload
    end
  end

  # live, every body came from the site's REST API, none from the export: one successful request per chunk of the staged posts (each chunk's first job fetches it and caches its bodies), no chunk marked failed, and a cached body for every post
  defp assert_bodies_from_the_site(dir, rest_statuses) do
    chunks = dir |> Path.join("chunks.json") |> File.read!() |> Jason.decode!()
    chunk_count = chunks |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    ids = chunks |> Map.values() |> List.flatten() |> List.flatten()

    ok = Enum.count(rest_statuses, &(&1 == 200))

    report("REST bodies", %{chunks: chunk_count, ok_requests: ok, requests: length(rest_statuses)})

    assert ok == chunk_count
    assert length(rest_statuses) == chunk_count
    assert File.ls(Path.join(dir, "failed")) in [{:error, :enoent}, {:ok, []}]

    missing = Enum.reject(ids, &File.exists?(Path.join([dir, "bodies", "#{&1}.html"])))

    assert missing == [],
           "#{length(missing)} posts fell back to the export's body, eg. #{inspect(Enum.take(missing, 5))}"
  end

  # The file's own counts, by an independent pass over its lines (an export puts each of these elements on a line of its own): published posts and podcast episodes without a password are imported, published pages listed apart, and the rest left out by status (for a post, page or podcast) or by type.
  defp scan(path) do
    path
    |> File.stream!()
    |> Enum.reduce({%{posts: 0, pages: 0, skipped: %{}}, nil}, fn line, {acc, item} ->
      cond do
        String.contains?(line, "<item>") ->
          {acc, %{}}

        is_nil(item) ->
          {acc, item}

        String.contains?(line, "</item>") ->
          {classify(item, acc), nil}

        true ->
          {acc, Map.merge(item, fields(line))}
      end
    end)
    |> elem(0)
  end

  defp fields(line) do
    for {key, element} <- [
          type: "wp:post_type",
          status: "wp:status",
          password: "wp:post_password"
        ],
        [_, value] <- [Regex.run(~r{<#{element}><!\[CDATA\[([^\]]*)\]\]>}, line)],
        into: %{},
        do: {key, value}
  end

  defp classify(%{type: "attachment"}, acc), do: acc

  defp classify(%{type: type, status: "publish"} = item, acc) when type in ["post", "podcast"] do
    if (item[:password] || "") != "",
      do: skip(acc, "password-protected"),
      else: %{acc | posts: acc.posts + 1}
  end

  defp classify(%{type: "page", status: "publish"}, acc), do: %{acc | pages: acc.pages + 1}

  defp classify(%{type: type, status: status}, acc) when type in ["post", "page", "podcast"],
    do: skip(acc, status)

  defp classify(item, acc), do: skip(acc, item[:type] || "unknown")

  defp skip(acc, key), do: update_in(acc.skipped, &Map.update(&1, key, 1, fn n -> n + 1 end))

  # a failure's kind, without anything personal it may carry (an email in an error message)
  defp describe({:error, %Ecto.Changeset{errors: errors}}),
    do: "a changeset error on #{errors |> Keyword.keys() |> Enum.uniq() |> Enum.join(", ")}"

  defp describe(other),
    do:
      other
      |> inspect(limit: 5, printable_limit: 120)
      |> String.replace(~r/[\w.+-]+@[\w-]+(\.[\w-]+)+/, "<email>")
      |> String.slice(0, 200)

  defp report(label, values), do: IO.puts("\n[full export] #{label}: #{inspect(values)}")

  defp seconds(us), do: Float.round(us / 1_000_000, 1)
  defp mb(bytes), do: Float.round(bytes / 1_048_576, 1)
end
