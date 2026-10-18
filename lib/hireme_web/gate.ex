defmodule HiremeWeb.Gate do
  @moduledoc """
  The BEAM end of the WebTransport gate (`native/gate`, `hireme-gate`).

  The gate terminates QUIC and HTTP/3 and holds no business logic. Each
  WebTransport session becomes one connection to the Unix socket this
  module listens on, and that connection's process hosts the
  `HiremeWeb.Session` itself: control-stream bytes are split into frames
  in place and handed to `Session.frame/2`, every other message the
  process receives goes to `Session.info/2`, and what the Session pushes
  is written back on the same socket, so the bridge adds no process hop.

  ## Bridge protocol, version 2

  Each message is a u32 big-endian length, then that many bytes laid out
  as `u8 op | body`; integers are big-endian. A session has one client
  stream, the control stream, which carries every frame in order, and any
  number of server uni streams for bulk (the BOOT), each one whole payload.

  Gate to BEAM:

  | op | name | body |
  |---|---|---|
  | `0x01` | OPEN | `u8 n, ip` · `u16 n, origin` ("" when absent) · `u16 n, path` |
  | `0x11` | DATA | control-stream bytes, chunked arbitrarily |
  | `0x30` | CLOSED | `u32 code` · reason; the socket closes next |

  BEAM to gate:

  | op | name | body |
  |---|---|---|
  | `0x02` | ACCEPT | answer the CONNECT with 200 |
  | `0x03` | REFUSE | `u16 status` (403, 404 or 429) |
  | `0x04` | READY | HELLO verified; lift the pre-auth window |
  | `0x11` | DATA | bytes for the control stream |
  | `0x15` | UNI | one whole payload on a fresh server uni stream, then its end |
  | `0x30` | CLOSE | `u32 code` · reason |

  Before anything reaches here the gate has applied QUIC Retry under load,
  a per-IP session cap, the path prefix and the `Origin` allow-list (an
  absent Origin is a native agent, whose HELLO must then carry a key).
  ACCEPT or REFUSE is due within 2 s of OPEN and READY within 2 s of the
  accept. Control bytes written before the client opens its stream wait in
  the gate, in order, up to 4 MiB.

  READY is sent with the Session's WELCOME, the frame that says HELLO
  passed; a BOOT goes out on its own uni stream, so a large one never holds
  up the control stream, and every other frame goes on the control stream.

  ## Supervision and config

  `config :hireme, HiremeWeb.Gate`: `socket` (this listener), `url` (what a
  page dials), `cmd` (the gate's command line, run as this node's Port
  with `env` added and `GATE_SOCKET` and `GATE_CERT_HASH_FILE` set from
  `socket` and `hash_file`), `hash_file` (where a self-signed gate writes
  its certificate's SHA-256, hex). Without `socket` nothing starts; with
  `config :hireme, :gate, false` (HIREME_GATE=off) the application does not
  start this module at all. `rest_for_one`: the listener, then the Port.
  The gate exits when its stdin closes; one that exits is started again
  after 2 s, so a broken binary cannot spend the restart budget.
  """

  use Supervisor
  require Logger

  alias HiremeWeb.Session
  alias HiremeWeb.Wire.Codec

  @open 0x01
  @accept 0x02
  # REFUSE (0x03, u16 status) is the bridge's; a wire session refuses in its
  # HELLO answer instead, so this end never sends it.
  @ready 0x04
  @data 0x11
  @uni 0x15
  @close 0x30

  # The gate's own deadline for an answer is 2 s.
  @open_wait 2_000
  # Messages per re-arm of the socket; the kernel buffer behind it pushes
  # back on the gate when a Session falls behind.
  @burst 64
  @max_message 16 * 1024 * 1024
  # A Session's stop reason as a WebTransport close code.
  @close_normal 0
  @close_error 0x4100

  @boot 3
  @welcome 2

  defp config, do: Application.get_env(:hireme, __MODULE__, [])

  defp enabled?,
    do: Application.get_env(:hireme, :gate, true) != false and config()[:socket] != nil

  # ------------------------------------------------------------- page

  @doc "The gate's public URL, or nil when no gate runs."
  @spec url() :: String.t() | nil
  def url, do: if(enabled?(), do: config()[:url])

  @doc """
  The hex SHA-256 of a self-signed gate's certificate, for the page's
  `serverCertificateHashes`; nil for a gate with a CA certificate, or none.
  """
  @spec cert_hash() :: String.t() | nil
  def cert_hash do
    with true <- enabled?(),
         file when is_binary(file) <- config()[:hash_file],
         {:ok, text} <- File.read(file),
         hash when byte_size(hash) == 64 <- String.trim(text) do
      hash
    else
      _ -> nil
    end
  end

  @doc "Ask the gate to reread its certificate (it also notices PEM changes itself)."
  @spec reload() :: :ok
  def reload, do: command("reload")

  @doc "Ask the gate to print its counters to the log."
  @spec stats() :: :ok
  def stats, do: command("stats")

  defp command(line) do
    case Process.whereis(HiremeWeb.Gate.Binary) do
      nil ->
        :ok

      pid ->
        send(pid, {:command, line})
        :ok
    end
  end

  # ------------------------------------------------------------ listener

  @doc """
  Listens on `opts[:socket]` when it is set and no live node holds that
  socket, and does nothing otherwise: a second VM of the same config (a
  bench script beside the server) must not take the server's socket.
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

    # sun_path holds 108 bytes with its NUL; past that listen/1 says only badarg.
    if byte_size(path) > 107,
      do:
        raise(
          ArgumentError,
          "gate socket path is #{byte_size(path)} bytes, past the 107 a Unix socket allows: #{path}"
        )

    _ = File.rm(path)
    File.mkdir_p!(Path.dirname(path))

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        ifaddr: {:local, path},
        packet: 4,
        packet_size: @max_message,
        active: false,
        backlog: 1024
      ])

    # The gate is this node's own child and runs as its user.
    :ok = File.chmod(path, 0o600)

    children = [
      {Task.Supervisor, name: HiremeWeb.Gate.Sessions},
      %{id: :acceptor, start: {Task, :start_link, [fn -> acceptor(listen) end]}}
      | binary(opts)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp binary(opts) do
    case opts[:cmd] do
      [exe | args] ->
        env =
          [{"GATE_SOCKET", to_string(opts[:socket])} | List.wrap(opts[:env])] ++
            if(opts[:hash_file],
              do: [{"GATE_CERT_HASH_FILE", to_string(opts[:hash_file])}],
              else: []
            )

        # The gate faces the internet and needs only its own settings: every
        # other variable the node holds (SECRET_KEY_BASE, the cookie, the
        # mail token) is unset for it, since a Port extends the environment.
        unset =
          for {k, _} <- System.get_env(),
              not kept?(k, exe),
              not List.keymember?(env, k, 0),
              do: {String.to_charlist(k), false}

        port_opts = [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          line: 4096,
          args: args,
          env: unset ++ for({k, v} <- env, do: {~c"#{k}", ~c"#{v}"}),
          cd: opts[:cd] || File.cwd!()
        ]

        [%{id: :gate, start: {__MODULE__, :start_binary, [exe, port_opts]}}]

      _ ->
        []
    end
  end

  # A built gate needs only its GATE_* settings; the development profile
  # runs it through cargo, which also needs a shell's basics and its own.
  @cargo_env ~w(PATH HOME USER LANG TMPDIR TZ)

  defp kept?(name, exe) do
    String.starts_with?(name, "GATE_") or
      (Path.basename(exe) == "cargo" and
         (name in @cargo_env or String.starts_with?(name, ["CARGO_", "RUST"])))
  end

  @doc false
  def start_binary(exe, port_opts) do
    path = System.find_executable(exe) || exe

    pid =
      spawn_link(fn ->
        # A stop waits for the gate to let go of its UDP port, so the gate
        # started after it can bind at once.
        Process.flag(:trap_exit, true)

        try do
          Port.open({:spawn_executable, path}, port_opts)
        rescue
          e -> gate_exited(Exception.message(e))
        else
          port -> binary_loop(port)
        end
      end)

    Process.register(pid, HiremeWeb.Gate.Binary)
    {:ok, pid}
  end

  defp binary_loop(port) do
    receive do
      {:command, line} ->
        Port.command(port, [line, ?\n])
        binary_loop(port)

      {^port, {:data, {_, line}}} ->
        Logger.info(line)
        binary_loop(port)

      {^port, {:exit_status, status}} ->
        gate_exited("status #{status}")

      {:EXIT, _, reason} ->
        case Port.info(port, :os_pid) do
          {:os_pid, pid} ->
            Port.close(port)
            await_exit("/proc/#{pid}", 150)

          nil ->
            :ok
        end

        exit(reason)
    end
  end

  # The gate closes its endpoint on EOF and waits at most 2 s for peers.
  defp await_exit(proc, 0), do: Logger.warning("hireme-gate (#{proc}) outlived its stop")

  defp await_exit(proc, tries) do
    if File.exists?(proc) do
      Process.sleep(20)
      await_exit(proc, tries - 1)
    end
  end

  defp gate_exited(why) do
    Logger.error("hireme-gate exited (#{why}); starting it again in 2 s")
    Process.sleep(2_000)
    exit({:shutdown, :gate_exited})
  end

  defp acceptor(listen) do
    {:ok, socket} = :gen_tcp.accept(listen)

    {:ok, pid} =
      Task.Supervisor.start_child(HiremeWeb.Gate.Sessions, fn -> connection(socket) end,
        restart: :temporary
      )

    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, :go)
    acceptor(listen)
  end

  # ---------------------------------------------------------- connection

  defp connection(socket) do
    receive do
      :go -> :ok
    end

    case :gen_tcp.recv(socket, 0, @open_wait) do
      {:ok,
       <<@open, n, ip::binary-size(n), o::16, origin::binary-size(o), p::16,
         _path::binary-size(p)>>} ->
        peer = %{peer_ip: ip, origin: origin, carrier: :wt}

        {:ok, state} = Session.open(peer)
        :ok = :gen_tcp.send(socket, <<@accept>>)
        :ok = :inet.setopts(socket, active: @burst)
        loop(%{socket: socket, buf: <<>>, ready: false}, state)

      _ ->
        :gen_tcp.close(socket)
    end
  end

  defp loop(%{socket: socket} = c, state) do
    receive do
      {:tcp, ^socket, <<@data, bytes::binary>>} ->
        frames(%{c | buf: c.buf <> bytes}, state)

      {:tcp, ^socket, <<@close, _code::32, _reason::binary>>} ->
        :gen_tcp.close(socket)

      {:tcp, ^socket, _other} ->
        close(c, @close_error, "bridge protocol")

      {:tcp_passive, ^socket} ->
        :ok = :inet.setopts(socket, active: @burst)
        loop(c, state)

      {:tcp_closed, ^socket} ->
        :ok

      {:tcp_error, ^socket, _reason} ->
        :gen_tcp.close(socket)

      other ->
        step(c, Session.info(other, state))
    end
  end

  # Every whole frame in the buffer, in order, to the Session.
  defp frames(c, state) do
    case Codec.split(c.buf, Codec.max_up()) do
      {:ok, frame, rest} ->
        case Session.frame(frame, state) do
          {:stop, _, _, _} = stop -> step(%{c | buf: rest}, stop)
          answer -> with {:cont, c, state} <- push(%{c | buf: rest}, answer), do: frames(c, state)
        end

      :more ->
        loop(c, state)

      {:error, _} ->
        close(c, @close_error, "not frames")
    end
  end

  defp step(c, answer) do
    case push(c, answer) do
      {:cont, c, state} -> loop(c, state)
      done -> done
    end
  end

  defp push(c, {:ok, state}), do: {:cont, c, state}

  defp push(c, {:push, frames, state}) do
    case write(c, frames) do
      {:ok, c} -> {:cont, c, state}
      :error -> :gen_tcp.close(c.socket)
    end
  end

  defp push(c, {:stop, reason, frames, _state}) do
    case write(c, frames) do
      {:ok, c} -> close(c, close_code(reason), close_reason(reason))
      :error -> :gen_tcp.close(c.socket)
    end
  end

  # A BOOT on its own uni stream; READY just ahead of WELCOME; the rest on
  # the control stream, in one write.
  defp write(c, frames) do
    {c, messages} =
      Enum.reduce(frames, {c, []}, fn frame, {c, acc} ->
        case kind(frame) do
          @boot ->
            {c, [[<<@uni>> | frame] | acc]}

          @welcome when not c.ready ->
            {%{c | ready: true}, [[<<@data>> | frame], <<@ready>> | acc]}

          _ ->
            {c, [[<<@data>> | frame] | acc]}
        end
      end)

    result =
      messages
      |> Enum.reverse()
      |> Enum.reduce_while(:ok, fn m, :ok ->
        case :gen_tcp.send(c.socket, m) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

    if result == :ok, do: {:ok, c}, else: :error
  end

  defp kind(frame) do
    <<_len::little-32, kind::8, _::binary>> = IO.iodata_to_binary(frame)
    kind
  end

  defp close(c, code, reason) do
    _ = :gen_tcp.send(c.socket, [<<@close, code::32>> | reason])
    :gen_tcp.close(c.socket)
  end

  defp close_code(reason) when reason in [:normal, :shutdown], do: @close_normal
  defp close_code(_), do: @close_error

  defp close_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp close_reason({kind, _}) when is_atom(kind), do: Atom.to_string(kind)
  defp close_reason(_), do: "closed"
end
