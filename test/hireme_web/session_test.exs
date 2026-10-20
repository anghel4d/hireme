defmodule HiremeWeb.SessionTest do
  # The test process hosts the session, as the /wire handler or a gate
  # connection does: frames in through frame/2, every message through info/2.
  use Hireme.WireCase, async: false

  import Ecto.Query
  alias Hireme.Keys
  alias HiremeWeb.Session

  @peer %{peer_ip: "127.0.0.1", origin: nil, carrier: :ws}

  defp open(peer \\ @peer) do
    {:ok, state} = Session.open(peer)
    state
  end

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

  defp key(session, preset \\ :read_write) do
    {:ok, %{key: key, secret: secret}} = Keys.mint(session, "agent", Keys.preset(preset))
    {key, secret}
  end

  # A key's session past its HELLO: `{key, state}`.
  defp keyed(s) do
    {key, secret} = key(s)
    {:push, _, state} = Session.frame(Codec.encode_hello(:key, secret, "test"), open())
    {key, state}
  end

  defp reply(state, method, params) do
    {:push, [frame], _} = Session.frame(Codec.encode_rpc(1, method, JSON.encode!(params)), state)

    %{
      kind: :REPLY,
      body: <<1::little-32, ok, 0::24, n::little-32, json::binary-size(n), _::binary>>
    } = decode(frame)

    {ok, JSON.decode!(json)}
  end

  test "a key's HELLO, taken or refused, is audited with the peer's address and user agent",
       %{session: s, account: a} do
    {key, rw} = key(s)
    peer = %{@peer | peer_ip: "198.51.100.9"} |> Map.put(:user_agent, "agent-under-test/1.0")
    {:push, _, _} = Session.frame(Codec.encode_hello(:key, rw, "x"), open(peer))
    {:stop, _, _, _} = Session.frame(Codec.encode_hello(:key, "hm_nope", "x"), open(peer))

    rows =
      Repo.all(
        from(r in Hireme.Rows.Audit,
          where: r.kind in ["wire_key", "wire_key_refused"],
          order_by: r.id,
          select: {r.kind, r.key_id, r.account_id, r.ip, r.user_agent}
        ),
        skip_account: true
      )

    assert [
             {"wire_key", kid, aid, "198.51.100.9", "agent-under-test/1.0"},
             {"wire_key_refused", nil, _, "198.51.100.9", "agent-under-test/1.0"}
           ] = rows

    assert {kid, aid} == {key.id, a.id}
  end

  test "an exception while handling a HELLO ends the session and logs neither the frame nor the key",
       %{session: s} do
    {_, rw} = key(s)

    Hireme.Repo.query!(
      "CREATE TRIGGER boom BEFORE INSERT ON audit WHEN NEW.kind = 'wire_key' BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END",
      [],
      skip_account: true
    )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:stop, :internal, [], _} =
                 Session.frame(Codec.encode_hello(:key, rw, "x"), open())
      end)

    [_, public, secret_part] = Regex.run(~r/^hm_([^_]+)_(.+)$/, rw)
    refute log =~ secret_part
    refute log =~ public
  end

  test "a refused HELLO says why: BYE revoked for a bad credential or a foreign origin, BYE restart for one past its address's failures, while a valid key from it is welcomed; a frame before HELLO is a protocol error",
       %{session: s} do
    assert {:stop, {:protocol, :hello_first}, [], _} = Session.frame(Codec.ping(:PING, 1), open())

    assert {:stop, {:bye, :revoked}, [bye], _} =
             Session.frame(Codec.encode_hello(:key, "hm_nope", "x"), open())

    assert decode(bye).kind == :BYE
    ticket = Hireme.Accounts.ticket(s)

    assert {:stop, {:bye, :revoked}, _, _} =
             Session.frame(
               Codec.encode_hello(:ticket, ticket, "x"),
               open(%{@peer | origin: "https://evil.example"})
             )

    {_, rw} = key(s)
    :ets.delete_all_objects(Hireme.RateLimit)
    # The limiter's window is a fixed wall-clock minute: start with seconds
    # to spare, so the HELLOs that fill it and the one after share it.
    ms = rem(System.system_time(:millisecond), 60_000)
    if ms > 50_000, do: Process.sleep(60_000 - ms + 100)

    bad = fn ->
      {:stop, {:bye, reason}, _, _} =
        Session.frame(Codec.encode_hello(:key, "hm_nope", "x"), open())

      reason
    end

    assert Enum.any?(1..200, fn _ -> bad.() == :restart end)

    assert {:push, _, %{phase: :live}} = Session.frame(Codec.encode_hello(:key, rw, "x"), open())
  end

  test "a browser's ticket makes the operator's session, holding the channel; a snapshot at the current rev resumes with a PATCH flagged END, one under another schema_rev gets a BOOT",
       %{session: s, account: a} do
    {[_], []} =
      run(a.id, op(:put, :items, %{kind: :skill, key: "s", title: "s"}))

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
    s
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!(skip_account: true)

    assert {:ok, _} = Session.info({Hireme.Audit, :changed}, state)
    assert {:stop, {:bye, :revoked}, _, _} = Session.info({Hireme.Audit, :factors}, state)
  end

  test "each tick re-checks the key: one that expired mid-connection ends the session with BYE revoked",
       %{session: s} do
    {key, state} = keyed(s)
    assert {:push, [tick], state} = Session.info({Session, :tick}, state)
    assert decode(tick).kind == :TICK

    key
    |> Ecto.Changeset.change(
      expires_at: DateTime.add(DateTime.utc_now(), -60) |> DateTime.truncate(:second)
    )
    |> Repo.update!(skip_account: true)

    assert {:stop, {:bye, :revoked}, [bye], _} = Session.info({Session, :tick}, state)
    assert <<0, 0::56, _::binary>> = decode(bye).body
  end

  test "malformed lease.claim params are refused type and the sequencer lives; a dead sequencer is BYE restart",
       %{session: s, account: a} do
    {_, state} = keyed(s)
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
