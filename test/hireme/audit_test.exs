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

  @tag window: :revokes
  test "lease revokes past their budget coalesce too, and are never refused" do
    %{account: a} = sign_in()
    results = for _ <- 1..125, do: Audit.record(:lease_revoked, %{}, %{account_id: a.id})
    assert Enum.all?(results, &(&1 == :ok))
    assert Enum.count(kinds(a.id), &(&1 == "lease_revoked")) == 120
    Audit.Coalescer.flush(:all)
    assert "revokes_coalesced" in kinds(a.id)
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
