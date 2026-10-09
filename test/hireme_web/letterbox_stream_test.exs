defmodule HiremeWeb.LetterboxStreamTest do
  use Hireme.DataCase, async: false
  import Hireme.Fixtures

  alias Hireme.ApiKeys
  alias Hireme.Desk.Job
  alias Hireme.Letterbox
  alias HiremeWeb.LetterboxStream
  alias HiremeWeb.Packet

  # The session a lane belongs to is this test process: it hears every
  # byte the lane writes and every close.
  defp open(agent, opts \\ []) do
    me = self()

    {:ok, pid} =
      LetterboxStream.open(
        agent,
        fn bytes -> send(me, {:out, self(), IO.iodata_to_binary(bytes)}) end,
        fn reason -> send(me, {:closed, self(), reason}) end,
        opts
      )

    pid
  end

  defp lease(job_id), do: IO.iodata_to_binary(Packet.frame(:lease, 0, <<job_id::little-64>>))

  # An op as the wire carries it; kinds are the schema's numbers. Op ids
  # are the account's ledger keys, so each test run takes fresh ones.
  defp op(n, kind, target, fields) do
    op_id = Process.get(:op_base, 0) + n
    n = %{stage: 1, next: 2, score: 4, open_fire: 7}[kind]
    body = for f <- fields, into: <<>>, do: <<byte_size(f)::little-16, f::binary>>

    IO.iodata_to_binary(
      Packet.frame(
        :op,
        0,
        <<op_id::little-64, n, length(fields), 0::16, target::little-32, body::binary>>
      )
    )
  end

  # Feed bytes cut at seeded random points: framing must not depend on
  # how the carrier chunks the lane.
  defp feed(pid, bytes, seed) do
    :rand.seed(:exsss, {seed, seed, seed})
    chunks(bytes) |> Enum.each(&LetterboxStream.data(pid, &1))
  end

  defp chunks(<<>>), do: []

  defp chunks(bytes) do
    n = min(byte_size(bytes), :rand.uniform(40))
    <<head::binary-size(n), rest::binary>> = bytes
    [head | chunks(rest)]
  end

  # The next `n` answers the lane wrote: {:ack, op_id, rev} or {:nack, op_id, message}.
  defp answers(pid, n), do: answers(pid, n, <<>>, [])

  defp answers(_pid, 0, <<>>, acc), do: Enum.reverse(acc)

  defp answers(pid, n, buf, acc) do
    case Packet.split(buf) do
      {:ok, [_ | _] = frames, rest} ->
        got =
          Enum.map(frames, fn
            {:ack, _, rev, <<op_id::little-64, _::binary>>} ->
              {:ack, op_id, rev}

            {:nack, _, _,
             <<op_id::little-64, _code, 0, len::little-16, msg::binary-size(len), _::binary>>} ->
              {:nack, op_id, msg}
          end)

        answers(pid, n - length(got), rest, Enum.reverse(got, acc))

      _ ->
        assert_receive {:out, ^pid, bytes}, 2000
        answers(pid, n, buf <> bytes, acc)
    end
  end

  defp agent do
    {:ok, %{secret: secret}} = ApiKeys.create("streams")
    {:ok, agent} = LetterboxStream.agent_key(secret, "198.51.100.7")
    agent
  end

  defp gone(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2000
  end

  test "one key holds parallel leases; each writes only its own job, and closing one releases it" do
    agent = agent()
    Process.put(:op_base, uniq() * 1000)
    a = job(profile(), %{company: "Alpha #{uniq()}"})
    b = job(profile(), %{company: "Beta #{uniq()}"})

    for seed <- 1..3 do
      la = open(agent)
      lb = open(agent, lane: 7)

      Process.put(:op_base, uniq() * 1000)
      feed(la, lease(a.id) <> op(1, :next, a.id, ["call #{seed}", ""]), seed)
      feed(lb, lease(b.id) <> op(2, :score, b.id, ["#{40 + seed}"]), seed + 100)

      base = Process.get(:op_base)
      assert [{:ack, 0, 0}, {:ack, op_a, rev}] = answers(la, 2)
      assert op_a == base + 1 and rev > 0
      # A lane on the session's own channel answers with its number.
      assert [{:ack, 0, 7}, {:ack, _, 7}] = answers(lb, 2)

      assert Repo.get!(Job, a.id).next_action == "call #{seed}"
      assert Repo.get!(Job, b.id).score_100 == 40 + seed

      # A lease writes its own job and nothing else, and no desk-wide ops.
      feed(la, op(3, :score, b.id, ["1"]) <> op(4, :open_fire, 0, ["B-1"]), seed)
      assert [{:nack, refused_a, _}, {:nack, refused_b, _}] = answers(la, 2)
      assert {refused_a, refused_b} == {base + 3, base + 4}
      assert Repo.get!(Job, b.id).score_100 == 40 + seed

      assert MapSet.subset?(MapSet.new([a.id, b.id]), Letterbox.leased_jobs())
      LetterboxStream.fin(la)
      gone(la)
      refute MapSet.member?(Letterbox.leased_jobs(), a.id)
      assert MapSet.member?(Letterbox.leased_jobs(), b.id)
      LetterboxStream.fin(lb)
      gone(lb)
    end
  end

  test "a held job, or one on a held lineage, is refused and the lane closes" do
    agent = agent()
    job = job(profile(), %{company: "Gamma"})
    sibling = job(profile(), %{company: "Gamma"})
    first = open(agent)
    feed(first, lease(job.id), 1)
    assert [{:ack, 0, 0}] = answers(first, 1)

    for {target, reason} <- [{job.id, :busy}, {sibling.id, :lineage_busy}] do
      second = open(agent)
      feed(second, lease(target), 2)
      assert [{:nack, 0, _}] = answers(second, 1)
      assert_receive {:closed, ^second, ^reason}
      gone(second)
    end

    assert MapSet.member?(Letterbox.leased_jobs(), job.id)
  end

  test "an op before the lease, an unknown job, or another account's job closes the lane" do
    agent = agent()
    theirs = job(profile(), %{company: "Foreign"})

    early = open(agent)
    feed(early, op(1, :stage, theirs.id, ["gated"]), 1)
    assert_receive {:closed, ^early, :protocol}

    missing = open(agent)
    feed(missing, lease(2_000_000_000), 1)
    assert [{:nack, 0, _}] = answers(missing, 1)
    assert_receive {:closed, ^missing, :not_found}

    other = open_account("Other desk")
    stranger = open(%{agent | account_id: other.id, key_id: nil})
    feed(stranger, lease(theirs.id), 1)
    assert [{:nack, 0, _}] = answers(stranger, 1)
    assert_receive {:closed, ^stranger, :not_found}
  end

  test "revoking the key closes its lanes and frees their leases" do
    {:ok, %{key: key, secret: secret}} = ApiKeys.create("revoked")
    {:ok, agent} = LetterboxStream.agent_key(secret, "198.51.100.8")
    job = job(profile(), %{company: "Epsilon"})
    lane = open(agent)
    feed(lane, lease(job.id), 1)
    assert [{:ack, 0, 0}] = answers(lane, 1)

    ApiKeys.revoke(key)
    assert_receive {:closed, ^lane, :revoked}, 2000
    gone(lane)
    refute MapSet.member?(Letterbox.leased_jobs(), job.id)
  end

  test "the session's death ends its lanes and their leases" do
    account_id = Repo.account_id!()
    job = job(profile(), %{company: "Zeta"})
    me = self()

    session =
      spawn(fn ->
        Repo.put_account(account_id)

        {:ok, pid} =
          LetterboxStream.open(%{account_id: account_id}, &send(me, {:bytes, &1}), fn _ -> :ok end)

        LetterboxStream.data(pid, lease(job.id))
        send(me, {:lane, pid})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:lane, lane}
    assert_receive {:bytes, _}, 2000
    assert MapSet.member?(Letterbox.leased_jobs(), job.id)
    send(session, :stop)
    gone(lane)
    refute MapSet.member?(Letterbox.leased_jobs(), job.id)
  end
end
