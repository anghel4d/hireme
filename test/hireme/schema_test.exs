defmodule Hireme.SchemaTest do
  # docs/rebuild.md: `mix test` fails when the declaration's baseline does
  # not apply, left the frozen one without a migration, or moved an id.
  use ExUnit.Case, async: false

  test "the declaration's outputs apply, match the frozen baseline and keep every id; the Rust model's last day, emitted into the TypeScript, is the node's: 9999-12-31" do
    Mix.shell(Mix.Shell.Process)

    try do
      Mix.Tasks.Hireme.Schema.run(["--check"])
      assert_received {:mix_shell, :info, ["schema: " <> _]}
    after
      Mix.shell(Mix.Shell.IO)
    end

    ts = File.read!("assets/js/gen/schema.ts")
    [_, emitted] = Regex.run(~r/^export const DAY_MAX = (\d+);$/m, ts)
    assert String.to_integer(emitted) == Hireme.Schema.day_max()
    assert Date.from_gregorian_days(Hireme.Schema.day_max()) == ~D[9999-12-31]
  end
end

defmodule Hireme.SchemaRowsTest do
  use Hireme.WireCase, async: false

  import Ecto.Query
  alias Hireme.Rows.{ApiKey, Audit, Citation}

  test "every stored table an account owns has a cap; a write past it is refused cap, and a drop frees a slot",
       %{account: a} do
    for t <- Schema.tables(),
        t.residency in [:resident, :server],
        not t.global,
        do: assert(is_integer(t.cap) and t.cap > 0, t.name)

    cap = Schema.table(:profiles).cap

    {acks, []} =
      run(a.id, for(i <- 1..cap, do: op(:put, :profiles, %{slug: "p#{i}", name: "P#{i}"})))

    assert length(acks) == cap
    one_more = op(:put, :profiles, %{slug: "one-more", name: "One more"})
    assert nack!(a.id, one_more) == :cap
    ack!(a.id, op(:drop, :profiles, %{}, target: hd(acks).id))
    ack!(a.id, one_more)
  end

  # A purge removes a key or a session, never who wrote a row that outlives
  # it: append-only rows and the ledger name them by a loose ref, a plain id.
  test "purging a revoked key leaves the key_id of its citations and trail rows", %{
    account: a,
    session: s
  } do
    for t <- ~w(audit events citations op_ledger),
        c <- ~w(key_id session_id source_id),
        col = Schema.column(t, c),
        do: assert(col.loose, "#{t}.#{c}")

    {:ok, %{key: key}} = Hireme.Keys.mint(s, "agent", Hireme.Keys.preset(:read_write))
    cite = %Citation{table: "corporations", row_id: 1, column: "headcount", actor: :agent}

    Repo.insert!(%{cite | account_id: a.id, as_of: ~D[2026-01-01], key_id: key.id},
      skip_account: true
    )

    :ok = Hireme.Audit.record(:agent_ops, %{n: 1}, %{account_id: a.id, key_id: key.id})
    Repo.delete_all(from(k in ApiKey, where: k.id == ^key.id), skip_account: true)
    cited = from(c in Citation, where: c.column == "headcount", select: c.key_id)
    assert Repo.all(cited, skip_account: true) == [key.id]
    trail = from(e in Audit, where: e.account_id == ^a.id, select: e.key_id)
    assert key.id in Repo.all(trail, skip_account: true)
  end
end
