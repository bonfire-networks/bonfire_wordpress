defmodule Bonfire.WordPress.Import.WXRImportIntegrationTest do
  @moduledoc """
  Imports a whole WordPress export, to try the import on a real site before running it for real: opt-in, since it needs a real export file, which never goes in the repo (it holds people's emails).

  Run with `WXR_FULL_EXPORT=/path/to/export.xml just test extensions/bonfire_wordpress/test/import/wxr_import_integration_test.exs --include integration`. Bodies come from each post's own export text, as when the site's REST API is unavailable, unless `WXR_FULL_LIVE=1` lets the import ask the live site. Media files are never fetched.

  It checks that staging keeps memory in check, that the checklist's counts match the file's, and that every post's job succeeds, and prints the timings. It prints only ids, counts and timings, never post content or emails.
  """
  use Bonfire.WordPress.DataCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo

  alias Bonfire.Common.Import
  alias Bonfire.WordPress.Import.WXR

  @moduletag :integration
  @moduletag timeout: :infinity

  if not File.regular?(System.get_env("WXR_FULL_EXPORT") || "") do
    @moduletag skip: "set WXR_FULL_EXPORT to a WordPress export file to run this"
  end

  # a generous bound for staging a big export, which streams it one item at a time
  @max_staging_growth 300 * 1024 * 1024

  defp export_path, do: System.get_env("WXR_FULL_EXPORT")
  defp live?, do: System.get_env("WXR_FULL_LIVE") in ["1", "true", "yes"]

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
            if live?(), do: live_get(env), else: %Tesla.Env{status: 500, body: ""}

          # anything else, eg. unfurling an embedded player: no network, so it falls back to a bare link
          true ->
            %Tesla.Env{status: 404, body: ""}
        end
    end)

    {:ok, media_requests: media_requests}
  end

  test "a whole export imports every published post, with memory in check", %{
    media_requests: media_requests
  } do
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

    {prepare_us, _} =
      :timer.tc(fn ->
        for job <- all_enqueued(worker: Import), job.args["op"] == "import_materialize" do
          result = Import.perform(job)
          assert result == :ok or match?({:ok, _}, result)
        end
      end)

    post_jobs =
      for job <- all_enqueued(worker: Import), job.args["op"] == "wordpress_import", do: job

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

    report("importing", %{
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

    assert length(post_jobs) == expected.posts
    assert failures == []

    assert Agent.get(media_requests, & &1) == []
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
