defmodule HiremeWeb.LetterboxStreamTest do
  use Hireme.DataCase, async: false
  import Hireme.Fixtures

  alias Hireme.ApiKeys
  alias Hireme.Letterbox
  alias HiremeWeb.LetterboxStream
  alias HiremeWeb.Sockets

  # The session a stream belongs to is this test process: it hears every
  # byte the stream writes and every close.
  defp open(agent) do
    me = self()

    {:ok, pid} =
      LetterboxStream.open(
        agent,
        fn bytes -> send(me, {:out, self(), IO.iodata_to_binary(bytes)}) end,
        fn reason -> send(me, {:closed, self(), reason}) end
      )

    pid
  end

  defp lease_frame(id), do: frame(0x20, <<id::64-little>>)

  defp call_frame(id, name, args \\ %{}) do
    json =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: id,
        method: "tools/call",
        params: %{name: name, arguments: args}
      })

    frame(0x21, <<byte_size(json)::32-little, 0::32>> <> json)
  end

  defp frame(kind, body) do
    len = 16 + byte_size(body) + rem(8 - rem(16 + byte_size(body), 8), 8)
    pad = len - 16 - byte_size(body)
    <<len::32-little, kind, 0, 0::16, 0::64>> <> body <> :binary.copy(<<0>>, pad)
  end

  # Feed bytes cut at seeded random points: framing must not depend on
  # how the transport chunks the stream.
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

  # The next `n` JSON-RPC messages the stream wrote, decoded.
  defp messages(pid, n), do: messages(pid, n, <<>>, [])

  defp messages(_pid, 0, <<>>, acc), do: Enum.reverse(acc)

  defp messages(pid, n, <<len::32-little, 0x21, _::binary>> = buf, acc)
       when byte_size(buf) >= len do
    <<frame::binary-size(len), rest::binary>> = buf
    assert rem(len, 8) == 0
    <<_header::binary-16, size::32-little, 0::32, json::binary-size(size), pad::binary>> = frame
    assert pad == :binary.copy(<<0>>, byte_size(pad))
    messages(pid, n - 1, rest, [Jason.decode!(json) | acc])
  end

  defp messages(pid, n, buf, acc) do
    assert_receive {:out, ^pid, bytes}, 2000
    messages(pid, n, buf <> bytes, acc)
  end

  defp opened(company) do
    job = job(profile(), %{company: "#{company} #{uniq()}"})
    %{job: job, letterbox_id: Letterbox.for_job(job.id).id}
  end

  defp agent do
    {:ok, %{secret: secret}} = ApiKeys.create("streams")
    {:ok, agent} = Sockets.agent_key(secret, "198.51.100.7")
    agent
  end

  defp gone(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2000
  end

  test "one key carries parallel leases, and closing a stream releases only its own" do
    agent = agent()
    a = opened("Alpha")
    b = opened("Beta")

    for seed <- 1..3 do
      sa = open(agent)
      sb = open(agent)

      feed(sa, lease_frame(a.letterbox_id) <> call_frame(1, "get_application"), seed)

      feed(
        sb,
        lease_frame(b.letterbox_id) <>
          call_frame(1, "set_next_action", %{"next_action" => "call #{seed}"}),
        seed + 100
      )

      [lease_a, reply_a] = messages(sa, 2)
      [lease_b, reply_b] = messages(sb, 2)

      assert lease_a["method"] == "notifications/lease"
      assert lease_a["params"]["job_id"] == a.job.id
      assert lease_b["params"]["job_id"] == b.job.id
      assert reply_a["id"] == 1 and reply_a["result"]["job_id"] == a.job.id
      assert reply_b["result"] == %{"job_id" => b.job.id, "next_action" => "call #{seed}"}

      # A lease's tools are bound to it: aiming at another job is refused.
      feed(sa, call_frame(2, "set_score", %{"job_id" => b.job.id, "score" => 1}), seed)
      [refused] = messages(sa, 1)
      assert refused["error"]["message"] == "letterbox_mismatch"

      assert MapSet.subset?(MapSet.new([a.job.id, b.job.id]), Letterbox.leased_jobs())

      LetterboxStream.fin(sa)
      gone(sa)
      refute Letterbox.leased?(a.letterbox_id)
      refute MapSet.member?(Letterbox.leased_jobs(), a.job.id)
      assert Letterbox.leased?(b.letterbox_id)

      LetterboxStream.fin(sb)
      gone(sb)
    end
  end

  test "a held letterbox is refused on a second stream, which then closes" do
    agent = agent()
    %{letterbox_id: id} = opened("Gamma")
    first = open(agent)
    feed(first, lease_frame(id), 1)
    [_] = messages(first, 1)

    second = open(agent)
    feed(second, lease_frame(id), 2)
    [refused] = messages(second, 1)
    assert refused["params"] == %{"letterbox_id" => id, "error" => "busy"}
    assert_receive {:closed, ^second, :busy}
    gone(second)
    assert Letterbox.leased?(id)
  end

  test "id 0 opens the read-only directory" do
    %{letterbox_id: id} = opened("Delta")
    dir = open(agent())

    feed(
      dir,
      lease_frame(0) <> call_frame(1, "list_letterboxes") <> call_frame(2, "set_stage"),
      3
    )

    [hello, listed, refused] = messages(dir, 3)
    assert hello["params"]["directory"] == true
    assert Enum.any?(listed["result"]["letterboxes"], &(&1["letterbox_id"] == id))
    assert refused["error"]["message"] == "unleased"
  end

  test "an RPC before the lease, an unknown or another account's letterbox, all close the stream" do
    agent = agent()

    early = open(agent)
    feed(early, call_frame(1, "get_application"), 1)
    assert_receive {:closed, ^early, :protocol}

    missing = open(agent)
    feed(missing, lease_frame(2_000_000_000), 1)
    [refused] = messages(missing, 1)
    assert refused["params"]["error"] == "letterbox"
    assert_receive {:closed, ^missing, :letterbox}

    %{letterbox_id: foreign} = opened("Foreign")
    other = open_account("Other desk")
    stranger = open(%{agent | account_id: other.id, key_id: nil})
    feed(stranger, lease_frame(foreign), 1)
    [hidden] = messages(stranger, 1)
    assert hidden["params"]["error"] == "letterbox"
  end

  test "revoking the key closes its streams and frees their leases" do
    {:ok, %{key: key, secret: secret}} = ApiKeys.create("revoked")
    {:ok, agent} = Sockets.agent_key(secret, "198.51.100.8")
    %{letterbox_id: id} = opened("Epsilon")
    stream = open(agent)
    feed(stream, lease_frame(id), 1)
    [_] = messages(stream, 1)

    ApiKeys.revoke(key)
    assert_receive {:closed, ^stream, :revoked}, 2000
    gone(stream)
    refute Letterbox.leased?(id)
  end

  test "the session's death ends its streams and their leases" do
    account_id = Repo.account_id!()
    %{letterbox_id: id} = opened("Zeta")
    me = self()

    session =
      spawn(fn ->
        Repo.put_account(account_id)

        {:ok, pid} =
          LetterboxStream.open(%{account_id: account_id}, &send(me, {:bytes, &1}), fn _ -> :ok end)

        LetterboxStream.data(pid, lease_frame(id))
        send(me, {:stream, pid})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:stream, stream}
    assert_receive {:bytes, _}, 2000
    assert Letterbox.leased?(id)
    send(session, :stop)
    gone(stream)
    refute Letterbox.leased?(id)
  end
end
