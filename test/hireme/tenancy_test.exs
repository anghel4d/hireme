defmodule Hireme.TenancyTest do
  use Hireme.DataCase, async: false
  import Hireme.Fixtures

  alias Hireme.Desk.Job
  alias Hireme.Letterbox
  alias Hireme.Repo

  test "one account's rows do not exist for another" do
    job = job(profile(), %{company: "Mine Co"})
    assert [%{id: id}] = Repo.all(Job)
    assert id == job.id
    Hireme.Audit.record(:session_started, %{marker: "mine"}, %{account_id: Repo.account_id!()})

    other = Hireme.DataCase.open_account("Other desk")
    assert Repo.all(Job) == []
    assert Repo.get(Job, job.id) == nil
    refute Enum.any?(Hireme.Audit.recent(), &(&1.meta["marker"] == "mine"))
    assert {:error, %{code: :empty, n: 0}} = Letterbox.acquire({:count, 16})
    op = %{op_id: System.unique_integer([:positive]), kind: :next, target: id, fields: ["x", ""]}
    assert {:error, :not_found} = Hireme.Ops.run(other.id, op)
  end

  test "a write publishes only on its own desk's topic" do
    other = Hireme.Accounts.create!(%{name: "Listener"})
    Phoenix.PubSub.subscribe(Hireme.PubSub, Hireme.Desk.topic(other.id))
    job = job(profile(), %{company: "Mine"})
    Hireme.Desk.set_stage(job.id, :gated)
    refute_receive {:ops_delta, _, _}, 200
  end

  test "a read with no account on the process is refused, and so is a write" do
    Repo.put_account(nil)
    assert_raise ArgumentError, ~r/no account on the process/, fn -> Repo.all(Job) end

    assert_raise Ecto.InvalidChangesetError, fn ->
      Hireme.Corpus.create_profile!(%{slug: "x", name: "X", headline: "h", summary: "s"})
    end
  end

  test "the account comes from the process, never from the attributes" do
    other = Hireme.Accounts.create!(%{name: "Other desk"})

    profile =
      Hireme.Corpus.create_profile!(%{
        slug: "p",
        name: "P",
        headline: "h",
        summary: "s",
        account_id: other.id
      })

    assert profile.account_id == Repo.account_id!()
  end
end
