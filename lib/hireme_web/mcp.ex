defmodule HiremeWeb.Mcp do
  @moduledoc """
  MCP over HTTP at `/mcp` (the Streamable HTTP transport): an agent is an
  API key in `Authorization: Bearer`, and each MCP session is a wire
  session the node holds for it (`HiremeWeb.Mcp.Session`), so a key's
  grants, lease, revocation and the sequencer's verdicts are the same as
  on any carrier. There is no client to install: an agent points at the
  URL.

  The key is the only credential, checked before the body is read. A
  request without a valid one is answered 401 (past `api_key_peer`'s
  failures from its address, 429); a valid key is never refused.

  POST carries one JSON-RPC message: a request is answered as JSON (or, for
  `subscriptions/listen`, as an event stream), a notification with 202.
  GET opens the event stream of a session (`Mcp-Session-Id`) for the
  handshake revisions' notifications; DELETE ends a session. A session
  without an id is the key's default one, kept across requests, so a
  stateless client still holds its lease. A request naming a session the
  node no longer holds (idle past its limit, or a restart) is served by a
  new session under the same id, so a client never has to notice.
  """

  import Plug.Conn
  require Logger
  alias Hireme.Security
  alias HiremeWeb.Mcp.Session

  # A burst of puts is one request: room for a big one, never unbounded.
  @max_body 64 * 1024 * 1024
  # How long a request waits for its answer: under the 100 s a proxy in
  # front of the node allows (Cloudflare). A write answers by its own
  # deadline, before this, with what landed so far (`Session`).
  @wait 90_000
  @keepalive 15_000
  @unsure "; it may still have written: find or get before calling it again"

  @doc "Answers one request to `/mcp`."
  def call(conn) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    case origin(conn) do
      :ok -> authenticated(conn, ip)
      # A browser page on another origin (DNS rebinding) is refused.
      :refused -> refuse(conn, 403, "a page on another origin may not call this node")
    end
  end

  defp authenticated(conn, ip) do
    case authenticate(conn, ip) do
      {:ok, key, secret} ->
        serve(conn, key, secret, ip)

      :limited ->
        conn
        |> put_resp_header("retry-after", "60")
        |> refuse(429, "too many wrong keys from this address; a valid key is still served")

      :error ->
        refused(ip, conn)

        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="hireme"))
        |> send_resp(401, "")
    end
  end

  # An absent Origin is an agent; a present one must be this node's own.
  defp origin(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [o | _] ->
        if String.trim_trailing(o, "/") in HiremeWeb.Endpoint.origins(), do: :ok, else: :refused
    end
  end

  defp authenticate(conn, ip) do
    with ["Bearer " <> secret | _] <- get_req_header(conn, "authorization"),
         {:ok, key} <- Hireme.Keys.authenticate(String.trim(secret), ip) do
      {:ok, key, String.trim(secret)}
    else
      {:error, :rate_limited} -> :limited
      _ -> :error
    end
  end

  # A refused key is on the trail with its peer, inside the global refusal budget.
  defp refused(ip, conn) do
    if Security.limit(:refusal_global, :all) == :ok do
      ua = conn |> get_req_header("user-agent") |> List.first()

      Hireme.Audit.record(:wire_key_refused, %{carrier: :mcp}, %{
        ip: ip,
        user_agent: ua && Security.clip(ua)
      })
    end
  end

  defp serve(%{method: "POST"} = conn, key, secret, ip) do
    with {:ok, body, conn} <- body(conn),
         {:ok, %{"jsonrpc" => "2.0"} = msg} <- JSON.decode(body) do
      case session(conn, key, secret, ip, msg) do
        {:ok, pid, sid} -> post(conn, pid, sid, msg)
        {:error, why} -> unavailable(conn, msg, why)
      end
    else
      {:too_large, conn} ->
        refuse(conn, 413, "the body is over #{div(@max_body, 1024 * 1024)} MiB")

      {:ok, _} ->
        rpc_error(
          conn,
          400,
          nil,
          -32600,
          "one JSON-RPC 2.0 message per request; batches are not answered"
        )

      _ ->
        rpc_error(conn, 400, nil, -32700, "the body is not JSON")
    end
  end

  defp serve(%{method: "GET"} = conn, key, secret, ip) do
    with {:ok, pid, sid} <- session(conn, key, secret, ip, %{}),
         :ok <- Session.listen(pid, self(), :legacy) do
      stream(conn, pid, sid, [])
    else
      {:error, why} -> unavailable(conn, %{}, why)
    end
  end

  defp serve(%{method: "DELETE"} = conn, key, _secret, _ip) do
    case existing(conn, key) do
      {:ok, pid, _} ->
        Session.close(pid)
        send_resp(conn, 204, "")

      _ ->
        refuse(conn, 404, "no such session")
    end
  end

  defp serve(conn, _key, _secret, _ip),
    do:
      conn
      |> put_resp_header("allow", "GET, POST, DELETE")
      |> refuse(405, "MCP takes GET, POST and DELETE")

  defp post(conn, pid, sid, %{"method" => "subscriptions/listen", "id" => _} = msg) do
    case Session.subscribe_stream(pid, self(), msg) do
      {:ok, ack} -> stream(conn, pid, sid, [ack])
      {:error, answer} -> reply(conn, sid, answer)
    end
  end

  defp post(conn, pid, sid, %{"id" => id, "method" => _} = msg) when id != nil do
    case Session.request(pid, msg, @wait) do
      # Cancelled meanwhile (notifications/cancelled): nothing to answer.
      {:ok, nil} ->
        conn |> put_resp_header("mcp-session-id", sid) |> send_resp(202, "")

      {:ok, answer} ->
        reply(conn, sid, answer)

      # The session went while answering (a crash, the node stopping): the
      # next request names it and is served by a new one.
      {:error, :gone} ->
        reply(conn, sid, failure(id, -32_603, "the session ended before it answered"))

      {:error, :timeout} ->
        reply(conn, sid, failure(id, -32_001, "no answer within #{div(@wait, 1000)} s"))
    end
  end

  # An object with an id that is neither a request nor a response.
  defp post(conn, _pid, _sid, %{"id" => id} = msg)
       when id != nil and not is_map_key(msg, "result") and not is_map_key(msg, "error"),
       do:
         rpc_error(
           conn,
           400,
           id,
           -32600,
           "a message with an id is a request (method) or a response (result, error)"
         )

  # A notification or a response: taken, nothing to answer.
  defp post(conn, pid, sid, msg) do
    Session.notify(pid, msg)
    conn |> put_resp_header("mcp-session-id", sid) |> send_resp(202, "")
  end

  defp reply(conn, sid, answer) do
    conn
    |> put_resp_header("mcp-session-id", sid)
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode_to_iodata!(answer))
  end

  @doc false
  # One JSON-RPC error, the plug's and the session's.
  def error(id, code, message),
    do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}

  @doc false
  # A request the session could not finish: if it was a write, some of it
  # may have landed, so the agent reads before sending it again.
  def failure(id, code, why), do: error(id, code, why <> @unsure)

  # No session for a valid key: why, when to retry, and a line in the log.
  defp unavailable(conn, msg, why) do
    {status, text} =
      case why do
        :not_found -> {404, "that session id is another key's"}
        :key_sessions -> {429, "this key holds 64 sessions, none of them idle; retry shortly"}
        {:bye, :revoked} -> {401, "the key was revoked or paused while the session opened"}
        _ -> {503, "the session could not open (#{inspect(why)}); retry shortly"}
      end

    if status != 404, do: Logger.warning("mcp: no session for a key: #{inspect(why)}")
    conn |> put_resp_header("retry-after", "5") |> rpc_error(status, msg["id"], -32_000, text)
  end

  # Every refusal carries what went wrong, as a JSON-RPC error.
  defp refuse(conn, status, message), do: rpc_error(conn, status, nil, -32_000, message)

  defp rpc_error(conn, status, id, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode_to_iodata!(error(id, code, message)))
  end

  # The session a request names (resumed under its id when the node no
  # longer holds it), the one `initialize` starts, or the key's default.
  defp session(conn, key, secret, ip, msg) do
    ua = conn |> get_req_header("user-agent") |> List.first()
    peer = %{ip: ip, user_agent: ua && Security.clip(ua)}
    label = get_in(msg, ["params", "clientInfo", "name"])

    mode =
      case get_req_header(conn, "mcp-session-id") do
        [sid | _] -> {:resume, sid}
        [] -> if msg["method"] == "initialize", do: :fresh, else: :default
      end

    Session.start(key, secret, peer, label, mode)
  end

  defp existing(conn, key) do
    with [sid | _] <- get_req_header(conn, "mcp-session-id"),
         {:ok, pid} <- Session.whereis(sid, key.id) do
      {:ok, pid, sid}
    else
      _ -> :error
    end
  end

  # The body, bounded; a gzip-encoded one is inflated under the same bound.
  defp body(conn) do
    case read_body(conn, length: @max_body, read_length: 1_048_576) do
      {:ok, body, conn} ->
        case get_req_header(conn, "content-encoding") do
          ["gzip" | _] ->
            case Security.inflate(body, @max_body, 31) do
              nil -> {:too_large, conn}
              plain -> {:ok, plain, conn}
            end

          _ ->
            {:ok, body, conn}
        end

      {:more, _, conn} ->
        {:too_large, conn}

      _ ->
        :error
    end
  end

  # An event stream: the first events, then whatever the session sends,
  # with a comment line as keepalive, until the client goes or the session ends.
  defp stream(conn, pid, sid, first) do
    ref = Process.monitor(pid)

    conn =
      conn
      |> put_resp_header("mcp-session-id", sid)
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-store")
      |> send_chunked(200)

    case Enum.reduce_while(first, {:ok, conn}, fn e, {:ok, c} -> event(c, e) end) do
      {:ok, conn} -> pump(conn, ref)
      _ -> conn
    end
  end

  defp event(conn, json) do
    case chunk(conn, ["event: message\ndata: ", JSON.encode_to_iodata!(json), "\n\n"]) do
      {:ok, conn} -> {:cont, {:ok, conn}}
      _ -> {:halt, :closed}
    end
  end

  defp pump(conn, ref) do
    receive do
      {:mcp_event, json} ->
        case event(conn, json) do
          {:cont, {:ok, conn}} -> pump(conn, ref)
          _ -> conn
        end

      {:mcp_end} ->
        conn

      {:DOWN, ^ref, :process, _, _} ->
        conn
    after
      @keepalive ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> pump(conn, ref)
          _ -> conn
        end
    end
  end
