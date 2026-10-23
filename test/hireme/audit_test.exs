defmodule Hireme.AuditTest do
  use Hireme.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Hireme.Audit

  defp values(account_id, kind, col \\ :kind) do
    q = from(e in Hireme.Rows.Audit, where: e.account_id == ^account_id, select: field(e, ^col))
    q = if kind, do: where(q, [e], e.kind == ^kind), else: q
    Repo.all(q, skip_account: true)
  end

  defp rows(account_id, kind), do: length(values(account_id, kind))

  defp coalesced(account_id) do
    Audit.Coalescer.flush(:all)
    [meta] = values(account_id, "activity_coalesced", :meta)
    meta
  end

  defp ops(account_id, n, ctx \\ %{}) do
    ctx = Map.merge(%{account_id: account_id, key_id: 7}, ctx)
    for _ <- 1..n//1, do: :ok = Audit.record(:agent_ops, %{count: 1}, ctx)
  end

  defp hello(account_id, ip) do
    ctx = %{account_id: account_id, key_id: 9, ip: ip, user_agent: "agent/1"}
    Audit.record(:wire_key, %{}, ctx)
  end

  @tag window: [:activity, :activity_node]
  test "past its budget an account's activity coalesces into one row per window, its counts outliving the coalescer's own process; a security event never does" do
    %{account: a} = sign_in()
    ops(a.id, 1_005)
    :ok = Audit.record(:api_key_created, %{name: "k"}, %{account_id: a.id})
    assert rows(a.id, "agent_ops") == 1_000
    assert "api_key_created" in values(a.id, nil)
    pid = Process.whereis(Audit.Coalescer)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert coalesced(a.id)["counts"] == %{"agent_ops" => %{"7" => 5}}
  end

  @tag window: [:activity, :activity_node, :activity_floor]
  test "one account's flood of counted activity leaves the node's row ceiling to the others; past the ceiling an account still writes its floor" do
    %{account: loud} = sign_in()
    %{account: quiet} = sign_in()
    %{account: late} = sign_in()
    {_, node_max} = Hireme.Security.limits()[:activity_node]
    {_, floor} = Hireme.Security.limits()[:activity_floor]
    # Past its own budget every event of the loud account is only a count.
    ops(loud.id, node_max + 100)
    ops(quiet.id, 5, %{key_id: 8})
    assert rows(quiet.id, "agent_ops") == 5
    Hireme.Security.hit(:activity_node, :node, node_max)
    ops(late.id, floor + 5)
    assert rows(late.id, "agent_ops") == floor
  end

  @tag window: :revokes
  test "lease revokes past their budget coalesce too, and are never refused" do
    %{account: a} = sign_in()
    results = for _ <- 1..125, do: Audit.record(:lease_revoked, %{}, %{account_id: a.id})
    assert Enum.all?(results, &(&1 == :ok))
    assert rows(a.id, "lease_revoked") == 120
    Audit.Coalescer.flush(:all)
    assert "revokes_coalesced" in values(a.id, nil)
    # A revoke is a security event, coalesced or not.
    refute "revokes_coalesced" in Audit.activity_kinds()
  end

  @tag window: [:hellos, :activity_node]
  test "past the HELLO budget a key's first HELLO from each address is still its own row" do
    %{account: a} = sign_in()
    for _ <- 1..605, do: hello(a.id, "10.0.0.1")
    :ok = hello(a.id, "203.0.113.9")
    :ok = hello(a.id, "203.0.113.9")
    ips = values(a.id, "wire_key", :ip)
    assert "203.0.113.9" in ips and length(ips) == 601
    meta = coalesced(a.id)
    assert meta["counts"] == %{"wire_key" => %{"9" => 6}}
    assert Enum.sort(meta["addresses"]) == ["10.0.0.1", "203.0.113.9"]
    assert meta["user_agents"] == ["agent/1"]
  end

  @tag window: [:activity, :activity_node]
  test "a window tracks at most 1,000 addresses, names the busiest, and still counts the events of the rest" do
    %{account: a} = sign_in()
    ctx = &%{ip: &1, user_agent: "agent/1"}
    ops(a.id, 1_000)
    for _ <- 1..3, i <- 1..5, do: ops(a.id, 1, ctx.("203.0.113.#{i}"))
    for i <- 1..1_005, do: ops(a.id, 1, ctx.("198.51.#{div(i, 256)}.#{rem(i, 256)}"))
    meta = coalesced(a.id)
    assert meta["counts"] == %{"agent_ops" => %{"7" => 1_020}}
    assert meta["addresses_total"] == 1_000
    assert meta["addresses_untracked_events"] == 10
    assert meta["user_agents"] == ["agent/1"]
    assert Enum.map(1..5, &"203.0.113.#{&1}") -- meta["addresses"] == []
  end

  @tag window: [:hellos, :activity_node]
  test "a key's first HELLOs count a /64 as one peer, and only its first 50 peers a window" do
    %{account: a} = sign_in()
    {_, budget} = Hireme.Security.limits()[:hellos]
    for _ <- 1..budget, do: hello(a.id, "10.0.0.1")
    for i <- 1..10, do: :ok = hello(a.id, "2001:db8::#{i}")
    assert rows(a.id, "wire_key") == budget + 1
    # 10.0.0.1 and 2001:db8::/64 were two of the 50.
    for i <- 1..60, do: :ok = hello(a.id, "2001:db8:0:#{i}::1")
    assert rows(a.id, "wire_key") == budget + 1 + 48
  end

  @tag window: [:activity, :activity_node]
  test "events recorded while flushes run are each a row or a count, never lost" do
    %{account: a} = sign_in()
    {_, budget} = Hireme.Security.limits()[:activity]
    parent = self()

    recorders =
      for k <- 1..4 do
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())

          for i <- 1..3_000 do
            ip = "10.0.#{k}.#{rem(i, 50)}"
            ops(a.id, 1, %{key_id: k, ip: ip, user_agent: "agent/#{rem(i, 7)}"})
          end
        end)
      end

    # Flushes the open window over and over until every recorder is done.
    flusher =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        Stream.repeatedly(fn -> Audit.Coalescer.flush(:all) end)
        |> Enum.take_while(fn _ -> Enum.any?(recorders, &Process.alive?(&1.pid)) end)
      end)

    Task.await_many(recorders, 60_000)
    Task.await(flusher, 60_000)
    Audit.Coalescer.flush(:all)

    counted =
      for m <- values(a.id, "activity_coalesced", :meta),
          n <- Map.values(m["counts"]["agent_ops"]),
          do: n

    assert rows(a.id, "agent_ops") == budget
    assert budget + Enum.sum(counted) == 4 * 3_000
  end

  @tag window: :revokes
  test "a failed write puts its values back under the tracking cap, beside what came meanwhile" do
    %{account: a} = sign_in()
    ops(a.id, 1_000)
    ip = fn net, i -> %{ip: "10.#{net}.#{div(i, 250)}.#{rem(i, 250)}"} end
    for i <- 1..1_000, do: ops(a.id, 1, ip.(1, i))

    Repo.query!(
      "CREATE TRIGGER no_row BEFORE INSERT ON audit WHEN NEW.kind = 'activity_coalesced' " <>
        "BEGIN SELECT RAISE(ABORT, 'no'); END"
    )

    # The flush takes the window, then waits for the writer while new addresses arrive.
    parent = self()

    holder =
      Task.async(fn ->
        Hireme.Store.write(fn ->
          send(parent, :held)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :held

    flush =
      Task.async(fn -> ExUnit.CaptureLog.capture_log(fn -> Audit.Coalescer.flush(:all) end) end)

    Process.sleep(200)
    for i <- 1..1_000, do: ops(a.id, 1, ip.(2, i))
    send(holder.pid, :release)
    Task.await_many([holder, flush])
    Repo.query!("DROP TRIGGER no_row")
    meta = coalesced(a.id)
    assert meta["counts"] == %{"agent_ops" => %{"7" => 2_000}}
    assert meta["addresses_total"] == 1_000
    assert meta["addresses_untracked_events"] == 1_000
  end
end
