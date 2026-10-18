defmodule Hireme.PauseLedgerTest do
  @moduledoc """
  The operator's pause of a key and the op ledger's cap, through the
  sequencer: what a review's mutation run found unpinned, and its races.
  """

  use Hireme.WireCase, async: false
  import Ecto.Query

  alias Hireme.{Keys, Lease}
  alias Hireme.Rows.{ApiKey, OpLedger}

  defp key_row(id), do: Repo.get!(ApiKey, id, skip_account: true)

  defp mint(s, name, preset \\ :read_write) do
    {:ok, %{key: key}} = Keys.mint(s, name, Keys.preset(preset))
    key
  end

  defp seq(account_id),
    do: Registry.lookup(Hireme.Sequencer.Registry, account_id) |> hd() |> elem(0)

  defp stop_seq(account_id) do
    DynamicSupervisor.terminate_child(Hireme.Sequencer.Dynamic, seq(account_id))
    # the sandbox connection of the killed process is torn down; let it settle
    Process.sleep(300)
  end

  defp open_session(a, key, sid) do
    info = %{
      id: sid,
      label: "again#{sid}",
      grants: Hireme.Grants.key(key),
      key_id: key.id,
      session_id: nil
    }

    {:ok, _} = Hireme.Sequencer.subscribe(a.id, info, 0)
  end

  defp ledger_ids(account_id),
    do:
      Repo.all(
        from(l in OpLedger,
          where: l.account_id == ^account_id,
          order_by: l.id,
          select: l.op_id
        ),
        skip_account: true
      )

  defp ledger_rows(account_id, from_op, n) do
    now = Hireme.Store.now()

    for i <- from_op..(from_op + n - 1)//1,
        do: %{
          account_id: account_id,
          op_id: i,
          key_id: nil,
          writer: 0,
          verb: :put,
          subject: 1,
          target: 0,
          row_id: i,
          ack_rev: 1,
          rev: 1,
          inserted_at: now,
          updated_at: now
        }
  end

  defp insert_ledger(rows) do
    for chunk <- Enum.chunk_every(rows, 2_000),
        do: Repo.insert_all(OpLedger, chunk, skip_account: true)
  end

  defp gym(slug),
    do: op(:put, :gym_reps, %{platform: :other, slug: slug, done_on: ~D[2026-10-01]})

  defp ledger_table, do: Hireme.Schema.table("op_ledger")

  # ------------------------------------------------------------ the ledger

  test "at the cap the ledger evicts this account's oldest 1% and keeps the newest",
       %{account: a} do
    t = ledger_table()
    window = div(t.cap, 100)
    base = 1_000_000_000

    insert_ledger(ledger_rows(a.id, base + 1, window + 1))
    {[_], []} = run(a.id, gym("one"))
    assert length(ledger_ids(a.id)) == window + 2

    :sys.replace_state(seq(a.id), &put_in(&1.counts[t.id], t.cap))
    {[_], []} = run(a.id, gym("two"))

    ids = ledger_ids(a.id)
    # the oldest `window` went; the newest of the old rows, the first op's entry
    # and this op's entry stay
    assert length(ids) == 3
    assert (base + window + 1) in ids
    refute (base + 1) in ids
  end

  test "another account's older ledger rows neither shield this account's eviction nor are lost",
       %{account: a} do
    t = ledger_table()
    b = Hireme.DataCase.sign_in()
    window = div(t.cap, 100)

    # B's rows are the globally oldest ids, as many as an eviction takes.
    insert_ledger(ledger_rows(b.account.id, 1, window))
    for s <- ["a", "b", "c"], do: {[_], []} = run(a.id, gym(s))

    :sys.replace_state(seq(a.id), &put_in(&1.counts[t.id], t.cap))
    {[_], []} = run(a.id, gym("d"))

    assert length(ledger_ids(a.id)) == 1
    assert length(ledger_ids(b.account.id)) == window
  end

  test "the purge ends once this account's expired rows are gone, in chunks of at most 5,000", %{
    account: a
  } do
    old = DateTime.add(Hireme.Store.now(), -25 * 3600)
    expire = fn rows -> for r <- rows, do: %{r | inserted_at: old, updated_at: old} end
    b = Hireme.DataCase.sign_in()
    insert_ledger(expire.(ledger_rows(b.account.id, 1, 5_001)))
    insert_ledger(expire.(ledger_rows(a.id, 10_000, 12_000)) ++ ledger_rows(a.id, 30_000, 1))

    me = self()
    handler = "zz-purge-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:hireme, :repo, :query],
      fn _e, _m, meta, _c ->
        if String.contains?(meta.query, ~s(DELETE FROM "op_ledger")),
          do: send(me, {:delete, length(meta.params)})
      end,
      nil
    )

    {[_], []} = run(a.id, gym("after"))
    assert eventually(fn -> length(ledger_ids(a.id)) == 2 end)
    :telemetry.detach(handler)

    # three chunk deletes for 12,000 expired rows (5,000 + 5,000 + 2,000), none bigger
    sizes =
      for _ <- 1..3,
          do:
            (
              assert_receive {:delete, n}, 1_000
              n
            )

    assert Enum.all?(sizes, &(&1 <= 5_001))
    refute_receive {:delete, _}, 100

    # and it is over: an idle sequencer, not one re-selecting rows it cannot delete
    pid = seq(a.id)
    {:reductions, r1} = Process.info(pid, :reductions)
    Process.sleep(150)
    {:reductions, r2} = Process.info(pid, :reductions)
    assert r2 - r1 < 50_000
    assert length(ledger_ids(b.account.id)) == 5_001
  end

  # ---- P1: a purge drops the cached ledger count

  test "a purge drops the cached ledger count", %{account: a} do
    {[_], []} = run(a.id, gym("warm"))
    t = Hireme.Schema.table("op_ledger")
    :sys.replace_state(seq(a.id), &put_in(&1.counts[t.id], t.cap))
    send(seq(a.id), :purge_more)
    refute Map.has_key?(:sys.get_state(seq(a.id)).counts, t.id)
  end

  defp eventually(f, tries \\ 100) do
    cond do
      f.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(f, tries - 1)
    end
  end

  # ---------------------------------------------------------- the pause

  test "an operator (browser) session's revoke closes it, says why, and pauses no key",
       %{account: a, session: s} do
    key = mint(s, "bystander")

    info = fn id ->
      %{id: id, label: "b#{id}", grants: Hireme.Grants.operator(), key_id: nil, session_id: nil}
    end

    {:ok, %{lease: true}} = Hireme.Sequencer.subscribe(a.id, info.(700), 0)
    assert :ok = Lease.revoke(a.id, 700, %{})

    assert {:refused, :lease_missing, %{reason: "the operator revoked" <> _} = data} =
             Lease.claim(a.id, 700, %{})

    refute Map.has_key?(data, :paused)
    assert key_row(key.id).paused_at == nil

    # reconnecting takes the channel again, as it always did
    assert {:ok, %{lease: true}} = Hireme.Sequencer.subscribe(a.id, info.(701), 0)
  end

  test "the pause keeps the time of the first revoke, in the row and in what the agent is told",
       %{account: a, session: s} do
    key = mint(s, "since")
    {_agent, _} = key_session(a.id, key, 996)
    past = ~U[2026-10-01 00:00:00Z]

    # paused earlier (the row says so); the sequencer's memory only learns at the revoke
    from(k in ApiKey, where: k.id == ^key.id)
    |> Repo.update_all([set: [paused_at: past]], skip_account: true)

    :ok = Lease.revoke(a.id, 996, %{})
    assert key_row(key.id).paused_at == past

    assert {:refused, :lease_missing, %{since: "2026-10-01T00:00:00Z"}} =
             Lease.claim(a.id, 996, %{})

    # and across a restart
    stop_seq(a.id)
    open_session(a, key, 997)

    assert {:refused, :lease_missing, %{since: "2026-10-01T00:00:00Z"}} =
             Lease.claim(a.id, 997, %{})
  end

  test "a held key learns it is paused from a write even when it cannot read the table",
       %{account: a, session: s} do
    key = mint(s, "write-only", :write_only)
    {agent, _} = key_session(a.id, key, 902)
    :ok = Lease.revoke(a.id, 902, %{})

    {[], [nack]} =
      key_session_ops(agent, op(:put, :corporations, %{domain: "wo.example", name: "W"}))

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
    assert row.revoked_at
    assert row.paused_at == nil
    refute Map.has_key?(:sys.get_state(pid).lease.paused, key.id)
  end

  test "a Resume that lands between the sequencer's load and its subscription is not lost",
       %{account: a, session: s} do
    key = mint(s, "window")
    {_agent, _} = key_session(a.id, key, 904)
    :ok = Lease.revoke(a.id, 904, %{})
    assert key_row(key.id).paused_at
    stop_seq(a.id)

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

  test "a Resume message corrects a stale in-memory pause time to the row's", %{
    account: a,
    session: s
  } do
    key = mint(s, "since2")
    {_agent, _} = key_session(a.id, key, 907)
    :ok = Lease.revoke(a.id, 907, %{})

    :sys.replace_state(seq(a.id), fn st ->
      put_in(st.lease.paused[key.id], ~U[2026-09-01 00:00:00Z])
    end)

    send(seq(a.id), {:resume, {:key, key.id}})
    _ = :sys.get_state(seq(a.id))

    row_since = DateTime.to_iso8601(key_row(key.id).paused_at)
    assert {:refused, :lease_missing, %{since: ^row_since}} = Lease.claim(a.id, 907, %{})
  end

  # ---- Q6: a lease revoke landing after the key's own revoke holds nothing in memory

  test "a re-pause that lands before an earlier Resume's message stands", %{
    account: a,
    session: s
  } do
    key = mint(s, "repause")
    {_agent, _} = key_session(a.id, key, 906)
    :ok = Lease.revoke(a.id, 906, %{})

    # Keys.resume, in its steps: the row is cleared ...
    from(k in ApiKey, where: k.id == ^key.id)
    |> Repo.update_all([set: [paused_at: nil]], skip_account: true)

    # ... the operator revokes the idle lease again before the message is sent ...
    :ok = Lease.revoke(a.id, 906, %{})
    assert key_row(key.id).paused_at

    # ... and Keys.resume's broadcast arrives.
    send(seq(a.id), {:resume, {:key, key.id}})
    _ = :sys.get_state(seq(a.id))

    assert {:refused, :lease_missing, %{paused: true}} = Lease.claim(a.id, 906, %{})
  end
end
