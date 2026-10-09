# Write the derivation oracle (Hireme.Oracle) for one account as JSON lines.
#
#   MIX_ENV=test mix run --no-start test/oracle/run.exs --out DIR --today 2026-10-09 \
#     [--db PATH --account ID] [--seed N] [--ops K] [--name NAME]
#
# --db dumps an existing database, migrated first (use a copy: this writes to it).
# --seed builds DIR/<name>.db from scratch: migrated, one account, a
# seeded random desk around --today. --ops then runs K seeded random
# client ops through Hireme.Ops and records each one's raw delta.
# The output is DIR/<name>.jsonl; never point this at production.

# Started already, the repo would be the test database's, not --db's.
if List.keymember?(Application.started_applications(), :hireme, 0),
  do: raise("run with mix run --no-start")

{opts, _, _} =
  OptionParser.parse(System.argv(),
    strict: [
      out: :string,
      today: :string,
      db: :string,
      account: :integer,
      seed: :integer,
      ops: :integer,
      name: :string
    ]
  )

out = Keyword.fetch!(opts, :out) |> Path.expand()
today = opts |> Keyword.get(:today, Date.to_iso8601(Date.utc_today())) |> Date.from_iso8601!()
seed = Keyword.get(opts, :seed)
File.mkdir_p!(out)

name =
  Keyword.get_lazy(opts, :name, fn ->
    if seed, do: "seed-#{seed}", else: opts |> Keyword.fetch!(:db) |> Path.basename(".db")
  end)

{database, fresh?} =
  case {opts[:db], seed} do
    {nil, nil} -> raise "pass --db PATH or --seed N"
    {nil, _} -> {Path.join(out, name <> ".db"), true}
    {db, _} -> {Path.expand(db), false}
  end

if fresh?, do: Enum.each(["", "-wal", "-shm"], &File.rm(database <> &1))

repo = Application.get_env(:hireme, Hireme.Repo)

Application.put_env(
  :hireme,
  Hireme.Repo,
  Keyword.merge(repo, database: database, pool: DBConnection.ConnectionPool, pool_size: 1)
)

Logger.configure(level: :warning)
{:ok, _} = Application.ensure_all_started(:hireme)
Ecto.Migrator.run(Hireme.Repo, :up, all: true, log: false)

account_id =
  if fresh? do
    account = Hireme.Accounts.create!(%{name: "Oracle #{seed}"})
    Hireme.Repo.put_account(account.id)
    Hireme.Oracle.generate(seed, today)
    account.id
  else
    Keyword.get(opts, :account, 1)
  end

Hireme.Repo.put_account(account_id)
ops = Hireme.Oracle.ops(seed || 0, Keyword.get(opts, :ops, 0))
lines = Hireme.Oracle.dump(today, seed: seed, ops: ops)
path = Path.join(out, name <> ".jsonl")
File.write!(path, Enum.map(lines, &[Hireme.Oracle.encode(&1), ?\n]))
IO.puts("#{path}: #{length(lines)} lines")
