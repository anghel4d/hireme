# Production-release benchmark. State must be a synthetic testbed under BENCH_DIR.
defmodule HiremeBench.Server do
  alias Hireme.{Accounts, ApiKeys, Campaign, Corpus, Desk, Gym, Heat, Kv, Mfa, Net, Repo}

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
    items = Corpus.list_items(profile_id)
    resolved = Hireme.Mask.apply(items, [])
    profile = Corpus.get_profile!(profile_id)
    count = System.get_env("BENCH_N", "1000") |> String.to_integer()
    revision = System.fetch_env!("BENCH_REV")
    only = System.get_env("BENCH_ONLY", "")
    output = System.fetch_env!("BENCH_OUTPUT")

    operations = [
      {"Domain/Desk", "list_cards", fn -> Desk.list_cards(%Desk.Filters{status: :all}) end},
      {"Domain/Desk", "focus", fn -> Desk.focus(job_id) end},
      {"Domain/Desk", "root", fn -> Desk.root(profile_id) end},
      {"Domain/Heat", "snapshot", fn -> Heat.snapshot() end},
      {"Domain/Heat", "chart", fn -> Heat.chart() end},
      {"Domain/Heat", "can_apply", fn -> Heat.can_apply(job_id) end},
      {"Domain/Campaign", "scoreboard", fn -> Campaign.scoreboard() end},
      {"Domain/Gym", "progress", fn -> Gym.progress() end},
      {"Domain/Gym", "recent", fn -> Gym.recent() end},
      {"Domain/Net", "progress", fn -> Net.progress() end},
      {"Domain/Net", "recent", fn -> Net.recent() end},
      {"Domain/Corpus", "list_items", fn -> Corpus.list_items(profile_id) end},
      {"Domain/CV", "compose",
       fn -> Hireme.Cv.compose(profile, resolved, Hireme.Theme.parse(nil)) end},
      {"Domain/Keywords", "coverage",
       fn -> Hireme.Keywords.coverage(["elixir", "rust", "typescript", "sqlite"], resolved) end},
      {"Domain/Accounts", "session_authenticate", fn -> Accounts.session(token) end},
      {"Domain/Accounts", "list_sessions", fn -> Accounts.list_sessions(account.id) end},
      {"Domain/ApiKeys", "list", fn -> ApiKeys.list() end},
      {"Domain/Mfa", "enrolled", fn -> Mfa.enrolled?() end},
      {"Domain/Mfa", "methods", fn -> Mfa.methods() end},
      {"Domain/Mfa", "fresh", fn -> Mfa.fresh?(session) end},
      {"Domain/Kv", "list", fn -> Kv.list("global") end},
      {"Transport/Packet", "build", fn -> HiremeWeb.Packet.build() |> IO.iodata_to_binary() end},
      {"Transport/JSON", "focus",
       fn -> Desk.focus(job_id) |> HiremeWeb.JSON.focus() |> Jason.encode!() end},
      {"Transport/JSON", "lanes", fn -> HiremeWeb.JSON.lanes() |> Jason.encode!() end}
    ]

    for {page, interaction, operation} <- operations,
        only == "" or String.contains?(page <> "/" <> interaction, only) do
      for _ <- 1..20, do: operation.()
      :erlang.garbage_collect()

      samples =
        for _ <- 1..count do
          started = System.monotonic_time()
          operation.()

          System.convert_time_unit(System.monotonic_time() - started, :native, :nanosecond) /
            1_000_000
        end

      query_count = count_queries(operation)

      row =
        summarize(samples)
        |> Map.merge(%{
          page: page,
          interaction: interaction,
          rev: revision,
          queries: query_count,
          job_count: metadata["job_count"],
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

  def handle_query(_event, _measurements, _metadata, owner) do
    if self() == owner, do: Process.put(:bench_queries, Process.get(:bench_queries, 0) + 1)
  end

  defp count_queries(operation) do
    handler = {__MODULE__, make_ref()}
    Process.put(:bench_queries, 0)
    :ok = :telemetry.attach(handler, [:hireme, :repo, :query], &__MODULE__.handle_query/4, self())

    try do
      operation.()
      Process.get(:bench_queries)
    after
      :telemetry.detach(handler)
      Process.delete(:bench_queries)
    end
  end
end

HiremeBench.Server.run()
