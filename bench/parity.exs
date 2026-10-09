# Fingerprint public payloads from baseline/final releases on identical fixture copies.
# Compare digests, not private Ecto preload/query representation.
alias Hireme.{Campaign, Corpus, Desk, Heat, Repo}
alias HiremeWeb.{JSON, Packet}

dir = Path.expand(System.fetch_env!("BENCH_DIR"))
database = Application.fetch_env!(:hireme, Repo) |> Keyword.fetch!(:database) |> Path.expand()

unless String.starts_with?(dir, "/tmp/hireme-perf-") and
         dir != "/tmp/hireme-perf-canonical" and String.starts_with?(database, dir <> "/"),
       do: raise("use a disposable performance fixture copy")

Logger.configure(level: :warning)
endpoint = Application.fetch_env!(:hireme, HiremeWeb.Endpoint)
Application.put_env(:hireme, HiremeWeb.Endpoint, Keyword.put(endpoint, :server, false))
Application.put_env(:hireme, Hireme.Mailer, adapter: Swoosh.Adapters.Test)
{:ok, _} = Application.ensure_all_started(:hireme)
metadata = dir |> Path.join("testbed.json") |> File.read!() |> Jason.decode!()
Repo.put_account(metadata["account_id"])
ids = metadata["job_ids"]
focus_ids = Enum.uniq(Enum.take(ids, 10) ++ Enum.take(ids, -10))
batch = hd(Desk.list_batches())
mix = Heat.mix_batch(batch)

payloads = %{
  packet_bytes: Packet.build() |> IO.iodata_to_binary(),
  focuses: Enum.map(focus_ids, &(&1 |> Desk.focus() |> JSON.focus())),
  roots: Enum.map(Corpus.list_profiles(), &(&1.id |> Desk.root() |> JSON.root())),
  scoreboard: Campaign.scoreboard() |> JSON.scoreboard(),
  lanes: JSON.lanes(),
  score_chart: Desk.score_chart(),
  batch_mix: %{
    kept: Enum.map(mix.kept, & &1.id),
    deferred: Enum.map(mix.deferred, fn {job, verdict} -> {job.id, verdict} end)
  }
}

digests =
  Map.new(payloads, fn {key, value} ->
    binary = :erlang.term_to_binary(value, [:deterministic])
    {key, :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)}
  end)

row = %{
  rev: System.fetch_env!("BENCH_REV"),
  scenario: metadata["scenario"] || "canonical_unknown_ats",
  job_count: Repo.aggregate(Desk.Job, :count),
  focus_ids: focus_ids,
  digests: digests
}

File.write!(System.fetch_env!("BENCH_OUTPUT"), Jason.encode!(row) <> "\n", [:append])
IO.puts(Jason.encode!(row))
