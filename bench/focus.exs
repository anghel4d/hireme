# Run the immutable release with a copied synthetic BENCH_DIR and +S 2:2.
# BENCH_BASELINE_DESK and BENCH_CANDIDATE_DESK select the two source snapshots.
# Each phase recompiles only Desk; validations happen outside timed intervals.
defmodule HiremeBench.Focus do
  alias Hireme.{Desk, Repo}

  def run do
    dir = Path.expand(System.fetch_env!("BENCH_DIR"))
    database = Application.fetch_env!(:hireme, Repo) |> Keyword.fetch!(:database) |> Path.expand()

    unless String.starts_with?(database, dir <> "/"),
      do: raise("database must be inside BENCH_DIR")

    Logger.configure(level: :warning)
    endpoint = Application.fetch_env!(:hireme, HiremeWeb.Endpoint)
    Application.put_env(:hireme, HiremeWeb.Endpoint, Keyword.put(endpoint, :server, false))
    Application.put_env(:hireme, Hireme.Mailer, adapter: Swoosh.Adapters.Test)
    {:ok, _} = Application.ensure_all_started(:hireme)
    metadata = dir |> Path.join("testbed.json") |> File.read!() |> Jason.decode!()
    Repo.put_account(metadata["account_id"])
    baseline = System.fetch_env!("BENCH_BASELINE_DESK")
    candidate = System.fetch_env!("BENCH_CANDIDATE_DESK")
    n = System.get_env("BENCH_N", "1000") |> String.to_integer()
    true = n > 0
    ids = metadata["job_ids"] |> Enum.take(12) |> List.to_tuple()
    Code.compile_file(baseline)

    expected =
      Map.new(Tuple.to_list(ids), fn id ->
        focus = Desk.focus(id)
        true = focus.job.id == id
        true = focus.job.account_id == metadata["account_id"]
        true = focus.profile.id == focus.job.profile_id
        true = focus.variant.job_app.id == id
        true = Ecto.assoc_loaded?(focus.job.batch)
        true = Ecto.assoc_loaded?(focus.variant.lineage)
        {id, focus}
      end)

    expected_json = Map.new(expected, fn {id, focus} -> {id, json(focus)} end)
    :ets.new(:focus_bench_queries, [:named_table, :public, :set])

    for {revision, path, phase} <- [
          {"baseline", baseline, 1},
          {"joined", candidate, 2},
          {"joined", candidate, 3},
          {"baseline", baseline, 4}
        ] do
      Code.compile_file(path)
      nil = Desk.focus(nil)
      nil = Desk.focus(-1)
      nil = Repo.with_account(-1, fn -> Desk.focus(elem(ids, 0)) end)

      for {page, operation, expected_results} <- [
            {"Domain/Desk", &Desk.focus/1, expected},
            {"Transport/JSON", fn id -> id |> Desk.focus() |> json() end, expected_json}
          ] do
        for i <- 1..40 do
          id = elem(ids, rem(i - 1, tuple_size(ids)))
          result = operation.(id)
          true = result === Map.fetch!(expected_results, id)
        end

        :erlang.garbage_collect()

        samples =
          for i <- 1..n do
            id = elem(ids, rem(i - 1, tuple_size(ids)))
            started = System.monotonic_time()
            result = operation.(id)
            elapsed = System.monotonic_time() - started
            true = result === Map.fetch!(expected_results, id)
            System.convert_time_unit(elapsed, :native, :nanosecond) / 1_000_000
          end

        row =
          summarize(samples)
          |> Map.merge(%{
            page: page,
            interaction: "focus",
            rev: revision,
            phase: phase,
            queries: count_queries(fn -> operation.(elem(ids, 0)) end),
            samples: samples,
            job_count: metadata["job_count"],
            compared_jobs: tuple_size(ids),
            exact_equality: true,
            missing_and_foreign_account_nil: true,
            schedulers: :erlang.system_info(:schedulers_online)
          })

        File.write!(System.fetch_env!("BENCH_OUTPUT"), Jason.encode!(row) <> "\n", [:append])
        IO.puts(Jason.encode!(Map.delete(row, :samples)))
      end
    end
  end

  def handle_query(_event, _measurements, _metadata, _config) do
    :ets.update_counter(:focus_bench_queries, :queries, 1)
  end

  defp count_queries(operation) do
    :ets.insert(:focus_bench_queries, {:queries, 0})
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, [:hireme, :repo, :query], &__MODULE__.handle_query/4, nil)

    try do
      operation.()
      :ets.lookup_element(:focus_bench_queries, :queries, 2)
    after
      :telemetry.detach(handler)
    end
  end

  defp json(focus), do: focus |> HiremeWeb.JSON.focus() |> Jason.encode!()

  defp summarize(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    percentile = fn p -> Enum.at(sorted, max(0, ceil(n * p) - 1)) end

    %{
      n: n,
      mean: Enum.sum(samples) / n,
      p0_1: percentile.(0.001),
      p1: percentile.(0.01),
      p50: percentile.(0.5),
      p99: percentile.(0.99),
      p99_9: percentile.(0.999)
    }
  end
end

HiremeBench.Focus.run()
