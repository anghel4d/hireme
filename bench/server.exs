# Production-release benchmark. State must be a synthetic testbed under BENCH_DIR.
defmodule HiremeBench.Server do
  import Ecto.Query
  alias Hireme.{Accounts, ApiKeys, Corpus, Desk, Heat, Import, Kv, Mfa, Repo}

  def run do
    dir = Path.expand(System.fetch_env!("BENCH_DIR"))
    database = Application.fetch_env!(:hireme, Repo) |> Keyword.fetch!(:database) |> Path.expand()

    unless String.starts_with?(database, dir <> "/"),
      do: raise("database must be inside BENCH_DIR")

    Logger.configure(level: :warning)

    for path <- String.split(System.get_env("BENCH_PATCHES", ""), ":", trim: true) do
      Code.compile_file(path)
    end

    endpoint = Application.fetch_env!(:hireme, HiremeWeb.Endpoint)
    Application.put_env(:hireme, HiremeWeb.Endpoint, Keyword.put(endpoint, :server, false))
    Application.put_env(:hireme, Hireme.Mailer, adapter: Swoosh.Adapters.Test)
    {:ok, _} = Application.ensure_all_started(:hireme)
    metadata = dir |> Path.join("testbed.json") |> File.read!() |> Jason.decode!()
    Repo.put_account(metadata["account_id"])
    account = Accounts.get(metadata["account_id"])
    {token, session} = Accounts.start_session(account)
    job_id = hd(metadata["job_ids"])
    profile_id = hd(metadata["profile_ids"])
    batch = hd(Desk.list_batches())
    count = System.get_env("BENCH_N", "1000") |> String.to_integer()
    revision = System.fetch_env!("BENCH_REV")
    only = System.get_env("BENCH_ONLY", "")
    output = System.fetch_env!("BENCH_OUTPUT")
    profile = Corpus.get_profile!(profile_id)

    pack =
      Jason.encode!(%{
        batch: "Server-Import",
        fire: "hold",
        status: "draft_prep",
        queued_on: "2026-10-09",
        target_size: 55,
        apps:
          for i <- 1..55 do
            %{
              company: "Pack employer #{i}",
              role: "Systems engineer",
              location: "Remote",
              url: "https://pack.example.test/#{i}",
              stage: "gated",
              gate: "pursue",
              freshness: "open"
            }
          end
      })

    import_pack = fn ->
      {:ok, %{kind: :apps, count: 55}} = Import.import_body(pack, "pack.json", profile)
    end

    clear_pack = fn ->
      Repo.delete_all(from j in Desk.Job, where: like(j.company, "Pack employer %"))
      Repo.delete_all(from e in Desk.Employer, where: like(e.name, "Pack employer %"))
      Repo.delete_all(from b in Desk.Batch, where: b.code == "Server-Import")
    end

    operations = [
      {"Domain/Heat", "snapshot", fn -> Heat.snapshot() end},
      {"Domain/Heat", "can_apply", fn -> Heat.can_apply(job_id) end},
      {"Domain/Heat", "mix_batch_100", fn -> Heat.mix_batch(batch) end},
      {"Domain/Org", "size", fn -> Heat.Org.size("Company 42") end},
      {"Domain/Org", "department", fn -> Heat.Org.department(%{department: "Engineering 2"}) end},
      {"Domain/Org", "family", fn -> Heat.Org.family(%{role: "Senior Systems Engineer"}) end},
      {"Domain/ATS", "parse",
       fn -> Heat.Ats.parse("https://boards.greenhouse.io/acme/jobs/42") end},
      {"Domain/Corpus", "list_items", fn -> Corpus.list_items(profile_id) end},
      {"Domain/Accounts", "session_authenticate", fn -> Accounts.session(token) end},
      {"Domain/Accounts", "list_sessions", fn -> Accounts.list_sessions(account.id) end},
      {"Domain/ApiKeys", "list", fn -> ApiKeys.list() end},
      {"Domain/Mfa", "enrolled", fn -> Mfa.enrolled?() end},
      {"Domain/Mfa", "methods", fn -> Mfa.methods() end},
      {"Domain/Mfa", "fresh", fn -> Mfa.fresh?(session) end},
      {"Domain/Kv", "list", fn -> Kv.list("global") end},
      # What a boot costs the attaching process: every raw table read in
      # one transaction, encoded as the deflated BOOT frame.
      {"Transport/Packet", "boot",
       fn ->
         {:ok, tables} = Repo.transaction(fn -> Hireme.Ops.read_tables() end)
         body = for {table, rows} <- tables, do: HiremeWeb.Packet.raw(table, rows)

         HiremeWeb.Packet.frame(:boot, 0, body, deflate: true)
         |> IO.iodata_to_binary()
       end},
      # A pack of 55 applications as an agent imports it: onto a desk without
      # them (the reset runs before every call, outside the timer), then the
      # same pack again, which only updates the cards it matches.
      {"Domain/Import", "pack_55_new", {clear_pack, import_pack}},
      {"Domain/Import", "pack_55_again", {fn -> :ok end, import_pack}}
    ]

    for {page, interaction, operation} <- operations,
        only == "" or String.contains?(page <> "/" <> interaction, only) do
      # A write row is {reset, operation}: the reset runs before every call,
      # outside the timer, and the row takes a tenth of the samples.
      {reset, operation, n} =
        case operation do
          {reset, operation} -> {reset, operation, max(div(count, 10), 1)}
          operation -> {fn -> :ok end, operation, count}
        end

      for _ <- 1..20 do
        reset.()
        operation.()
      end

      :erlang.garbage_collect()

      samples =
        for _ <- 1..n do
          reset.()
          started = System.monotonic_time()
          operation.()

          System.convert_time_unit(System.monotonic_time() - started, :native, :nanosecond) /
            1_000_000
        end

      reset.()
      query_count = count_queries(operation)

      row =
        summarize(samples)
        |> Map.merge(%{
          page: page,
          interaction: interaction,
          rev: revision,
          queries: query_count,
          query_scope: "all_repo_processes",
          job_count: metadata["job_count"],
          scenario: metadata["scenario"] || "canonical_unknown_ats",
          samples: samples,
          layer: "domain",
          schedulers: :erlang.system_info(:schedulers_online)
        })

      File.write!(output, Jason.encode!(row) <> "\n", [:append])
      IO.puts(Jason.encode!(Map.delete(row, :samples)))
    end
  end

  def summarize(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    percentile = fn p -> Enum.at(sorted, max(0, ceil(n * p) - 1)) end
    mean = Enum.sum(samples) / n

    %{
      n: n,
      mean: mean,
      p0_1: percentile.(0.001),
      p1: percentile.(0.01),
      p50: percentile.(0.5),
      p99: percentile.(0.99),
      p99_9: percentile.(0.999),
      ops_per_second: 1000 / mean
    }
  end

  def handle_query(_event, _measurements, _metadata, counter) do
    :ets.update_counter(counter, :queries, 1)
  end

  defp count_queries(operation) do
    handler = {__MODULE__, make_ref()}
    # Ecto can preload associations in other processes. The isolated benchmark
    # has no concurrent requests; count those queries as part of the operation.
    counter = :ets.new(:bench_queries, [:public])
    :ets.insert(counter, {:queries, 0})

    :ok =
      :telemetry.attach(handler, [:hireme, :repo, :query], &__MODULE__.handle_query/4, counter)

    try do
      operation.()
      :ets.lookup_element(counter, :queries, 2)
    after
      :telemetry.detach(handler)
      :ets.delete(counter)
    end
  end
end

HiremeBench.Server.run()
