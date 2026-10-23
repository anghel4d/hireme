defmodule HiremeWeb.SessionTest do
  # The test process hosts the session, as the /wire handler or a gate
  # connection does: frames in through frame/2, every message through info/2.
  use Hireme.WireCase, async: false

  import Ecto.Query
  alias Hireme.Keys
  alias HiremeWeb.Session

  @peer %{peer_ip: "127.0.0.1", origin: nil, carrier: :ws}

  defp open(peer \\ @peer), do: elem(Session.open(peer), 1)

  defp hello(secret, peer \\ @peer),
    do: Session.frame(Codec.encode_hello(:key, secret, "x"), open(peer))

  defp browser(s, snapshot \\ 0, schema_rev \\ 0) do
    hello = Codec.encode_hello(:ticket, Hireme.Accounts.ticket(s), "b", snapshot, schema_rev)
    Session.frame(hello, open(%{@peer | origin: hd(HiremeWeb.Endpoint.origins())}))
  end

  defp decode(frame) do
    {:ok, kind, flags, rev, body} = Codec.decode(frame)
    %{kind: kind, flags: flags, rev: rev, body: body}
  end

  # Feeds the session whatever its subscriptions send until it stops: `{reason, frames}`.
  defp stopped(state) do
    receive do
      msg ->
        case Session.info(msg, state) do
          {:stop, reason, frames, _} -> {reason, Enum.map(frames, &decode/1)}
          {:push, _, state} -> stopped(state)
          {:ok, state} -> stopped(state)
        end
    after
      2_000 -> flunk("the session did not stop")
    end
  end

  # A key and its secret, and a session of it past its HELLO.
  defp keyed(s) do
    {:ok, %{key: key, secret: secret}} = Keys.mint(s, "agent", Keys.preset(:read_write))
    {:push, frames, state} = hello(secret)
    {key, secret, frames, state}
  end

  defp reply(state, method, params) do
    {:push, [frame], _} = Session.frame(Codec.encode_rpc(1, method, JSON.encode!(params)), state)

    <<1::little-32, ok, 0::24, n::little-32, json::binary-size(n), _::binary>> =
      decode(frame).body

    {ok, JSON.decode!(json)}
  end

  test "a key's HELLO, taken or refused, is audited with the peer's address and user agent",
       %{session: s, account: a} do
    {:ok, %{key: key, secret: rw}} = Keys.mint(s, "agent", Keys.preset(:read_write))
    peer = %{@peer | peer_ip: "198.51.100.9"} |> Map.put(:user_agent, "agent-under-test/1.0")
    {:push, _, _} = hello(rw, peer)
    {:stop, _, _, _} = hello("hm_nope", peer)
    kinds = ["wire_key", "wire_key_refused"]
    fields = [:kind, :key_id, :account_id, :ip, :user_agent]

    q =
      from(r in Hireme.Rows.Audit,
        where: r.kind in ^kinds,
        order_by: r.id,
        select: map(r, ^fields)
      )

    ua = "agent-under-test/1.0"

    assert [
             %{
               kind: "wire_key",
               key_id: kid,
               account_id: aid,
               ip: "198.51.100.9",
               user_agent: ^ua
             },
             %{kind: "wire_key_refused", key_id: nil, ip: "198.51.100.9", user_agent: ^ua}
           ] = Repo.all(q, skip_account: true)

    assert {kid, aid} == {key.id, a.id}
  end

  test "an exception while handling a HELLO ends the session and logs neither the frame nor the key",
       %{session: s} do
    {:ok, %{secret: rw}} = Keys.mint(s, "agent", Keys.preset(:read_write))

    Repo.query!(
      "CREATE TRIGGER boom BEFORE INSERT ON audit WHEN NEW.kind = 'wire_key' BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END",
      [],
      skip_account: true
    )

    log = ExUnit.CaptureLog.capture_log(fn -> assert {:stop, :internal, [], _} = hello(rw) end)
    [_, public, secret_part] = Regex.run(~r/^hm_([^_]+)_(.+)$/, rw)
    refute log =~ secret_part or log =~ public
  end

  test "a refused HELLO says why: BYE revoked for a bad credential or a foreign origin, BYE restart for one past its address's failures, while a valid key from it is welcomed; a frame before HELLO is a protocol error",
       %{session: s} do
    assert {:stop, {:protocol, :hello_first}, [], _} = Session.frame(Codec.ping(:PING, 1), open())
    assert {:stop, {:bye, :revoked}, [bye], _} = hello("hm_nope")
    assert decode(bye).kind == :BYE
    ticket = Codec.encode_hello(:ticket, Hireme.Accounts.ticket(s), "x")
    evil = open(%{@peer | origin: "https://evil.example"})
    assert {:stop, {:bye, :revoked}, _, _} = Session.frame(ticket, evil)
    {:ok, %{secret: rw}} = Keys.mint(s, "agent", Keys.preset(:read_write))
    :ets.delete_all_objects(Hireme.RateLimit)
    # The limiter's window is a fixed wall-clock minute: start with seconds
    # to spare, so the HELLOs that fill it and the one after share it.
    ms = rem(System.system_time(:millisecond), 60_000)
    if ms > 50_000, do: Process.sleep(60_000 - ms + 100)

    bad = fn ->
      {:stop, {:bye, reason}, _, _} = hello("hm_nope")
      reason
    end

    assert Enum.any?(1..200, fn _ -> bad.() == :restart end)
    assert {:push, _, %{phase: :live}} = hello(rw)
  end

  test "a browser's ticket makes the operator's session, holding the channel; a snapshot at the current rev resumes with a PATCH flagged END, one under another schema_rev gets a BOOT",
       %{session: s, account: a} do
    ack!(a.id, op(:put, :items, %{kind: :skill, key: "s", title: "s"}))
    {:push, [welcome, boot], _} = browser(s)
    welcome = decode(welcome)

    <<_::binary-8, sid::little-64, _::binary-8, r::little-16, w::little-16, d, lease, _::binary>> =
      welcome.body

    assert {sid, r, w, d, lease} == {s.id, 15, 15, 1, 1}
    assert decode(boot).kind == :BOOT
    {:push, [_, resumed], _} = browser(s, welcome.rev, Hireme.Schema.schema_rev())
    assert %{kind: :PATCH, flags: flags} = decode(resumed)
    assert Bitwise.band(flags, 2) == 2
    {:push, [_, train], _} = browser(s, welcome.rev, Hireme.Schema.schema_rev() + 1)
    assert decode(train).kind == :BOOT
  end

  test "only a factor change re-checks a browser's session at once; other audited events cost it nothing",
       %{session: s} do
    {:push, _, state} = browser(s)
    # The session row lapses without a broadcast: only a re-check would see it.
    revoked = DateTime.utc_now() |> DateTime.truncate(:second)
    Repo.update!(Ecto.Changeset.change(s, revoked_at: revoked), skip_account: true)
    assert {:ok, _} = Session.info({Hireme.Audit, :changed}, state)
    assert {:stop, {:bye, :revoked}, _, _} = Session.info({Hireme.Audit, :factors}, state)
  end

  test "each tick re-checks the key: one that expired mid-connection ends the session with BYE revoked",
       %{session: s} do
    {key, _, _, state} = keyed(s)
    assert {:push, [tick], state} = Session.info({Session, :tick}, state)
    assert decode(tick).kind == :TICK
    expired = DateTime.add(DateTime.utc_now(), -60) |> DateTime.truncate(:second)
    Repo.update!(Ecto.Changeset.change(key, expires_at: expired), skip_account: true)
    assert {:stop, {:bye, :revoked}, [bye], _} = Session.info({Session, :tick}, state)
    assert <<0, 0::56, _::binary>> = decode(bye).body
  end

  test "a key's OPS flagged ATOMIC gather until the frame also flagged END and land as one transaction: one refused op writes none; WELCOME says the node takes them" do
    {_, _, frames, state} = keyed(sign_in().session)
    welcome = frames |> Enum.map(&decode/1) |> Enum.find(&(&1.kind == :WELCOME))
    assert <<_::binary-30, 1::little-16, _::binary>> = welcome.body
    # As over /mcp, an atomic burst needs a bulk contract that covers it.
    assert {1, %{"bulk" => %{"writes" => 10}}} = reply(state, "lease.claim", %{"bulk" => 10})

    # One op per frame, flagged by hand: 0x04 ATOMIC, 0x02 END.
    sent = fn op, flags, state ->
      <<head::binary-5, _::8, rest::binary>> =
        Codec.frame(:OPS, 0, [<<1::little-32, 0::32>>, op.raw])

      Session.frame(<<head::binary, flags::8, rest::binary>>, state)
    end

    corp = &op(:put, :corporations, %{domain: &1, name: &1})
    missing = op(:put, :corporations, %{name: "nowhere"}, target: 999_999)
    landed = &Repo.aggregate(from(c in Hireme.Rows.Corporation, where: c.domain in ^&1), :count)
    {:ok, state} = sent.(corp.("burst-a.example"), 0x04, state)
    refute_receive {:sequencer, :verdicts, _, _, _}, 100
    {:ok, state} = sent.(missing, 0x06, state)
    assert_receive {:sequencer, :verdicts, _, [], nacks}
    assert Enum.map(nacks, &Hireme.Schema.refusal_name(&1.code)) == [:burst, :not_found]
    assert landed.(["burst-a.example"]) == 0
    {:ok, state} = sent.(corp.("burst-b.example"), 0x04, state)
    {:ok, _state} = sent.(corp.("burst-c.example"), 0x06, state)
    assert_receive {:sequencer, :verdicts, _, [_, _], []}
    assert landed.(["burst-b.example", "burst-c.example"]) == 2
  end

  test "malformed lease.claim params are refused type and the sequencer lives; a dead sequencer is BYE restart",
       %{session: s, account: a} do
    {_, _, _, state} = keyed(s)
    [{pid, _}] = Registry.lookup(Hireme.Sequencer.Registry, a.id)

    for params <- [
          %{"stage" => 3},
          %{"stage" => false},
          %{"ids" => %{}},
          %{"count" => -1},
          %{"nope" => 1}
        ],
        do: assert({0, %{"code" => "type"}} = reply(state, "lease.claim", params))

    assert Process.alive?(pid)
    Process.exit(pid, :kill)
    assert {{:bye, :restart}, [%{kind: :BYE, body: <<code, 0::56, _::binary>>}]} = stopped(state)
    assert code == Codec.enum_code("bye", :restart)
  end
end