end

defmodule HiremeWeb.Mcp.Session do
  @moduledoc """
  One MCP session: a wire session (`HiremeWeb.Session`) this process hosts
  as its carrier, standing in for the peer (it answers the session's
  pings), and the MCP session itself, `native/mcp`'s machine (the daemon's
  too, docs/mcp/one_session.md), held in the NIF and stepped here.

  Each step runs inside `Hireme.Sequencer.read/2`, on the account's kernel
  under the key's grants, so a read sees every write acknowledged before
  it. A step that needs what only this process can do stops on an effect:
  ops to submit (answered when every verdict is in, or at the deadline),
  a lease claim or release, a blob to store. The effect done, the request
  steps again with its outcome. What the session knows (masks, the lease,
  the bulk contract, the next op id) goes in as facts; what a step changed
  of it comes back as a ledger. A put under the session's bulk contract
  (`lease` with `bulk`) is one atomic burst: it lands whole or not at all.

  A session that has served no request for `@idle_ms` ends, and its lease
  with it; a request naming it later is served by a new one under its id.
  A key holds at most `Hireme.Security.key_sessions/0` sessions: a new one
  past that ends the key's longest-idle one (one with an open event stream
  last), so a new session always fits.
  """

  use GenServer
  import Bitwise, only: [&&&: 2]
  alias Hireme.Kernel.Nif
  alias Hireme.{Lease, Security, Sequencer}
  alias HiremeWeb.Mcp
  alias HiremeWeb.Wire.Codec

  @registry HiremeWeb.Mcp.Registry
  @supervisor HiremeWeb.Mcp.Sessions
  @idle_ms :timer.minutes(30)
  # A write's call answers by then with what landed, under `HiremeWeb.Mcp`'s wait.
  @deadline 80_000
  def child_spec(_),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}

  @doc "The supervision this module needs: its registry and its sessions."
  def children,
    do: [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
    ]

  # ------------------------------------------------------------------ API

  @doc """
  The key's session for a request: `:fresh` (an `initialize`) starts one,
  `:default` is the key's own, kept across requests, and `{:resume, sid}`
  is `sid`, or a new session under that id when the node no longer holds
  it. `{:ok, pid, session_id}`, or `{:error, why}`.
  """
  def start(key, secret, peer, label, mode) do
    case held(key.id, mode) do
      :none -> open(%{key: key, secret: secret, peer: peer, label: label, mode: mode}, 3)
      found -> found
    end
  end

  defp held(key_id, :default) do
    case Registry.lookup(@registry, {:default, key_id}) do
      [{pid, _}] -> named(pid)
      [] -> :none
    end
  end

  defp held(key_id, {:resume, sid}) do
    case Registry.lookup(@registry, {:id, sid}) do
      [{pid, {^key_id, _, _}}] -> {:ok, pid, sid}
      [_] -> {:error, :not_found}
      [] -> if sid =~ ~r/^[A-Za-z0-9_-]{16,128}$/, do: :none, else: {:error, :not_found}
    end
  end

  defp held(_key_id, :fresh), do: :none

  defp open(args, tries) do
    make_room(args.key.id)

    case DynamicSupervisor.start_child(@supervisor, %{
           id: __MODULE__,
           start: {GenServer, :start_link, [__MODULE__, args]},
           restart: :temporary
         }) do
      {:ok, pid} -> named(pid)
      # Two requests raced for the key's default or for one resumed id: the winner's.
      {:error, {:already, pid}} -> named(pid)
      # The key's sessions on other carriers fill its cap too; room again, then retry.
      {:error, :key_sessions} when tries > 1 -> open(args, tries - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp named(pid) do
    {:ok, pid, GenServer.call(pid, :id)}
  catch
    :exit, _ -> {:error, :gone}
  end

  # Past the key's cap its longest-idle sessions end, ones with an open
  # event stream last, so the next one fits.
  defp make_room(key_id) do
    mine =
      Registry.select(@registry, [
        {{{:id, :_}, :"$1", {key_id, :"$2", :"$3"}}, [], [{{:"$1", :"$2", :"$3"}}]}
      ])

    over = length(mine) - Security.key_sessions() + 1

    if over > 0 do
      mine
      |> Enum.sort_by(fn {_pid, used, streams} -> {streams > 0, used} end)
      |> Enum.take(over)
      |> Enum.each(fn {pid, _, _} -> stop(pid) end)
    end
  end

  defp stop(pid) do
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  @doc "A session by id, if it is `key_id`'s."
  def whereis(sid, key_id) do
    case Registry.lookup(@registry, {:id, sid}) do
      [{pid, {^key_id, _, _}}] -> {:ok, pid}
      _ -> :error
    end
  end

  def request(pid, msg, wait) do
    {:ok, GenServer.call(pid, {:request, msg}, wait)}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :gone}
  end

  def notify(pid, msg), do: GenServer.cast(pid, {:notify, msg})

  def listen(pid, stream, kind) do
    GenServer.call(pid, {:listen, stream, kind})
  catch
    :exit, _ -> {:error, :gone}
  end

  def subscribe_stream(pid, stream, msg) do
    GenServer.call(pid, {:subscribe_stream, stream, msg}, 30_000)
  catch
    :exit, _ -> {:error, failure(msg["id"])}
  end

  defp failure(id),
    do: Mcp.error(id, -32_603, "the session ended before it answered; send the request again")

  def close(pid), do: GenServer.cast(pid, :close)

  # ------------------------------------------------------------------ session

  @impl GenServer
  def init(args) do
    # The name first, so a race for the key's default or a resumed id has one winner.
    case claim_name(args.mode, args.key.id) do
      {:error, {:already_registered, pid}} -> {:stop, {:already, pid}}
      _ -> hello(args)
    end
  end

  defp claim_name(:default, key_id), do: Registry.register(@registry, {:default, key_id}, nil)

  defp claim_name({:resume, sid}, key_id),
    do: Registry.register(@registry, {:id, sid}, {key_id, now(), 0})

  defp claim_name(:fresh, _key_id), do: :ok

  defp hello(args) do
    peer = %{peer_ip: args.peer.ip, origin: nil, carrier: :mcp, user_agent: args.peer.user_agent}
    {:ok, wire} = HiremeWeb.Session.open(peer)
    label = String.slice(args.label || "mcp", 0, 64)

    case HiremeWeb.Session.frame(Codec.encode_hello(:key, args.secret, label), wire) do
      {:push, _welcome_and_train, %{phase: :live} = wire} ->
        sid =
          case args.mode do
            {:resume, sid} ->
              sid

            _ ->
              sid = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
              {:ok, _} = Registry.register(@registry, {:id, sid}, {args.key.id, now(), 0})
              sid
          end

        g = wire.session.grants
        <<base::unsigned-64>> = :crypto.strong_rand_bytes(8)
        Process.send_after(self(), :idle, @idle_ms)

        {:ok,
         %{
           id: sid,
           wire: wire,
           key_id: args.key.id,
           account_id: wire.account_id,
           masks: {g.read_mask, g.write_mask, g.may_delete},
           mcp: Nif.mcp_open(wire.session.label),
           # Op ids are unique per key (the ledger answers a resend by them): a random base, then counted.
           next_op: base &&& 0x3FFF_FFFF_FFFF_FFFF,
           pending: %{},
           calls: %{},
           contract: nil,
           streams: %{},
           sinks: 0,
           used: now()
         }}

      {:stop, reason, _frames, _wire} ->
        {:stop, reason}

      _ ->
        {:stop, :hello}
    end
  end

  @impl GenServer
  def handle_call(:id, _from, s), do: {:reply, s.id, s}

  def handle_call({:request, msg}, from, s) do
    to = %{from: from, id: msg["id"]}
    {:noreply, step(used(s), to, &Nif.mcp_request(s.mcp, &1, &2, JSON.encode!(msg)))}
  end

  def handle_call({:listen, stream, :legacy}, _from, s) do
    {sink, s} = watch_stream(used(s), stream)
    Nif.mcp_stream(s.mcp, sink, true)
    {:reply, :ok, s}
  end

  def handle_call({:subscribe_stream, stream, %{"id" => id} = msg}, from, s) do
    {sink, s} = watch_stream(used(s), stream)
    to = %{from: from, id: id, listen: true}
    {:noreply, step(s, to, &Nif.mcp_listen(s.mcp, &1, &2, JSON.encode!(msg), sink))}
  end

  # A notification (`notifications/cancelled` among them) or a client's response: nothing to answer.
  @impl GenServer
  def handle_cast({:notify, msg}, s) do
    {:noreply,
     step(used(s), %{from: nil, id: nil}, &Nif.mcp_request(s.mcp, &1, &2, JSON.encode!(msg)))}
  end

  def handle_cast(:close, s), do: {:stop, :normal, s}

  @impl GenServer
  def handle_info({:sequencer, :verdicts, _rev, acks, nacks} = msg, s) do
    s = Enum.reduce(acks, s, &verdict(&2, &1.op_id, {:ack, &1}))
    s = Enum.reduce(nacks, s, &verdict(&2, &1.op_id, {:nack, &1}))
    wire(msg, s)
  end

  # The watched rows a PATCH moved: their streams hear it.
  def handle_info({:sequencer, :patch, _rev, body} = msg, s) do
    with [_ | _] = out <- Nif.mcp_patch(s.mcp, body) do
      pids = Map.new(s.streams, fn {_, {pid, sink}} -> {sink, pid} end)
      for {sink, json} <- out, pid = pids[sink], do: send(pid, {:mcp_event, JSON.decode!(json)})
    end

    wire(msg, s)
  end

  # A call past its deadline answers what landed and what is still pending.
  def handle_info({:call_timeout, ref}, s) do
    case Map.pop(s.calls, ref) do
      {nil, _} ->
        {:noreply, s}

      {call, calls} ->
        s = %{s | calls: calls, pending: Map.drop(s.pending, call.ops)}
        {:noreply, finish(call, s)}
    end
  end

  def handle_info(:idle, s) do
    left = @idle_ms - (now() - s.used)
    if left > 0, do: Process.send_after(self(), :idle, left)
    if left > 0, do: {:noreply, s}, else: {:stop, :normal, s}
  end

  def handle_info({:DOWN, ref, :process, _, _}, s) when is_map_key(s.streams, ref) do
    {{_, sink}, streams} = Map.pop(s.streams, ref)
    streaming(s.id, -1)
    Nif.mcp_stream(s.mcp, sink, false)
    {:noreply, %{s | streams: streams}}
  end

  def handle_info(msg, s), do: wire(msg, s)

  # The wire session's own business (pings, ticks, BYE, drain): its pings
  # are answered here, as its peer would; when it ends, so does this.
  defp wire(msg, s) do
    case HiremeWeb.Session.info(msg, s.wire) do
      {:ok, wire} ->
        {:noreply, %{s | wire: wire}}

      {:push, frames, wire} ->
        {:noreply, %{s | wire: pong(frames, wire)}}

      {:stop, reason, _frames, wire} ->
        {:stop, {:shutdown, reason}, %{s | wire: wire}}
    end
  end

  defp pong(frames, wire) do
    Enum.reduce(frames, wire, fn f, wire ->
      case Codec.decode(f, :down) do
        {:ok, :PING, _, _, body} ->
          {:ok, n} = Codec.nonce(body)

          case HiremeWeb.Session.frame(Codec.ping(:PONG, n), wire) do
            {_, wire} -> wire
            {_, _, wire} -> wire
            {_, _, _, wire} -> wire
          end

        _ ->
          wire
      end
    end)
  end

  @impl GenServer
  def terminate(_reason, s) do
    for {_, {pid, _}} <- s.streams, do: send(pid, {:mcp_end})
    for {_, call} <- s.calls, do: fail(call, "the session ended before every verdict came")
    :ok
  end

  # A call answered without its verdicts: it may have written.
  defp fail(call, why), do: reply(call.to, Mcp.failure(call.to.id, -32_603, why))

  # ------------------------------------------------------------------ the machine

  # Steps a request on the account's kernel: its answer goes to `to`, or the effect it stops on is
  # done here and it steps again with the outcome.
  defp step(s, to, f) do
    case Sequencer.read(s.account_id, fn k, lease -> f.(k.res, facts(s, lease)) end) do
      {:ok, {:error, :panic}} ->
        reply(to, rpc_error(to, "the read failed on the node; a read is safe to call again"))
        s

      {:ok, {step, {ops, drawn, lost}}} ->
        s = %{s | next_op: s.next_op + ops}
        s = %{s | contract: drawn(s.contract, drawn, lost)}
        next(s, step, to)

      {:error, _} ->
        reply(to, rpc_error(to, "the account is unavailable; call again"))
        s
    end
  end

  defp next(s, {:answer, json}, to), do: tap(s, fn _ -> reply(to, json && JSON.decode!(json)) end)
  defp next(s, {:pending, ticket, effect}, to), do: effect(s, ticket, effect, to)

  defp resume(s, ticket, outcome, to),
    do: step(s, to, &Nif.mcp_resume(s.mcp, &1, &2, ticket, JSON.encode!(outcome)))

  # The node is connected and booted already: a wait is over at once.
  defp effect(s, ticket, :wait, to), do: resume(s, ticket, %{waited: true}, to)

  defp effect(s, ticket, {:submit, ops, atomic}, to) do
    bytes = for {_, _, b} <- ops, do: decode_op(b)

    if atomic,
      do: Sequencer.submit_atomic(s.account_id, bytes),
      else: Sequencer.submit(s.account_id, bytes)

    ref = make_ref()
    Process.send_after(self(), {:call_timeout, ref}, @deadline)
    ids = for {id, _, _} <- ops, do: id
    call = %{ticket: ticket, to: to, ops: ids, verdicts: %{}, atomic: atomic}
    pending = Enum.reduce(ids, s.pending, &Map.put(&2, &1, ref))
    %{s | calls: Map.put(s.calls, ref, call), pending: pending}
  end

  defp effect(s, ticket, {:claim, _label, args}, to) do
    {s, claimed} =
      case Lease.claim(s.account_id, s.wire.session.id, JSON.decode!(args)) do
        {:ok, reply} -> {contract(s, reply["bulk"]), %{ok: reply}}
        {:refused, code, data} -> {s, %{error: %{code: to_string(code), data: data}}}
        {:error, reason} -> {s, %{error: %{code: to_string(reason), data: %{}}}}
      end

    resume(s, ticket, %{claimed: claimed}, to)
  end

  defp effect(s, ticket, {:release, ids}, to) do
    {:ok, reply} = Lease.release(s.account_id, s.wire.session.id, ids)
    s = if ids == nil, do: %{s | contract: nil}, else: s
    resume(s, ticket, %{released: %{ok: reply}}, to)
  end

  defp effect(s, ticket, {:blob, type, bytes}, to) do
    stored =
      case Hireme.Blobs.put(s.account_id, bytes, type) do
        {:ok, blob} -> %{ok: blob.sha}
        {:error, why} -> %{error: upload_refusal(why)}
      end

    resume(s, ticket, %{blob: stored}, to)
  end

  defp decode_op(bytes) do
    {:ok, op, ""} = Codec.op(bytes)
    op
  end

  defp verdict(s, op_id, v) do
    case Map.pop(s.pending, op_id) do
      {nil, _} ->
        s

      {ref, pending} ->
        call = s.calls[ref]
        call = %{call | verdicts: Map.put(call.verdicts, op_id, v)}
        s = %{s | pending: pending}

        if map_size(call.verdicts) == length(call.ops),
          do: finish(call, %{s | calls: Map.delete(s.calls, ref)}),
          else: %{s | calls: Map.put(s.calls, ref, call)}
    end
  end

  # Every verdict of a call in op order (none for one past the deadline), and the request steps on.
  defp finish(call, s) do
    verdicts =
      for id <- call.ops do
        case call.verdicts[id] do
          {:ack, a} -> %{ack: [a.rev, a.id]}
          {:nack, n} -> %{nack: [n.code, JSON.decode!(n.data)]}
          nil -> nil
        end
      end

    resume(s, call.ticket, %{submitted: %{verdicts: verdicts, atomic: call.atomic}}, call.to)
  end

  # What the machine asks of this session, as of now.
  defp facts(s, lease) do
    sid = s.wire.session.id
    session = lease.sessions[sid]
    {r, w, d} = s.masks

    JSON.encode!(%{
      masks: [r, w, d],
      account: s.account_id,
      session: sid,
      leased: session != nil and session.channel,
      held: if(session, do: session.held |> Enum.sort(), else: []),
      paused: if(is_map_key(lease.paused, s.key_id), do: ""),
      bulk:
        case s.contract do
          {left, until} -> if now() < until, do: [left, div(until - now(), 1000)]
          _ -> nil
        end,
      rev: s.wire.rev,
      origin: HiremeWeb.Endpoint.url(),
      server: ["hireme", to_string(Application.spec(:hireme, :vsn))],
      next_op: s.next_op
    })
  end

  # The step's ledger on the bulk contract: writes drawn for a burst, or the lease gone.
  defp drawn(_contract, _drawn, {:lost, _}), do: nil
  defp drawn({left, until}, drawn, _), do: {left - drawn, until}
  defp drawn(contract, _drawn, _), do: contract

  defp contract(s, %{"writes" => n}) when is_integer(n),
    do: %{s | contract: {n, now() + :timer.minutes(10) - 1_000}}

  defp contract(s, _), do: s

  defp reply(%{from: nil}, _answer), do: :ok
  defp reply(%{listen: true} = to, answer), do: GenServer.reply(to.from, {:ok, answer})
  defp reply(to, answer), do: GenServer.reply(to.from, answer)

  defp rpc_error(to, message), do: Mcp.error(to.id, -32_603, message)

  defp upload_refusal(:too_large), do: "a CV file is at most 10 MiB"
  defp upload_refusal(:cap), do: "the account already holds 1000 CV files"
  defp upload_refusal(other), do: "the upload failed (#{inspect(other)})"

  defp watch_stream(s, stream) do
    ref = Process.monitor(stream)
    streaming(s.id, 1)
    sink = s.sinks + 1
    {sink, %{s | sinks: sink, streams: Map.put(s.streams, ref, {stream, sink})}}
  end

  # What eviction reads (`make_room/1`): when the session last served, and
  # how many event streams it has open.
  defp used(s) do
    t = now()
    Registry.update_value(@registry, {:id, s.id}, fn {k, _, n} -> {k, t, n} end)
    %{s | used: t}
  end

  defp streaming(sid, d),
    do: Registry.update_value(@registry, {:id, sid}, fn {k, t, n} -> {k, t, n + d} end)

  defp now, do: System.monotonic_time(:millisecond)
end
