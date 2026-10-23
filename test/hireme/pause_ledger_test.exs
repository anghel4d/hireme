defmodule Hireme.PauseLedgerTest do
  @moduledoc """
  The operator's pause of a key and the op ledger, through the sequencer:
  what a review's mutation run found unpinned, and its races.
  """

  use Hireme.WireCase, async: false
  import Ecto.Query

  alias Hireme.{Keys, Lease}
  alias Hireme.Rows.{ApiKey, OpLedger}

  defp key_row(id), do: Repo.get!(ApiKey, id, skip_account: true)

  defp mint(s, name, preset \\ :read_write),
    do: elem(Keys.mint(s, name, Keys.preset(preset)), 1).key

  defp seq(account_id),
    do: Registry.lookup(Hireme.Sequencer.Registry, account_id) |> hd() |> elem(0)

  defp open_session(a, key, sid) do
    info = %{id: sid, label: "again#{sid}", grants: Grants.key(key), key_id: key.id}
    {:ok, _} = Sequencer.subscribe(a.id, Map.put(info, :session_id, nil), 0)
  end

  defp paused_audits,
    do: Repo.all(from(e in Hireme.Rows.Audit, where: e.kind == "key_paused"), skip_account: true)

  defp set_paused(key, at),
    do:
      Repo.update_all(from(k in ApiKey, where: k.id == ^key.id), [set: [paused_at: at]],
        skip_account: true
      )

  defp ledger_ids(account_id) do
    q = from(l in OpLedger, where: l.account_id == ^account_id, order_by: l.id, select: l.op_id)
    Repo.all(q, skip_account: true)
  end

  # `n` of the operator's ledger entries from op `from_op`, written `age` seconds ago.
  defp insert_ledger(account_id, from_op, n, age \\ 0) do
    at = DateTime.add(Hireme.Store.now(), -age)
    entry = %{account_id: account_id, key_id: nil, writer: 0, verb: :put, subject: 1, target: 0}
    entry = Map.merge(entry, %{ack_rev: 1, rev: 1, inserted_at: at, updated_at: at})
    rows = for i <- from_op..(from_op + n - 1)//1, do: Map.merge(entry, %{op_id: i, row_id: i})

    for chunk <- Enum.chunk_every(rows, 2_000),
        do: Repo.insert_all(OpLedger, chunk, skip_account: true)
  end

  defp skill(slug), do: op(:put, :items, %{kind: :skill, key: "s-#{slug}", title: slug})

  # ------------------------------------------------------------ the ledger

  test "at the cap the ledger evicts this account's oldest 1% and keeps the newest; another account's older rows neither shield it nor are lost",
       %{account: a} do
    t = Hireme.Schema.table("op_ledger")
    window = div(t.cap, 100)
    base = 1_000_000_000
    b = Hireme.DataCase.sign_in()

    # B's rows are the node's oldest ids, as many as an eviction takes.
    insert_ledger(b.account.id, 1, window)
    insert_ledger(a.id, base + 1, window + 1)
    ack!(a.id, skill("one"))
    assert length(ledger_ids(a.id)) == window + 2

    # The cached count says the ledger is full.
    :sys.replace_state(seq(a.id), &put_in(&1.counts[t.id], t.cap))
    ack!(a.id, skill("two"))

    # The oldest `window` went; the newest of the old rows, the first op's
    # entry and this op's entry stay.
    ids = ledger_ids(a.id)
    assert length(ids) == 3
    assert (base + window + 1) in ids and (base + 1) not in ids
    assert length(ledger_ids(b.account.id)) == window
  end

  test "the purge takes this account's expired entries and ends; live ones and another account's stay; an entry older than a day no longer answers a resend",
       %{account: a} do
    b = Hireme.DataCase.sign_in()
    insert_ledger(b.account.id, 1, 5_001, 25 * 3600)
    insert_ledger(a.id, 10_000, 12_000, 25 * 3600)
    insert_ledger(a.id, 30_000, 1)

    # A contact with no address has no key, so a resend the ledger forgot makes a second row.
    put = op(:put, :contacts, %{name: "old"}, op_id: 4242)
    first = ack!(a.id, put)
    assert eventually(fn -> length(ledger_ids(a.id)) == 2 end)

    # And it is over: an idle sequencer, not one re-selecting rows it cannot delete.
    pid = seq(a.id)
    {:reductions, r1} = Process.info(pid, :reductions)
    Process.sleep(150)
    {:reductions, r2} = Process.info(pid, :reductions)
    assert r2 - r1 < 50_000
    assert length(ledger_ids(b.account.id)) == 5_001

    # (The sign-in of b scoped this process to b.)
    Repo.put_account(a.id)
    old = DateTime.add(Hireme.Store.now(), -25 * 3600)
    Repo.update_all(from(l in OpLedger, where: l.op_id == 4242), set: [inserted_at: old])
    assert ack!(a.id, put).id != first.id
  end

  # ---------------------------------------------------------- the pause

  test "an operator (browser) session's revoke closes it, says why, and pauses no key",
       %{account: a, session: s} do
    key = mint(s, "bystander")
    info = &%{id: &1, label: "b#{&1}", grants: Grants.operator(), key_id: nil, session_id: nil}
    {:ok, %{lease: true}} = Sequencer.subscribe(a.id, info.(700), 0)
    assert :ok = Lease.revoke(a.id, 700, %{})

    assert {:refused, :lease_missing, %{reason: "the operator revoked" <> _} = data} =
             Lease.claim(a.id, 700, %{})

    refute Map.has_key?(data, :paused)
    assert key_row(key.id).paused_at == nil
    # Reconnecting takes the channel again, as it always did.
    assert {:ok, %{lease: true}} = Sequencer.subscribe(a.id, info.(701), 0)
  end

  test "the pause keeps the time of the first revoke, in the row and in what the agent is told, across a restart, until the operator resumes the key",
       %{account: a, session: s} do
    key = mint(s, "since")
    {_agent, _} = key_session(a.id, key, 996)
    past = ~U[2026-10-01 00:00:00Z]
    # Paused earlier (the row says so); the sequencer's memory only learns at the revoke.
    set_paused(key, past)
    :ok = Lease.revoke(a.id, 996, %{})
    assert key_row(key.id).paused_at == past
    since = "2026-10-01T00:00:00Z"
    assert {:refused, :lease_missing, %{since: ^since}} = Lease.claim(a.id, 996, %{})

    stop_sequencer(a.id)
    open_session(a, key, 997)

    assert {:refused, :lease_missing, %{paused: true, since: ^since}} =
             Lease.claim(a.id, 997, %{})

    {:ok, _} = Keys.resume(key_row(key.id))
    assert {:ok, _} = Lease.claim(a.id, 997, %{})
  end

  test "a held key learns it is paused from a write even when it cannot read the table; the pause is recorded once, when it begins, with who and from where",
       %{account: a, session: s} do
    key = mint(s, "write-only", :write_only)
    {agent, _} = key_session(a.id, key, 902)
    :ok = Lease.revoke(a.id, 902, %{ip: "203.0.113.9"})
    :ok = Lease.revoke(a.id, 902, %{})
    assert [%{ip: "203.0.113.9"}] = paused_audits()
    put = op(:put, :corporations, %{domain: "wo.example", name: "W"})
    {[], [nack]} = key_session_ops(agent, put)
    assert nack.refusal == :lease_missing
    assert %{"paused" => true, "reason" => "paused by the operator"} = JSON.decode!(nack.data)
  end

  test "a lease revoke landing before the key's own revoke is heard does not pause a revoked key",
       %{account: a, session: s} do
    key = mint(s, "revoked-late")
    {_agent, _} = key_session(a.id, key, 903)
    pid = seq(a.id)
    :sys.suspend(pid)
    t = Task.async(fn -> Lease.revoke(a.id, 903, %{}) end)
    Process.sleep(100)
    Keys.revoke(key_row(key.id))
    :sys.resume(pid)
    assert :ok = Task.await(t)
    Process.sleep(100)
    row = key_row(key.id)
    assert row.revoked_at != nil and row.paused_at == nil
    assert paused_audits() == []
  end

  test "a Resume that lands between the sequencer's load and its subscription is not lost",
       %{account: a, session: s} do
    key = mint(s, "window")
    {_agent, _} = key_session(a.id, key, 904)
    :ok = Lease.revoke(a.id, 904, %{})
    assert key_row(key.id).paused_at
    stop_sequencer(a.id)
    fired = :atomics.new(1, [])
    kid = key.id
    handler = "rev3-window-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:hireme, :repo, :query],
      fn _e, _m, meta, _c ->
        # paused_keys has just returned inside init/1: the operator's Resume lands here.
        if String.contains?(meta.query, ~s(SELECT a0."id", a0."paused_at" FROM "api_keys")) and
             :atomics.compare_exchange(fired, 1, 0, 1) == :ok do
          {:ok, _} = Keys.resume(key_row(kid))
        end
      end,
      nil
    )

    open_session(a, key, 905)
    :telemetry.detach(handler)
    assert key_row(kid).paused_at == nil
    assert {:ok, _} = Lease.claim(a.id, 905, %{})
  end

  test "a re-pause that lands before an earlier Resume's message stands",
       %{account: a, session: s} do
    key = mint(s, "repause")
    {_agent, _} = key_session(a.id, key, 906)
    :ok = Lease.revoke(a.id, 906, %{})
    # Keys.resume, in its steps: the row is cleared ...
    set_paused(key, nil)
    # ... the operator revokes the idle lease again before the message is sent ...
    :ok = Lease.revoke(a.id, 906, %{})
    assert key_row(key.id).paused_at
    # ... and Keys.resume's broadcast arrives.
    send(seq(a.id), {:resume, {:key, key.id}})
    _ = :sys.get_state(seq(a.id))
    assert {:refused, :lease_missing, %{paused: true}} = Lease.claim(a.id, 906, %{})
  end
end
