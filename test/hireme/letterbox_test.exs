defmodule Hireme.LetterboxTest do
  use Hireme.DataCase, async: false
  import Hireme.Fixtures

  alias Hireme.Desk
  alias Hireme.Letterbox

  # Another agent's session: a process of the same account.
  defp elsewhere(fun) do
    account_id = Repo.account_id!()

    Task.async(fn ->
      Repo.put_account(account_id)
      fun.()
    end)
    |> Task.await()
  end

  defp jobs(n) do
    profile = profile()
    for i <- 1..n, do: job(profile, %{company: "Co #{i}"})
  end

  test "blocks are contiguous, exclusive and all or nothing" do
    jobs = jobs(10)
    ids = Enum.map(jobs, & &1.id)

    assert {:ok, %{from: 1, to: 4, jobs: first}, []} = Letterbox.acquire({:count, 4})
    assert first == Enum.take(ids, 4)

    # The next agent asking for a size gets the next free run.
    assert {{:ok, %{from: 5, to: 8}, []}, other} = hold_lease({:count, 4})

    # A range over held entries is refused whole, naming them and a free block.
    assert {:error, %{code: :busy, held: [3, 4], free: {9, 10}, n: 10}} =
             elsewhere(fn -> Letterbox.acquire({:range, 3, 4}) end)

    refute MapSet.member?(Letterbox.leased_jobs(), Enum.at(ids, 8))
    let_go(other)
  end

  test "agents racing for the same free run never both win it" do
    jobs(16)
    account_id = Repo.account_id!()
    parent = self()

    racers =
      for _ <- 1..8 do
        Task.async(fn ->
          Repo.put_account(account_id)
          receive do: (:go -> send(parent, {self(), Letterbox.acquire({:count, 4})}))
          receive do: (:done -> :ok)
        end)
      end

    Enum.each(racers, &send(&1.pid, :go))
    answers = for %{pid: pid} <- racers, do: receive(do: ({^pid, answer} -> {pid, answer}))
    wins = for {pid, {:ok, block, _}} <- answers, do: {pid, block.jobs}
    claimed = Enum.flat_map(wins, &elem(&1, 1))

    assert wins != []
    assert length(claimed) == length(Enum.uniq(claimed))

    for {pid, jobs} <- wins,
        job <- jobs,
        do: assert([{^pid, _}] = Registry.lookup(Hireme.Letterbox.Registry, {:job, job}))

    for {_pid, answer} <- answers,
        do: assert(match?({:ok, _, _}, answer) or match?({:error, %{code: :busy}}, answer))

    Enum.each(racers, &send(&1.pid, :done))
    Enum.each(racers, &Task.await/1)
  end

  test "a range past the desk is clamped with a warning; one wholly outside is empty" do
    jobs(5)

    assert {:ok, %{from: 1, to: 5}, [%{code: :count_capped, asked: 99, n: 5}]} =
             elsewhere(fn -> Letterbox.acquire({:count, 99}) end)

    assert {:ok, %{from: 4, to: 5}, [%{code: :truncated, asked: {4, 40}, n: 5}]} =
             Letterbox.acquire({:range, 40, 4})

    assert {:error, %{code: :empty, asked: {6, 9}, n: 5}} =
             elsewhere(fn -> Letterbox.acquire({:range, 6, 9}) end)
  end

  test "a block's writes: its own applications only, and one agent per employer CV" do
    profile = profile()
    a = job(profile, %{company: "Shared Co"})
    b = job(profile, %{company: "Other Co"})
    c = job(profile, %{company: "Shared Co"})

    {:ok, mine, []} = Letterbox.acquire({:range, 1, 2})
    assert Letterbox.permit(mine, %{kind: :next, target: a.id}) == :ok
    assert Letterbox.permit(mine, %{kind: :gym_target, target: 0}) == :ok
    assert {:error, {:leased, _}} = Letterbox.permit(mine, %{kind: :score, target: c.id})
    assert {:error, {:leased, _}} = Letterbox.permit(nil, %{kind: :stage, target: a.id})

    # A CV write claims the employer's lineage for this block…
    assert Letterbox.permit(mine, %{kind: :overlay, target: a.id}) == :ok

    # …so another agent's CV write for the same employer waits for it.
    assert {:error, :lineage_busy} =
             elsewhere(fn ->
               {:ok, theirs, []} = Letterbox.acquire({:range, 3, 3})
               Letterbox.permit(theirs, %{kind: :overlay, target: c.id})
             end)

    assert Letterbox.release(mine) == :ok
    refute MapSet.member?(Letterbox.leased_jobs(), a.id)
    assert Letterbox.permit(nil, %{kind: :narrative, target: b.id}) == :ok
  end

  test "the desk refuses a write while another process holds the lease" do
    job = job(profile(), %{company: "Held Co"})
    {{:ok, _block, _}, holder} = hold_lease(job.id)
    assert {:error, :leased} = Desk.set_stage(job.id, :freshness)
    let_go(holder)
    assert {:ok, moved} = Desk.set_stage(job.id, :freshness)
    assert moved.current_stage == :freshness
  end
end
