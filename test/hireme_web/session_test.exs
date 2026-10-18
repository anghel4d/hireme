defmodule HiremeWeb.SessionTest do
  # The test process hosts the session, as the /wire handler or a gate
  # connection does: frames in through frame/2, every message through info/2.
  use Hireme.WireCase, async: false

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

    {:ok, %{"ids" => []}} = rpc_ok(state, "lease.claim", %{})

    {:ok, state} =
      Session.frame(ops(op(:put, :corporations, %{domain: "ro.example", name: "RO"})), state)

    {frames, _} = until(state, :NACK)
    assert nack_refusal(Enum.find(frames, &(&1.kind == :NACK))) == :scope

    {_, wo} = key(s, :write_only)
    {[_, boot], state} = hello(open(), :key, wo)
    assert tables(boot.body) |> Enum.map(&elem(&1, 0)) |> Enum.all?(&(&1 in ~w(catalog clock)))
    {:ok, %{"ids" => []}} = rpc_ok(state, "lease.claim", %{})

    {:ok, state} =
      Session.frame(ops(op(:put, :corporations, %{domain: "wo.example", name: "WO"})), state)

    {frames, _} = until(state, :ACK)
    ack = Enum.find(frames, &(&1.kind == :ACK))
    <<1::little-32, 0::32, _op::little-64, _rev::little-64, id::little-32, 0::32>> = ack.body
    assert id > 0
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

    [last | _] =
      for _ <- 1..25 do
        {:stop, {:bye, reason}, _, _} =
          Session.frame(Codec.encode_hello(:key, "hm_nope", "x"), open())

        reason
      end
      |> Enum.reverse()

    assert last == :restart

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
    assert bye.kind == :BYE
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
