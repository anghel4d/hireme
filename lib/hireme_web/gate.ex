defmodule HiremeWeb.Gate do
  @moduledoc """
  The BEAM end of the WebTransport gate, and the carrier a
  `HiremeWeb.Session` writes through when its peer came in over QUIC.

  `native/gate` (Rust, `wtransport` on quinn) terminates QUIC and HTTP/3
  and holds no business logic. Each WebTransport session becomes one
  connection to the Unix socket this module listens on. The connection's
  process hosts the Session itself: socket bytes are decoded in place and
  handed to `Session.event/2`, every other message goes to
  `Session.info/2`, and writes are port commands from that same process,
  so the bridge adds no process hop in either direction.

  ## Bridge protocol, version 1

  Each message is framed `{packet,4}` (a u32 big-endian length) and laid
  out as `u8 op | body`. All integers are big-endian. Stream ids are
  session-relative: client bidi streams are `4n` in the order they open
  (the first, id 0, is the control stream; letterbox leases follow), as in
  QUIC. Server uni streams are `4n+3`, opened by the Session for bulk (the
  BOOT) and always yielding to the client's streams. The gate accepts no
  uni streams; datagrams travel only from the client (PING).

  Gate to BEAM:

  | op | name | body |
  |---|---|---|
  | `0x01` | OPEN | `u8 n, ip` · `u16 n, origin` ("" when absent) · `u16 n, path` (with query) |
  | `0x10` | STREAM | `u32 id`: the peer opened a stream |
  | `0x11` | DATA | `u32 id` · bytes (chunked arbitrarily) |
  | `0x12` | FIN | `u32 id` |
  | `0x13` | RESET | `u32 id` · `u32 code`: the peer reset its sending side |
  | `0x14` | STOP | `u32 id` · `u32 code`: the peer stopped reading ours |
  | `0x20` | DGRAM | bytes, one client datagram |
  | `0x30` | CLOSED | `u32 code` · reason; the socket closes next |

  BEAM to gate:

  | op | name | body |
  |---|---|---|
  | `0x02` | ACCEPT | answer the CONNECT with 200 |
  | `0x03` | REFUSE | `u16 status` (403, 404 or 429) |
  | `0x04` | READY | HELLO verified; lift the pre-auth caps |
  | `0x11` `0x12` `0x13` | DATA FIN RESET | as above, for our side |
  | `0x15` | OPEN_UNI | `u32 id`: a server uni stream, `4n+3` |
  | `0x30` | CLOSE | `u32 code` · reason |

  The gate enforces the posture of an order gateway before anything
  reaches here: QUIC Retry under handshake load, a per-IP session cap,
  a path prefix and an `Origin` allow-list. An absent Origin means a
  native agent, so its Session must insist on an API-key HELLO. ACCEPT
  or REFUSE is due within 2 s of OPEN, and READY within 2 s of the
  accept, or the gate closes the connection. A Session that authenticated
  at OPEN (a browser's ticket) may write inside `init`, before the ACCEPT:
  `ready/1` lifts the caps as the session opens, and `open_uni/2` plus
  `send/3` put a BOOT on the wire in the same flight as the 200. The gate
  holds such messages until the session exists. Likewise, writes to the
  control stream (id 0) wait in the gate, in order, until the client opens
  it; more than 4 MiB of them closes the session. Until READY the peer gets
  one client bidi stream and a 64 KiB receive window, and no datagrams
  are forwarded.

  ## Carrier

  A Session sees `%HiremeWeb.Gate{}` as an opaque carrier and calls the
  write functions below on its module. The WebSocket fallback offers the
  same functions.
  """

  use Supervisor

  require Logger

  @enforce_keys [:socket]
  defstruct [:socket]

  @type t :: %__MODULE__{socket: :gen_tcp.socket()}
  @type id :: non_neg_integer()
  @type event ::
          {:stream, id()}
          | {:data, id(), binary()}
          | {:fin, id()}
          | {:reset, id(), non_neg_integer()}
          | {:stop, id(), non_neg_integer()}
          | {:dgram, binary()}
          | {:closed, non_neg_integer(), binary()}

  @open 0x01
  @accept 0x02
  @refuse 0x03
  @ready 0x04
  @stream 0x10
  @data 0x11
  @fin 0x12
  @reset 0x13
  @stop 0x14
  @open_uni 0x15
  @dgram 0x20
  @close 0x30

  # The gate's own deadline for an answer is 2 s; waiting for OPEN longer
  # than that only holds a socket.
  @open_wait 2_000
  # Messages delivered per re-arm of the socket; the kernel buffer behind
  # it pushes back on the gate when a Session falls behind.
  @burst 64
  @max_packet 16 * 1024 * 1024

  # ------------------------------------------------------------- carrier

  @doc "Answer the CONNECT with 200; the Session exists."
  @spec accept(t()) :: :ok | {:error, term()}
  def accept(%__MODULE__{socket: s}), do: :gen_tcp.send(s, <<@accept>>)

  @doc "Refuse the CONNECT with an HTTP status (403, 404 or 429)."
  @spec refuse(t(), 403 | 404 | 429) :: :ok | {:error, term()}
  def refuse(%__MODULE__{socket: s}, status), do: :gen_tcp.send(s, <<@refuse, status::16>>)

  @doc "HELLO is verified: lift the gate's pre-auth stream and window caps."
  @spec ready(t()) :: :ok | {:error, term()}
  def ready(%__MODULE__{socket: s}), do: :gen_tcp.send(s, <<@ready>>)

  @spec send(t(), id(), iodata()) :: :ok | {:error, term()}
  def send(%__MODULE__{socket: s}, id, iodata), do: :gen_tcp.send(s, [<<@data, id::32>> | iodata])

  @spec fin(t(), id()) :: :ok | {:error, term()}
  def fin(%__MODULE__{socket: s}, id), do: :gen_tcp.send(s, <<@fin, id::32>>)

  @spec reset(t(), id(), non_neg_integer()) :: :ok | {:error, term()}
  def reset(%__MODULE__{socket: s}, id, code), do: :gen_tcp.send(s, <<@reset, id::32, code::32>>)

  @doc "Open a server uni stream for bulk; `id` is `4n+3` and unused."
  @spec open_uni(t(), id()) :: :ok | {:error, term()}
  def open_uni(%__MODULE__{socket: s}, id) when rem(id, 4) == 3,
    do: :gen_tcp.send(s, <<@open_uni, id::32>>)

  @spec close(t(), non_neg_integer(), binary()) :: :ok | {:error, term()}
  def close(%__MODULE__{socket: s}, code, reason),
    do: :gen_tcp.send(s, [<<@close, code::32>> | reason])

  # One bridge message from the gate.
  @spec decode(binary()) :: event() | :error
  defp decode(<<@stream, id::32>>), do: {:stream, id}
  defp decode(<<@data, id::32, bytes::binary>>), do: {:data, id, bytes}
  defp decode(<<@fin, id::32>>), do: {:fin, id}
  defp decode(<<@reset, id::32, code::32>>), do: {:reset, id, code}
  defp decode(<<@stop, id::32, code::32>>), do: {:stop, id, code}
  defp decode(<<@dgram, bytes::binary>>), do: {:dgram, bytes}
  defp decode(<<@close, code::32, reason::binary>>), do: {:closed, code, reason}
  defp decode(_), do: :error

  # ------------------------------------------------------- client config

  @doc """
  What a page needs to reach the gate: the URL, and in development the
  SHA-256 of the gate's self-signed certificate for
  `serverCertificateHashes`. Returns `nil` when no gate is configured.
  """
  @spec client() :: %{url: String.t(), hashes: [String.t()]} | nil
  def client do
    config = Application.get_env(:hireme, __MODULE__, [])

    case config[:url] do
      nil ->
        nil

      url ->
        hashes =
          with path when is_binary(path) <- config[:hash_file],
               {:ok, hex} <- File.read(path),
               hex = String.trim(hex),
               true <- byte_size(hex) == 64 do
            [hex]
          else
            _ -> []
          end

        %{url: url, hashes: hashes}
    end
  end

  # ------------------------------------------------------------ listener

  @doc """
  Listens on `opts[:socket]` when it is set and no live node holds that
  socket already, and does nothing otherwise. `opts[:session]` names the
  Session module (`HiremeWeb.Session` unless a test swaps it).

  A second VM of the same configuration (`mix run` of a bench script beside
  `mix phx.server`) used to delete the server's socket and listen in its
  place; when it exited, every CONNECT the gate forwarded met a dead socket
  and was refused (Chromium: ERR_METHOD_NOT_SUPPORTED) until a restart.
  """
  def start_link(opts) do
    path = opts[:socket] && to_string(opts[:socket])

    cond do
      is_nil(path) ->
        :ignore

      held?(path) ->
        Logger.warning("gate socket #{path} is held by another node; not listening")
        :ignore

      true ->
        Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  defp held?(path) do
    case :gen_tcp.connect({:local, path}, 0, [:binary], 200) do
      {:ok, probe} -> :gen_tcp.close(probe) == :ok
      {:error, _} -> false
    end
  end

  @impl Supervisor
  def init(opts) do
    path = opts |> Keyword.fetch!(:socket) |> to_string()
    session = Keyword.get(opts, :session, HiremeWeb.Session)
    _ = File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        ifaddr: {:local, path},
        packet: 4,
        packet_size: @max_packet,
        active: false,
        backlog: 1024
      ])

    # Owner and group only: the gate's user reaches it through the group.
    :ok = File.chmod(path, 0o660)

    children = [
      {Task.Supervisor, name: HiremeWeb.Gate.Sessions},
      %{
        id: :acceptor,
        start: {Task, :start_link, [fn -> acceptor(listen, session) end]}
      }
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp acceptor(listen, session) do
    {:ok, socket} = :gen_tcp.accept(listen)

    {:ok, pid} =
      Task.Supervisor.start_child(HiremeWeb.Gate.Sessions, fn -> open(socket, session) end,
        restart: :temporary
      )

    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, :go)
    acceptor(listen, session)
  end

  # ---------------------------------------------------------- connection

  defp open(socket, session) do
    receive do
      :go -> :ok
    end

    carrier = %__MODULE__{socket: socket}

    case :gen_tcp.recv(socket, 0, @open_wait) do
      {:ok,
       <<@open, n, ip::binary-size(n), o::16, origin::binary-size(o), p::16,
         path::binary-size(p)>>} ->
        case session.init(carrier, %{ip: ip, origin: origin, path: path}) do
          {:ok, state} ->
            accept(carrier)
            :ok = :inet.setopts(socket, active: @burst)
            loop(socket, session, state)

          {:refuse, status} ->
            refuse(carrier, status)
            :gen_tcp.close(socket)
        end

      _ ->
        :gen_tcp.close(socket)
    end
  end

  defp loop(socket, session, state) do
    receive do
      {:tcp, ^socket, message} ->
        case decode(message) do
          :error -> finish(socket, session, :bridge_protocol, state)
          event -> step(socket, session, session.event(event, state))
        end

      {:tcp_passive, ^socket} ->
        :ok = :inet.setopts(socket, active: @burst)
        loop(socket, session, state)

      {:tcp_closed, ^socket} ->
        case session.event({:closed, 0, "bridge closed"}, state) do
          {_, _reason, state} -> finish(socket, session, :normal, state)
          {:ok, state} -> finish(socket, session, :normal, state)
        end

      {:tcp_error, ^socket, reason} ->
        finish(socket, session, {:bridge, reason}, state)

      other ->
        step(socket, session, session.info(other, state))
    end
  end

  defp step(socket, session, {:ok, state}), do: loop(socket, session, state)

  defp step(socket, session, {:stop, reason, state}),
    do: finish(socket, session, reason, state)

  defp finish(socket, session, reason, state) do
    session.terminate(reason, state)
    :gen_tcp.close(socket)
  end
end
