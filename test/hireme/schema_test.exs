defmodule Hireme.SchemaTest do
  # docs/rebuild.md: "`mix test` fails when a checked-in output differs from
  # a fresh emit".
  use ExUnit.Case, async: false

  alias Mix.Tasks.Hireme.Schema, as: SchemaTask

  test "the checked-in baseline, TypeScript and model JSON are a fresh emit" do
    Mix.shell(Mix.Shell.Process)

    try do
      SchemaTask.run(["--check"])
      assert_received {:mix_shell, :info, ["schema: " <> _]}
    after
      Mix.shell(Mix.Shell.IO)
    end
  end

  test "the Rust model's last day, emitted into the TypeScript, is the node's: 9999-12-31" do
    [_, emitted] =
      Regex.run(~r/^export const DAY_MAX = (\d+);$/m, File.read!("assets/js/gen/schema.ts"))

    assert String.to_integer(emitted) == Hireme.Schema.day_max()
    assert Date.from_gregorian_days(Hireme.Schema.day_max()) == ~D[9999-12-31]
  end
end

defmodule Hireme.SchemaCapTest do
  # Every table an account owns is bounded by its declared cap.
  use Hireme.WireCase, async: false

  test "every stored table an account owns has a cap; a write past it is refused cap, and a drop frees a slot",
       %{account: a} do
    for t <- Schema.tables(),
        t.residency in [:resident, :server],
        not t.global,
        do: assert(is_integer(t.cap) and t.cap > 0, t.name)

    cap = Schema.table(:profiles).cap
    ops = for i <- 1..cap, do: op(:put, :profiles, %{slug: "p#{i}", name: "P#{i}"})
    {acks, []} = run(a.id, ops)
    assert length(acks) == cap

    one_more = op(:put, :profiles, %{slug: "one-more", name: "One more"})
    assert {[], [%{refusal: :cap}]} = run(a.id, one_more)
    {[_], []} = run(a.id, op(:drop, :profiles, %{}, target: hd(acks).id))
    assert {[_], []} = run(a.id, one_more)
  end
end

defmodule Hireme.SchemaLooseRefTest do
  # A purge removes a key or a session, never who wrote a row that outlives
  # it: append-only rows and the ledger name them by a loose ref.
  use Hireme.WireCase, async: false

  import Ecto.Query
  alias Hireme.Rows.{ApiKey, Audit, Citation}

  test "purging a revoked key leaves the key_id of its citations and trail rows", %{
    account: a,
    session: s
  } do
    {:ok, %{key: key}} = Hireme.Keys.mint(s, "agent", Hireme.Keys.preset(:read_write))
    # The rows a key leaves behind: a citation of what it wrote and its trail.
    Repo.insert!(
      %Citation{
        account_id: a.id,
        table: "corporations",
        row_id: 1,
        column: "headcount",
        as_of: ~D[2026-01-01],
        actor: :agent,
        key_id: key.id
      },
      skip_account: true
    )

    :ok = Hireme.Audit.record(:agent_ops, %{n: 1}, %{account_id: a.id, key_id: key.id})

    Repo.delete_all(from(k in ApiKey, where: k.id == ^key.id), skip_account: true)

    assert Repo.all(from(c in Citation, where: c.column == "headcount", select: c.key_id),
             skip_account: true
           ) == [key.id]

    assert key.id in Repo.all(from(e in Audit, where: e.account_id == ^a.id, select: e.key_id),
             skip_account: true
           )
  end

  test "a loose ref is a plain id in the database" do
    for {t, c} <- [
          {"audit", "key_id"},
          {"audit", "session_id"},
          {"events", "key_id"},
          {"citations", "key_id"},
          {"citations", "source_id"},
          {"op_ledger", "key_id"}
        ] do
      assert Schema.column(t, c).loose, "#{t}.#{c}"
    end
  end
end
