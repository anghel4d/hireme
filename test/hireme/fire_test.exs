defmodule Hireme.FireTest do
  # Missions under fire keys on the node: the kernel's verdicts (fire.rs)
  # persisted by the sequencer as they are judged (docs/mail/kernel.md).
  use Hireme.WireCase, async: false

  alias Hireme.Kernel.Nif
  alias Hireme.Rows

  # A key writes under a lease: a subscribed agent session holding the
  # application the shot moves.
  defp agent(account_id, session, app_id) do
    {:ok, %{key: key}} = Hireme.Keys.mint(session, "agent", Hireme.Keys.preset(:read_write))
    {pid, _} = key_session(account_id, key, 950, %{"ids" => [app_id]})
    {pid, key.id}
  end

  # A read of the account's kernel, as the MCP makes one, with every domain.
  defp read(account_id, op, args) do
    req = JSON.encode!(Map.put(args, "op", op))
    {:ok, {:ok, json}} = Hireme.Sequencer.read(account_id, fn k, _ -> Nif.query(k.res, req, 0xFF, 0xFF, true) end)
    JSON.decode!(json)
  end

  test "the operator's key fires a mission once: the shot lands, burns and submits its application, and a second is answered",
       %{account: a, session: s} do
    {[batch], []} = run(a.id, op(:put, :batches, %{code: "B1", ordinal: 1}))
    {[app], []} = run(a.id, app(%{company: "Acme", role: "Staff Engineer", batch_id: batch.id}))
    {[_], []} = run(a.id, op(:command, :stage, %{stage: :fire_ready}, target: app.id))

    {[m], []} =
      run(
        a.id,
        op(:put, :missions, %{
          application_id: app.id,
          kind: :careers_page,
          target: "https://job-boards.greenhouse.io/acme/jobs/1",
          draft: "## Name\nAna",
          state: :fire_ready
        })
      )

    {agent, key_id} = agent(a.id, s, app.id)

    # No key, no shot: the commander's answer, with what a request would carry.
    {[], [nack]} = key_session_ops(agent, op(:command, :fire, %{}, target: m.id))
    assert nack.refusal == :fire
    assert %{"why" => "no_key", "ask" => %{"missions" => ask}} = JSON.decode!(nack.data)
    assert ask == "#{m.id}"

    # The operator makes the key over exactly what the review showed.
    review = read(a.id, "fire_review", %{"missions" => ask})
    assert [%{"eligible" => true, "hash" => hash}] = review["missions"]

    {[_], []} =
      run(a.id, op(:command, :create_fire_key, %{missions: review["scope"], digest: review["digest"], usable_by: key_id}))

    [key] = Repo.all(Rows.FireKey)
    assert {key.scope, key.usable_by, key.first_used_at} == {ask, key_id, nil}
    assert [%Rows.FireShot{mission_id: mid, hash: ^hash, burned_at: nil}] = Repo.all(Rows.FireShot)
    assert mid == m.id

    # The agent fires: in flight, the key's 24 hours started.
    {[_], []} = key_session_ops(agent, op(:command, :fire, %{}, target: m.id))
    assert %Rows.Mission{state: :in_flight, fire_key_id: kid, fired_with: ^key_id} = Repo.get!(Rows.Mission, m.id)
    assert kid == key.id
    used = Repo.get!(Rows.FireKey, key.id)
    assert DateTime.diff(used.expires_at, used.first_used_at) == 86_400

    # It lands: fired and provisional, the shot burned, the application submitted.
    {[_], []} = key_session_ops(agent, op(:command, :landed, %{}, target: m.id))
    assert %Rows.Mission{state: :fired, confirmation: :provisional} = Repo.get!(Rows.Mission, m.id)
    assert %Rows.FireShot{burned_at: %DateTime{}} = Repo.one!(Rows.FireShot)
    assert Repo.get!(Rows.Application, app.id).stage == :submitted

    # Again: already done, with what the key burned.
    {[], [again]} = key_session_ops(agent, op(:command, :fire, %{key: key.id}, target: m.id))
    assert %{"why" => "fired", "key" => k, "burned" => burned} = JSON.decode!(again.data)
    assert {k, burned} == {key.id, "#{m.id}"}

    # A key is the record: no one drops it.
    assert {[], [%{refusal: :scope}]} = run(a.id, op(:drop, :fire_keys, %{}, target: key.id))
  end
end
