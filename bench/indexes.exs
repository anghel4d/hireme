# Run from an immutable release against a disposable copy of the canonical fixture.
# CPU pinning and +S2:2 are supplied by the caller. No application source is changed.
defmodule HiremeBench.Indexes do
  import Ecto.Query
  alias Hireme.{Repo, Desk, Gym, Net, Heat, Campaign}

  def run do
    dir = Path.expand(System.fetch_env!("BENCH_DIR"))
    database = Application.fetch_env!(:hireme, Repo) |> Keyword.fetch!(:database) |> Path.expand()
    unless String.starts_with?(database, dir <> "/"), do: raise("database outside BENCH_DIR")
    Logger.configure(level: :warning)

    for path <- String.split(System.get_env("BENCH_PATCHES", ""), ":", trim: true),
        do: Code.compile_file(path)

    endpoint = Application.fetch_env!(:hireme, HiremeWeb.Endpoint)
    Application.put_env(:hireme, HiremeWeb.Endpoint, Keyword.put(endpoint, :server, false))
    Application.put_env(:hireme, Hireme.Mailer, adapter: Swoosh.Adapters.Test)
    {:ok, _} = Application.ensure_all_started(:hireme)
    metadata = dir |> Path.join("testbed.json") |> File.read!() |> Jason.decode!()
    Repo.put_account(metadata["account_id"])
    output = System.fetch_env!("BENCH_OUTPUT")
    n = System.get_env("BENCH_N", "300") |> String.to_integer()
    job_id = hd(metadata["job_ids"])
    variant = Repo.one!(from v in Hireme.Desk.Variant, where: v.job_app_id == ^job_id)

    item =
      Repo.one!(
        from i in Hireme.Corpus.Item, where: i.profile_id == ^variant.profile_id, limit: 1
      )

    lineage = fn ->
      {:error, :index_bench} =
        Repo.transaction(fn ->
          {:ok, _} = Desk.put_overlay(job_id, item.id, :inherit)
          Repo.rollback(:index_bench)
        end)
    end

    candidates = [
      {"gym_solved", "gym_reps", "account_id, outcome, done_on",
       [{"Gym/progress", &Gym.progress/0}], Hireme.Gym.Rep, :outcome},
      {"gym_solved_cover", "gym_reps", "account_id, outcome, done_on, problem_id",
       [{"Gym/progress", &Gym.progress/0}], Hireme.Gym.Rep, :outcome},
      {"gym_recent", "gym_reps", "account_id, done_on, id",
       [{"Gym/recent", &Gym.recent/0}, {"Gym/progress", &Gym.progress/0}], Hireme.Gym.Rep,
       :done_on},
      {"gym_recent_rowid", "gym_reps", "account_id, done_on",
       [{"Gym/recent", &Gym.recent/0}, {"Gym/progress", &Gym.progress/0}], Hireme.Gym.Rep,
       :done_on},
      {"net_recent", "net_entries", "account_id, id", [{"Net/recent", &Net.recent/0}],
       Hireme.Net.Entry, :kind},
      {"net_counts", "net_entries", "account_id, kind, shipped_on",
       [{"Net/progress", &Net.progress/0}], Hireme.Net.Entry, :kind},
      {"events_focus", "events", "account_id, job_app_id, id",
       [{"Desk/focus", fn -> Desk.focus(job_id) end}], Hireme.Desk.Event, :job_app_id},
      {"variant_lineage", "cv_variants", "account_id, lineage_id",
       [{"Desk/lineage_refresh", lineage}], Hireme.Desk.Variant, :lineage_id},
      {"job_stage", "job_apps", "account_id, current_stage, stage_on",
       [{"Heat/snapshot", &Heat.snapshot/0}, {"Campaign/scoreboard", &Campaign.scoreboard/0}],
       Hireme.Desk.Job, :current_stage},
      {"batch_order", "batches", "account_id, ordinal",
       [{"Campaign/scoreboard", &Campaign.scoreboard/0}], Hireme.Desk.Batch, :ordinal}
    ]

    only = String.split(System.get_env("BENCH_ONLY", ""), ",", trim: true)

    catalog =
      sql(
        "SELECT type, name, sql FROM sqlite_master WHERE type IN ('index','trigger') ORDER BY type,name"
      ).rows

    cardinalities =
      for table <- ~w(accounts job_apps gym_reps net_entries events cv_variants batches),
          into: %{},
          do: {table, sql("SELECT COUNT(*) FROM #{table}").rows}

    File.write!(
      output <> ".catalog.json",
      Jason.encode!(%{catalog: catalog, cardinalities: cardinalities})
    )

    for {name, table, columns, operations, schema, field} <- candidates,
        only == [] or name in only do
      row = Repo.one!(from r in schema, limit: 1)

      write = fn ->
        {:error, :index_bench} =
          Repo.transaction(fn ->
            for _ <- 1..20 do
              row
              |> Ecto.Changeset.change()
              |> Ecto.Changeset.force_change(field, Map.fetch!(row, field))
              |> Repo.update!()
            end

            Repo.rollback(:index_bench)
          end)
      end

      insert =
        if schema in [Hireme.Gym.Rep, Hireme.Net.Entry, Hireme.Desk.Event] do
          attrs =
            row |> Map.from_struct() |> Map.take(schema.__schema__(:fields)) |> Map.delete(:id)

          fn ->
            {:error, :index_bench} =
              Repo.transaction(fn ->
                for _ <- 1..20, do: Repo.insert!(struct(schema, attrs))
                Repo.rollback(:index_bench)
              end)
          end
        end

      operations =
        operations ++
          [{"Write/update20", write}] ++ if(insert, do: [{"Write/insert20", insert}], else: [])

      expected = Map.new(operations, fn {label, operation} -> {label, operation.()} end)
      index = "bench_" <> name

      try do
        for {state, round} <- Enum.with_index([:before, :after, :after, :before], 1) do
          Repo.checkout(fn ->
            sql("SELECT name FROM sqlite_master")
            sql("DROP INDEX IF EXISTS #{index}")
            if state == :after, do: sql("CREATE INDEX #{index} ON #{table} (#{columns})")
          end)

          for {label, operation} <- operations do
            # Validate outside timing; rolled-back writes leave the fixture unchanged.
            plans = capture(operation)

            unless operation.() == expected[label] do
              rejection = %{
                candidate: name,
                operation: label,
                reason: "result changed",
                plans: plans
              }

              File.write!(output <> ".rejections.jsonl", Jason.encode!(rejection) <> "\n", [
                :append
              ])

              throw(:reject_candidate)
            end

            for _ <- 1..20, do: operation.()
            :erlang.garbage_collect()

            samples =
              for _ <- 1..n do
                start = System.monotonic_time()
                operation.()

                System.convert_time_unit(System.monotonic_time() - start, :native, :nanosecond) /
                  1_000_000
              end

            data =
              summarize(samples)
              |> Map.merge(%{
                page: "Indexes/" <> name,
                interaction: label,
                rev: Atom.to_string(state),
                round: round,
                samples: samples,
                table: table,
                columns: columns,
                plans: plans,
                cardinalities: cardinalities
              })

            File.write!(output, Jason.encode!(data) <> "\n", [:append])
            IO.puts(Jason.encode!(Map.drop(data, [:samples, :plans, :cardinalities])))
          end
        end
      catch
        :reject_candidate -> :ok
      after
        sql("DROP INDEX IF EXISTS #{index}")
      end
    end
  end

  def handle_query(_event, _measurements, metadata, owner) do
    if self() == owner and Process.get(:index_capture),
      do:
        Process.put(:index_queries, [
          {metadata.query, metadata.params} | Process.get(:index_queries, [])
        ])
  end

  defp capture(operation) do
    handler = {__MODULE__, make_ref()}
    Process.put(:index_queries, [])
    Process.put(:index_capture, true)
    :ok = :telemetry.attach(handler, [:hireme, :repo, :query], &__MODULE__.handle_query/4, self())

    try do
      operation.()
      Process.put(:index_capture, false)

      Process.get(:index_queries)
      |> Enum.reverse()
      |> Enum.uniq()
      |> Enum.filter(fn {query, _} -> String.starts_with?(query, "SELECT") end)
      |> Enum.map(fn {query, params} ->
        Repo.checkout(fn ->
          # EXPLAIN alone can observe a pooled connection's pre-DDL schema cache.
          sql("SELECT name FROM sqlite_master")

          %{
            sql: query,
            params: Enum.map(params, &inspect/1),
            plan: sql("EXPLAIN QUERY PLAN " <> query, params).rows
          }
        end)
      end)
    after
      :telemetry.detach(handler)
      Process.delete(:index_capture)
      Process.delete(:index_queries)
    end
  end

  defp sql(query, params \\ []), do: Ecto.Adapters.SQL.query!(Repo, query, params)

  defp summarize(samples) do
    sorted = Enum.sort(samples)
    n = length(samples)
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

HiremeBench.Indexes.run()
