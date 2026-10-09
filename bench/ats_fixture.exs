# Transform a DISPOSABLE canonical fixture copy into a known-ATS workload.
# BENCH_DIR must begin /tmp/hireme-perf-ats-; BENCH_HOT_JOBS defaults to 100.
# Existing company/profile/lineage ownership and stage dates remain unchanged.
import Ecto.Query
alias Hireme.{Desk, Pipeline, Repo}

dir = Path.expand(System.fetch_env!("BENCH_DIR"))
database = Application.fetch_env!(:hireme, Repo) |> Keyword.fetch!(:database) |> Path.expand()

unless String.starts_with?(dir, "/tmp/hireme-perf-ats-") and
         String.starts_with?(database, dir <> "/") and
         File.lstat!(database).type == :regular and File.lstat!(dir).type == :directory,
       do: raise("use a disposable copied ATS fixture")

metadata_path = Path.join(dir, "testbed.json")
metadata = metadata_path |> File.read!() |> Jason.decode!()
Logger.configure(level: :warning)
endpoint = Application.fetch_env!(:hireme, HiremeWeb.Endpoint)
Application.put_env(:hireme, HiremeWeb.Endpoint, Keyword.put(endpoint, :server, false))
Application.put_env(:hireme, Hireme.Mailer, adapter: Swoosh.Adapters.Test)
{:ok, _} = Application.ensure_all_started(:hireme)
Repo.put_account(metadata["account_id"])
hot = System.get_env("BENCH_HOT_JOBS", "100") |> String.to_integer()
count = Repo.aggregate(Desk.Job, :count)
true = hot in 0..count

# Synthetic URLs exercise the real Greenhouse parser; nothing fetches these URLs.
Ecto.Adapters.SQL.query!(
  Repo,
  """
  UPDATE job_apps
  SET listing_url = 'https://boards.greenhouse.io/bench-' || (id % 100) || '/jobs/' || id,
      canonical_url = 'https://boards.greenhouse.io/bench-' || (id % 100) || '/jobs/' || id
  WHERE account_id = ?
  """,
  [metadata["account_id"]]
)

Repo.update_all(Desk.Job,
  set: [current_stage: :discovered, pips: Pipeline.encode(Pipeline.initial(:discovered))]
)

ids = Repo.all(from j in Desk.Job, order_by: j.id, limit: ^hot, select: j.id)

{^hot, _} =
  Repo.update_all(from(j in Desk.Job, where: j.id in ^ids),
    set: [current_stage: :submitted, pips: Pipeline.encode(Pipeline.initial(:submitted))]
  )

scenario = "greenhouse_#{count}_jobs_#{hot}_hot"
metadata = Map.merge(metadata, %{"scenario" => scenario, "job_count" => count, "hot_jobs" => hot})
File.write!(metadata_path, Jason.encode!(metadata))
File.chmod!(metadata_path, 0o600)
IO.puts(Jason.encode!(%{scenario: scenario, jobs: count, hot_jobs: hot, ats: "greenhouse"}))
