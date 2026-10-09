defmodule Hireme.LetterboxTest do
  use Hireme.DataCase, async: false
  import Hireme.Fixtures

  alias Hireme.Desk
  alias Hireme.Letterbox

  # Claim in another process of the same account, as another lease would.
  defp elsewhere(fun) do
    account_id = Repo.account_id!()

    Task.async(fn ->
      Repo.put_account(account_id)
      fun.()
    end)
    |> Task.await()
  end

  test "a lease keeps its job and its employer's lineage from every other lease" do
    first = job(profile(), %{company: "North Co"})
    sibling = job(profile(), %{company: "North Co"})
    other = job(profile(), %{company: "South Co"})

    assert {:ok, pair} = Letterbox.claim(first.id)
    assert {:error, :busy} = elsewhere(fn -> Letterbox.claim(first.id) end)
    assert {:error, :lineage_busy} = elsewhere(fn -> Letterbox.claim(sibling.id) end)
    assert {:ok, _} = elsewhere(fn -> Letterbox.claim(other.id) end)
    assert MapSet.member?(Letterbox.leased_jobs(), first.id)

    # A lineage refusal leaves nothing behind.
    refute MapSet.member?(Letterbox.leased_jobs(), sibling.id)

    assert Letterbox.release(pair) == :ok
    refute MapSet.member?(Letterbox.leased_jobs(), first.id)
    assert {:ok, _} = elsewhere(fn -> Letterbox.claim(sibling.id) end)
  end

  test "the desk refuses a write while another process holds the lease" do
    job = job(profile(), %{company: "Held Co"})
    me = self()
    account_id = Repo.account_id!()

    holder =
      spawn_link(fn ->
        Repo.put_account(account_id)
        {:ok, pair} = Letterbox.claim(job.id)
        send(me, :held)

        receive do
          :release -> send(me, Letterbox.release(pair))
        end
      end)

    assert_receive :held
    assert {:error, :leased} = Desk.set_stage(job.id, :freshness)
    send(holder, :release)
    assert_receive :ok
    assert {:ok, moved} = Desk.set_stage(job.id, :freshness)
    assert moved.current_stage == :freshness
  end

  test "another account's job cannot be leased" do
    job = job(profile(), %{company: "Theirs"})
    open_account("Other desk")
    assert {:error, :not_found} = Letterbox.claim(job.id)
    assert {:error, :not_found} = Letterbox.claim(2_000_000_000)
  end
end
