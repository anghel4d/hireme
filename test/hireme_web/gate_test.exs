defmodule HiremeWeb.GateTest do
  # The test plays the Rust gate's half of the bridge (HiremeWeb.Gate's
  # moduledoc) against the real listener, with a real Session behind it.
  use Hireme.WireCase, async: false
  use ExUnitProperties

  import Bitwise
  alias Hireme.Keys

  @open 0x01
  @accept 0x02
  @ready 0x04
  @data 0x11
  @uni 0x15
  @close 0x30

  setup %{session: session} do
    dir = Path.join(System.tmp_dir!(), "hireme-gate-#{System.unique_integer([:positive])}")
    socket = Path.join(dir, "gate.sock")
    start_supervised!({HiremeWeb.Gate, socket: socket})
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, %{secret: secret}} = Keys.mint(session, "agent", Keys.preset(:read_write))
    %{socket: socket, secret: secret}
  end

  defp connect(socket, origin \\ "") do
    {:ok, s} = :gen_tcp.connect({:local, socket}, 0, [:binary, packet: 4, active: false], 1_000)
    ip = "127.0.0.1"

    :ok =
      :gen_tcp.send(
        s,
        <<@open, byte_size(ip), ip::binary, byte_size(origin)::16, origin::binary, 3::16, "/wt">>
      )

    assert {:ok, <<@accept>>} = :gen_tcp.recv(s, 0, 1_000)
    s
  end

  defp send_data(s, bytes), do: :ok = :gen_tcp.send(s, [<<@data>>, bytes])

  # Bridge messages until `stop?` holds for one, decoded: {:ready} |
  # {:data, kind} for each whole frame on the control stream | {:uni, kind}
  # | {:close, code}.
  defp recv_until(s, stop?, acc \\ [], buf \\ <<>>) do
    case :gen_tcp.recv(s, 0, 2_000) do
      {:ok, <<@ready>>} ->
        next(s, stop?, acc ++ [{:ready}], buf)

      {:ok, <<@uni, frame::binary>>} ->
        next(s, stop?, acc ++ [{:uni, kind(frame)}], buf)

      {:ok, <<@data, bytes::binary>>} ->
        {frames, rest} = split(buf <> bytes, [])
        next(s, stop?, acc ++ Enum.map(frames, &{:data, kind(&1)}), rest)

      {:ok, <<@close, code::32, _::binary>>} ->
        acc ++ [{:close, code}]

      {:error, reason} ->
        flunk("bridge #{inspect(reason)} after #{inspect(acc)}")
    end
  end

  defp next(s, stop?, acc, buf),
    do: if(Enum.any?(acc, stop?), do: acc, else: recv_until(s, stop?, acc, buf))

  defp split(buf, acc) do
    case Codec.split(buf, 1 <<< 30) do
      {:ok, frame, rest} -> split(rest, acc ++ [frame])
      _ -> {acc, buf}
    end
  end

  # Bridge messages until `n` PONGs have come back; answers how many did.
  defp pongs(s, n, seen \\ 0) do
    got = recv_until(s, &(&1 == {:data, :PONG}))
    seen = seen + Enum.count(got, &(&1 == {:data, :PONG}))
    if seen >= n, do: seen, else: pongs(s, n, seen)
  end

  defp kind(frame) do
    {:ok, kind, _, _, _} = Codec.decode(frame)
    kind
  end

  test "a HELLO over the bridge lifts the gate's caps with WELCOME, and the BOOT leaves on its own uni stream",
       %{socket: socket, secret: secret} do
    s = connect(socket)
    send_data(s, Codec.encode_hello(:key, secret, "probe"))

    got = recv_until(s, &match?({:uni, :BOOT}, &1))
    assert Enum.take(got, 2) == [{:ready}, {:data, :WELCOME}]
    assert {:uni, :BOOT} in got
    refute {:data, :BOOT} in got
  end

  property "frames reach the Session whole however the gate chunks the stream", %{
    socket: socket,
    secret: secret
  } do
    check all(
            nonces <- list_of(integer(1..1_000_000), min_length: 1, max_length: 6),
            cuts <- list_of(integer(1..40), max_length: 30),
            max_runs: 15
          ) do
      s = connect(socket)

      stream =
        IO.iodata_to_binary([
          Codec.encode_hello(:key, secret, "probe") | Enum.map(nonces, &Codec.ping(:PING, &1))
        ])

      {pieces, rest} =
        Enum.reduce(cuts, {[], stream}, fn n, {acc, rest} ->
          n = min(n, byte_size(rest))
          {[binary_part(rest, 0, n) | acc], binary_part(rest, n, byte_size(rest) - n)}
        end)

      for piece <- Enum.reverse([rest | pieces]), piece != "", do: send_data(s, piece)

      assert pongs(s, length(nonces)) == length(nonces)
      :gen_tcp.close(s)
    end
  end

  test "bytes that are not frames close the session with an error code", %{socket: socket} do
    s = connect(socket)
    send_data(s, <<3::little-32, 0::96>>)
    assert [{:close, code}] = recv_until(s, &match?({:close, _}, &1))
    assert code != 0
  end

  test "a bad credential is BYE'd over the control stream and the session closes", %{
    socket: socket
  } do
    s = connect(socket)
    send_data(s, Codec.encode_hello(:key, "hm_nope", "probe"))
    got = recv_until(s, &match?({:close, _}, &1))
    assert {:data, :BYE} in got
    refute {:ready} in got
  end
end
