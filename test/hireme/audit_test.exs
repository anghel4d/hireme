defmodule Hireme.AuditTest do
  use Hireme.DataCase, async: false

  alias Hireme.Audit

  defp kinds(account_id) do
    Repo.all(from(e in Hireme.Rows.Audit, where: e.account_id == ^account_id, select: e.kind),
      skip_account: true
    )
  end

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
        ), skip_account: true)

    assert row.meta["counts"] == %{"agent_ops" => %{"7" => 5}}
  end

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
end
