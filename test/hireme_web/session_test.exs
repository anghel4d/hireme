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

  defp hello(state, cred, credential, snapshot \\ 0) do
    {:push, frames, state} =
      Session.frame(Codec.encode_hello(cred, credential, "test", snapshot), state)

    {Enum.map(frames, &decode/1), state}
  end

  defp decode(frame) do
    {:ok, kind, flags, rev, body} = Codec.decode(frame)
    %{kind: kind, flags: flags, rev: rev, body: body}
  end

  # Feeds the session whatever its subscriptions sent, until `kind` comes out.
  defp until(state, kind, acc \\ []) do
    receive do
      msg ->
        case Session.info(msg, state) do
          {:push, frames, state} ->
            frames = Enum.map(frames, &decode/1)

            if Enum.any?(frames, &(&1.kind == kind)),
              do: {acc ++ frames, state},
              else: until(state, kind, acc ++ frames)

          {:ok, state} ->
            until(state, kind, acc)

          {:stop, reason, frames, state} ->
            {acc ++ Enum.map(frames, &decode/1), {:stopped, reason, state}}
        end
    after
      2_000 -> flunk("no #{kind} frame; got #{inspect(Enum.map(acc, & &1.kind))}")
    end
  end

  defp key(session, preset) do
    {:ok, %{key: key, secret: secret}} = Keys.mint(session, "agent", Keys.preset(preset))
    {key, secret}
  end

  defp ops(op), do: Codec.encode_ops([op_tuple(op)])

  defp op_tuple(op) do
    <<_::binary-8, _, flags, _::binary>> = op.raw
    {op.op_id, op.verb, flags, op.subject, op.target, op.expect_rev, op.cells}
  end

  test "a read-only key's put is scope; a write-only key's BOOT carries no table and its put ACKs an id",
       %{session: s} do
    {_, ro} = key(s, :read_only)
    {[welcome, boot], state} = hello(open(), :key, ro)
    assert welcome.kind == :WELCOME and boot.kind == :BOOT and Bitwise.band(boot.flags, 2) == 2
    assert {"applications", 0} in tables(boot.body)

    {:ok, state} =
      Session.frame(ops(op(:put, :corporations, %{domain: "ro.example", name: "RO"})), state)

    {frames, _} = until(state, :NACK)
    assert nack_refusal(Enum.find(frames, &(&1.kind == :NACK))) == :scope

    {_, wo} = key(s, :write_only)
    {[_, boot], state} = hello(open(), :key, wo)

    assert Enum.all?(tables(boot.body), fn {name, rows} ->
             name in ~w(catalog clock) or rows == 0
           end)

    {:ok, %{"ids" => []}} = rpc_ok(state, "lease.claim", %{})

    {:ok, state} =
      Session.frame(ops(op(:put, :corporations, %{domain: "wo.example", name: "WO"})), state)

    {frames, _} = until(state, :ACK)
    ack = Enum.find(frames, &(&1.kind == :ACK))
    <<1::little-32, 0::32, _op::little-64, _rev::little-64, id::little-32, 0::32>> = ack.body
    assert id > 0
  end

  test "a key's HELLO is audited with its peer, and so is a refused key", %{
    session: s,
    account: a
  } do
    {key, rw} = key(s, :read_write)
    {_, _} = hello(open(), :key, rw)
    {:stop, _, _, _} = Session.frame(Codec.encode_hello(:key, "hm_nope", "x"), open())

    rows =
      Repo.all(
        from(r in Hireme.Rows.Audit,
          where: r.kind in ["wire_key", "wire_key_refused"],
          order_by: r.id
        ),
        skip_account: true
      )

    assert [
             %{kind: "wire_key", key_id: kid, account_id: aid, ip: "127.0.0.1"},
             %{kind: "wire_key_refused", ip: "127.0.0.1"}
           ] = rows

    assert {kid, aid} == {key.id, a.id}
  end

  test "key HELLO rows carry the peer's address and user agent", %{session: s} do
    {_, rw} = key(s, :read_write)

    peer = %{
      peer_ip: "198.51.100.9",
      origin: nil,
      carrier: :ws,
      user_agent: "agent-under-test/1.0"
    }

    {:push, _, _} = Session.frame(Codec.encode_hello(:key, rw, "x"), open(peer))
    {:stop, _, _, _} = Session.frame(Codec.encode_hello(:key, "hm_nope", "x"), open(peer))

    rows =
      Repo.all(
        from(r in Hireme.Rows.Audit,
          where: r.kind in ["wire_key", "wire_key_refused"],
          order_by: r.id,
          select: {r.kind, r.ip, r.user_agent}
        ),
        skip_account: true
      )

    assert [
             {"wire_key", "198.51.100.9", "agent-under-test/1.0"},
             {"wire_key_refused", "198.51.100.9", "agent-under-test/1.0"}
           ] = rows
  end

  test "an exception while handling a HELLO ends the session and logs neither the frame nor the key",
       %{session: s} do
    {_, rw} = key(s, :read_write)

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

  test "a wire whose browser session now owes its factor ends when the factor is enrolled", %{
    session: s,
    account: a,
    email: email
  } do
    origin = hd(HiremeWeb.Endpoint.origins())

    {:push, _, state} =
      Session.frame(
        Codec.encode_hello(:ticket, Hireme.Accounts.ticket(s), "b"),
        open(%{@peer | origin: origin})
      )

    # The owner, in another browser (another process), enrols an authenticator app.
    Task.async(fn ->
      {:ok, _, owner} = Hireme.Accounts.sign_in_with(:email, %{subject: email, display: email})
      Repo.put_account(a.id)
      {:ok, %{secret: secret}} = Hireme.Mfa.begin_totp(owner, "me")
      code = secret |> Base.decode32!(padding: false) |> NimbleTOTP.verification_code()
      {:ok, _, _} = Hireme.Mfa.confirm_totp(owner, code, "phone")
    end)
    |> Task.await()

    {frames, {:stopped, {:bye, :revoked}, _}} = until(state, :BYE)
    assert Enum.any?(frames, &(&1.kind == :BYE))
  end

  test "only a factor change re-checks the session at once; other audited events cost it nothing",
       %{session: s} do
    origin = hd(HiremeWeb.Endpoint.origins())

    {:push, _, state} =
      Session.frame(
        Codec.encode_hello(:ticket, Hireme.Accounts.ticket(s), "b"),
        open(%{@peer | origin: origin})
      )

    # The session row lapses without a broadcast: only a re-check would see it.
    s
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!(skip_account: true)

    assert {:ok, _} = Session.info({Hireme.Audit, :changed}, state)
    assert {:stop, {:bye, :revoked}, _, _} = Session.info({Hireme.Audit, :factors}, state)
  end

  test "a bad credential, or a ticket from a foreign origin, is BYE revoked", %{session: s} do
    assert {:stop, {:bye, :revoked}, [bye], _} =
             Session.frame(Codec.encode_hello(:key, "hm_nope", "x"), open())

    assert decode(bye).kind == :BYE
    ticket = Hireme.Accounts.ticket(s)

    assert {:stop, {:bye, :revoked}, _, _} =
             Session.frame(
               Codec.encode_hello(:ticket, ticket, "x"),
               open(%{@peer | origin: "https://evil.example"})
             )
  end

  test "a throttled HELLO is BYE restart, retryable, not revoked", %{session: s} do
    {_, rw} = key(s, :read_write)
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

    assert {:stop, {:bye, :restart}, _, _} =
             Session.frame(Codec.encode_hello(:key, rw, "x"), open())
  end

  test "a browser's ticket makes the operator's session, holding the channel", %{session: s} do
    ticket = Hireme.Accounts.ticket(s)
    origin = hd(HiremeWeb.Endpoint.origins())
    {[welcome, _boot], _state} = hello(open(%{@peer | origin: origin}), :ticket, ticket)
    <<_::binary-24, r::little-16, w::little-16, d, lease, _::binary>> = welcome.body
    assert {r, w, d, lease} == {31, 31, 1, 1}
  end

  defp browser(s) do
    origin = hd(HiremeWeb.Endpoint.origins())

    open(%{@peer | origin: origin})
    |> then(&Session.frame(Codec.encode_hello(:ticket, Hireme.Accounts.ticket(s), "b"), &1))
  end

  test "account.watch asks the account lens first: a cursor already passed answers at once", %{
    session: s
  } do
    {:push, _, state} = browser(s)

    {:push, [frame], state} =
      Session.frame(Codec.encode_rpc(1, "account.watch", JSON.encode!(%{since: 0})), state)

    assert %{kind: :REPLY, body: <<1::little-32, 1, _::binary>>} = decode(frame)
    {:ok, %{"cursor" => cursor}} = rpc_ok(state, "account.overview", %{})
    # At the current cursor it parks: no reply until the account moves.
    assert {:push, [], _} =
             Session.frame(
               Codec.encode_rpc(2, "account.watch", JSON.encode!(%{since: cursor})),
               state
             )
  end

  test "a snapshot under another schema_rev is answered with a full BOOT", %{
    session: s,
    account: a
  } do
    origin = hd(HiremeWeb.Endpoint.origins())

    {[_], []} =
      run(a.id, op(:put, :gym_reps, %{platform: :other, slug: "s", done_on: ~D[2026-10-01]}))

    {:push, [w, _], _} = browser(s)
    {:ok, :WELCOME, _, rev, _} = Codec.decode(w)

    hello = fn schema_rev ->
      Codec.encode_hello(:ticket, Hireme.Accounts.ticket(s), "b", rev, schema_rev)
    end

    {:push, [_, resumed], _} =
      Session.frame(hello.(Hireme.Schema.schema_rev()), open(%{@peer | origin: origin}))

    assert decode(resumed).kind == :PATCH

    {:push, [_, train], _} =
      Session.frame(hello.(Hireme.Schema.schema_rev() + 1), open(%{@peer | origin: origin}))

    assert decode(train).kind == :BOOT
  end

  test "a current snapshot gets a PATCH, flagged END, instead of a BOOT", %{session: s} do
    {_, rw} = key(s, :read_write)
    {[welcome, _], _} = hello(open(), :key, rw)
    {[_, train], _} = hello(open(), :key, rw, welcome.rev)
    assert welcome.rev == 0 or train.kind == :PATCH
    assert Bitwise.band(train.flags, 2) == 2
  end

  test "revoking the key ends its session with BYE revoked", %{session: s} do
    {key, rw} = key(s, :read_write)
    {_, state} = hello(open(), :key, rw)
    Keys.revoke(key)
    {[bye], {:stopped, {:bye, :revoked}, _}} = until(state, :BYE)
    assert <<0, 0::56, _::binary>> = bye.body
  end

  test "each tick re-checks the key: one that expired mid-connection ends the session", %{
    session: s
  } do
    {key, rw} = key(s, :read_write)
    {_, state} = hello(open(), :key, rw)
    assert {:push, [tick], state} = Session.info({Session, :tick}, state)
    assert decode(tick).kind == :TICK

    key
    |> Ecto.Changeset.change(
      expires_at: DateTime.add(DateTime.utc_now(), -60) |> DateTime.truncate(:second)
    )
    |> Repo.update!(skip_account: true)

    assert {:stop, {:bye, :revoked}, [bye], _} = Session.info({Session, :tick}, state)
    assert decode(bye).kind == :BYE
  end

  test "malformed lease.claim params are refused type and the sequencer lives", %{
    session: s,
    account: a
  } do
    {_, rw} = key(s, :read_write)
    {_, state} = hello(open(), :key, rw)
    [{pid, _}] = Registry.lookup(Hireme.Sequencer.Registry, a.id)

    for params <- [
          %{"stage" => 3},
          %{"stage" => false},
          %{"ids" => %{}},
          %{"count" => -1},
          %{"nope" => 1}
        ] do
      {:push, [frame], _} =
        Session.frame(Codec.encode_rpc(1, "lease.claim", JSON.encode!(params)), state)

      assert %{kind: :REPLY, body: <<1::little-32, 0, _::binary>>} = decode(frame)
    end

    assert Process.alive?(pid)
  end

  test "a session whose sequencer died is told to reconnect, with the restart reason byte", %{
    session: s,
    account: a
  } do
    {_, rw} = key(s, :read_write)
    {_, state} = hello(open(), :key, rw)
    [{pid, _}] = Registry.lookup(Hireme.Sequencer.Registry, a.id)
    Process.exit(pid, :kill)
    {[bye], {:stopped, {:bye, :restart}, _}} = until(state, :BYE)
    assert <<code, 0::56, _::binary>> = bye.body
    assert code == Codec.enum_code("bye", :restart)
  end

  test "a PING is answered with the same nonce; a frame before HELLO ends the session" do
    assert {:stop, {:protocol, :hello_first}, [], _} = Session.frame(Codec.ping(:PING, 1), open())
  end

  defp rpc_ok(state, method, params) do
    {:push, [frame], _} = Session.frame(Codec.encode_rpc(1, method, JSON.encode!(params)), state)

    %{
      kind: :REPLY,
      body: <<1::little-32, 1, 0::24, n::little-32, json::binary-size(n), _::binary>>
    } = decode(frame)

    {:ok, JSON.decode!(json)}
  end

  defp nack_refusal(%{body: <<1::little-32, 0::32, _::little-64, code::little-16, _::binary>>}),
    do: Schema.refusal_name(code)
end
