defmodule Hireme.AuditTest do
  use Hireme.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Hireme.Audit

  defp kinds(account_id) do
    Repo.all(from(e in Hireme.Rows.Audit, where: e.account_id == ^account_id, select: e.kind),
      skip_account: true
    )
  end

  @tag window: [:activity, :activity_node]
  test "past its budget an account's activity coalesces into one row per window" do
    %{account: a} = sign_in()

    for _ <- 1..1_005,
        do: :ok = Audit.record(:agent_ops, %{count: 1}, %{account_id: a.id, key_id: 7})

    assert Enum.count(kinds(a.id), &(&1 == "agent_ops")) == 1_000

    Audit.Coalescer.flush(:all)

    [row] =
      Repo.all(
        from(e in Hireme.Rows.Audit,
          where: e.account_id == ^a.id and e.kind == "activity_coalesced"
        ),
        skip_account: true
      )

    assert row.meta["counts"] == %{"agent_ops" => %{"7" => 5}}
  end

  @tag window: [:activity, :activity_node]
  test "one account's flood of counted activity leaves the node's row ceiling to the others" do
    %{account: loud} = sign_in()
    %{account: quiet} = sign_in()
    {_, node_max} = Hireme.Security.limits()[:activity_node]

    # Past its own budget every event of the loud account is only a count.
    for _ <- 1..(node_max + 100),
        do: :ok = Audit.record(:agent_ops, %{count: 1}, %{account_id: loud.id, key_id: 7})

    for _ <- 1..5,
        do: :ok = Audit.record(:agent_ops, %{count: 1}, %{account_id: quiet.id, key_id: 8})

    assert Enum.count(kinds(quiet.id), &(&1 == "agent_ops")) == 5
  end

  @tag window: [:activity, :activity_node, :activity_floor]
  test "past the node's ceiling an account still writes its floor" do
    %{account: a} = sign_in()
    {_, node_max} = Hireme.Security.limits()[:activity_node]
    {_, floor} = Hireme.Security.limits()[:activity_floor]
    Hireme.Security.hit(:activity_node, :node, node_max)

    for _ <- 1..(floor + 5),
        do: :ok = Audit.record(:agent_ops, %{count: 1}, %{account_id: a.id, key_id: 7})

    assert Enum.count(kinds(a.id), &(&1 == "agent_ops")) == floor
  end

  @tag window: :revokes
  test "lease revokes past their budget coalesce too, and are never refused" do
    %{account: a} = sign_in()
    results = for _ <- 1..125, do: Audit.record(:lease_revoked, %{}, %{account_id: a.id})
    assert Enum.all?(results, &(&1 == :ok))
    assert Enum.count(kinds(a.id), &(&1 == "lease_revoked")) == 120
    Audit.Coalescer.flush(:all)
    assert "revokes_coalesced" in kinds(a.id)
    # A revoke is a security event, coalesced or not.
    refute "revokes_coalesced" in Audit.activity_kinds()
  end

  test "a security event is never coalesced" do
    %{account: a} = sign_in()
    for _ <- 1..1_100, do: Audit.record(:agent_ops, %{}, %{account_id: a.id})
    :ok = Audit.record(:api_key_created, %{name: "k"}, %{account_id: a.id})
    assert "api_key_created" in kinds(a.id)
  end

  @tag window: [:hellos, :activity_node]
  test "past the HELLO budget a key's first HELLO from each address is still its own row" do
    %{account: a} = sign_in()
    ctx = fn ip -> %{account_id: a.id, key_id: 9, ip: ip, user_agent: "agent/1"} end
    for _ <- 1..600, do: Audit.record(:wire_key, %{}, ctx.("10.0.0.1"))
    for _ <- 1..5, do: Audit.record(:wire_key, %{}, ctx.("10.0.0.1"))
    :ok = Audit.record(:wire_key, %{}, ctx.("203.0.113.9"))
    :ok = Audit.record(:wire_key, %{}, ctx.("203.0.113.9"))

    ips =
      Repo.all(
        from(e in Hireme.Rows.Audit,
          where: e.account_id == ^a.id and e.kind == "wire_key",
          select: e.ip
        ),
        skip_account: true
      )

    assert "203.0.113.9" in ips
    assert length(ips) == 601

    Audit.Coalescer.flush(:all)

    [row] =
      Repo.all(
        from(e in Hireme.Rows.Audit,
          where: e.account_id == ^a.id and e.kind == "activity_coalesced"
        ),
        skip_account: true
      )

    assert row.meta["counts"] == %{"wire_key" => %{"9" => 6}}
    assert Enum.sort(row.meta["addresses"]) == ["10.0.0.1", "203.0.113.9"]
    assert row.meta["user_agents"] == ["agent/1"]
  end

  @tag window: [:activity, :activity_node]
  test "a window tracks at most 1,000 addresses; events from the rest are still counted" do
    %{account: a} = sign_in()
    for _ <- 1..1_000, do: Audit.record(:agent_ops, %{}, %{account_id: a.id, key_id: 7})

    for i <- 1..1_005,
        do:
          Audit.record(:agent_ops, %{}, %{
            account_id: a.id,
            key_id: 7,
            ip: "198.51.#{div(i, 256)}.#{rem(i, 256)}",
            user_agent: "agent/1"
          })

    Audit.Coalescer.flush(:all)

    [meta] =
      Repo.all(
        from(e in Hireme.Rows.Audit,
          where: e.account_id == ^a.id and e.kind == "activity_coalesced",
          select: e.meta
        ),
        skip_account: true
      )

    assert meta["counts"] == %{"agent_ops" => %{"7" => 1_005}}
    assert meta["addresses_total"] == 1_000
    assert meta["addresses_untracked_events"] == 5
    assert meta["user_agents"] == ["agent/1"]
  end

  @tag window: [:activity, :activity_node]
  test "a coalesced row names the addresses with the most events, not the lowest-sorting" do
    %{account: a} = sign_in()
    ctx = fn ip -> %{account_id: a.id, key_id: 7, ip: ip, user_agent: "agent/1"} end
    for _ <- 1..1_000, do: Audit.record(:agent_ops, %{}, %{account_id: a.id, key_id: 7})
    for i <- 1..25, do: Audit.record(:agent_ops, %{}, ctx.("10.0.0.#{i}"))
    for _ <- 1..3, i <- 1..5, do: Audit.record(:agent_ops, %{}, ctx.("203.0.113.#{i}"))
    Audit.Coalescer.flush(:all)

    [meta] =
      Repo.all(
        from(e in Hireme.Rows.Audit,
          where: e.account_id == ^a.id and e.kind == "activity_coalesced",
          select: e.meta
        ),
        skip_account: true
      )

    busiest = for i <- 1..5, do: "203.0.113.#{i}"
    assert busiest -- meta["addresses"] == []
    assert meta["addresses_total"] == 30
  end

  @tag window: [:hellos, :activity_node]
  test "a key's first HELLOs count a /64 as one peer, and only its first 50 peers a window" do
    %{account: a} = sign_in()
    ctx = fn ip -> %{account_id: a.id, key_id: 9, ip: ip, user_agent: "agent/1"} end
    {_, budget} = Hireme.Security.limits()[:hellos]
    for _ <- 1..budget, do: Audit.record(:wire_key, %{}, ctx.("10.0.0.1"))
    hellos = fn -> Enum.count(kinds(a.id), &(&1 == "wire_key")) end

    for i <- 1..10, do: :ok = Audit.record(:wire_key, %{}, ctx.("2001:db8::#{i}"))
    assert hellos.() == budget + 1

    # 10.0.0.1 and 2001:db8::/64 were two of the 50.
    for i <- 1..60, do: :ok = Audit.record(:wire_key, %{}, ctx.("2001:db8:0:#{i}::1"))
    assert hellos.() == budget + 1 + 48

    # Peers past the 50 leave nothing held for them.
    for i <- 1..500,
        do: :ok = Audit.record(:wire_key, %{}, ctx.("192.0.#{div(i, 256)}.#{rem(i, 256)}"))

    marks = :ets.select_count(Audit.Coalescer, [{{{:first, :_, :_, :_, :_}, :_}, [], [true]}])
    assert marks <= 51
  end

  @tag window: [:activity, :activity_node]
  test "a coalesced lease change still moves the cursor and wakes the account's watchers" do
    %{account: a} = sign_in()
    for _ <- 1..1_000, do: Audit.record(:lease_opened, %{}, %{account_id: a.id})
    cursor = Audit.rev(a.id)
    Phoenix.PubSub.subscribe(Hireme.PubSub, Audit.topic(a.id))
    # Recorded by another process, as the sequencer records it: a process
    # never hears its own announcement.
    parent = self()

    Task.await(
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        Audit.record(:lease_released, %{}, %{account_id: a.id})
      end)
    )

    assert Audit.rev(a.id) == cursor + 1
    assert_receive {Hireme.Audit, :changed}
  end

  @tag window: [:activity, :activity_node]
  test "a burst of coalesced lease changes wakes the watchers once, and once more after it" do
    %{account: a} = sign_in()
    for _ <- 1..1_000, do: Audit.record(:lease_opened, %{}, %{account_id: a.id})
    cursor = Audit.rev(a.id)
    Phoenix.PubSub.subscribe(Hireme.PubSub, Audit.topic(a.id))
    parent = self()
    t0 = System.monotonic_time(:millisecond)

    Task.await(
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        for _ <- 1..20, do: Audit.record(:lease_released, %{}, %{account_id: a.id})
      end)
    )

    seconds = div(System.monotonic_time(:millisecond) - t0, 1000)
    # The burst's last change still arrives: a wake follows it.
    assert_receive {Hireme.Audit, :changed}
    assert_receive {Hireme.Audit, :changed}, 2_000

    wakes =
      2 +
        Enum.count(
          Stream.repeatedly(fn -> receive do: (m -> m), after: (1_500 -> nil) end)
          |> Enum.take_while(& &1)
        )

    assert wakes <= seconds + 2
    assert Audit.rev(a.id) == cursor + wakes
  end

  @tag window: [:activity, :activity_node]
  test "a trailing wake whose message was lost does not silence the next ones" do
    %{account: a} = sign_in()
    for _ <- 1..1_000, do: Audit.record(:lease_opened, %{}, %{account_id: a.id})
    # As if its timer fired while the Coalescer was restarting: a marker long past due.
    past = System.os_time(:millisecond) - 5_000
    :ets.insert(Audit.Coalescer, {{:trailing, a.id}, past})
    send(Audit.Coalescer, :flush)
    Process.sleep(1_100)
    cursor = Audit.rev(a.id)
    Audit.record(:lease_opened, %{}, %{account_id: a.id})
    Audit.record(:lease_opened, %{}, %{account_id: a.id})
    Process.sleep(1_500)
    assert Audit.rev(a.id) == cursor + 2
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
            Audit.record(:agent_ops, %{}, %{
              account_id: a.id,
              key_id: k,
              ip: "10.0.#{k}.#{rem(i, 50)}",
              user_agent: "agent/#{rem(i, 7)}"
            })
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

    rows = Enum.count(kinds(a.id), &(&1 == "agent_ops"))

    counted =
      Repo.all(
        from(e in Hireme.Rows.Audit,
          where: e.account_id == ^a.id and e.kind == "activity_coalesced",
          select: e.meta
        ),
        skip_account: true
      )
      |> Enum.flat_map(&Map.values(&1["counts"]["agent_ops"]))
      |> Enum.sum()

    assert rows == budget
    assert rows + counted == 4 * 3_000
  end

  @tag window: [:activity, :activity_node]
  test "the counts outlive the coalescer's own process" do
    %{account: a} = sign_in()
    for _ <- 1..1_003, do: Audit.record(:agent_ops, %{}, %{account_id: a.id, key_id: 1})
    pid = Process.whereis(Audit.Coalescer)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    Audit.Coalescer.flush(:all)

    [row] =
      Repo.all(
        from(e in Hireme.Rows.Audit,
          where: e.account_id == ^a.id and e.kind == "activity_coalesced"
        ),
        skip_account: true
      )

    assert row.meta["counts"] == %{"agent_ops" => %{"1" => 3}}
  end
end
