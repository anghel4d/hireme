defmodule HiremeWeb.Session do
  @moduledoc """
  One wire session per browser tab or agent: HELLO, the masks, the initial
  train, OPS, RPC, liveness and BYE (`docs/rebuild.md`, "Wire v2").

  A session is carrier-neutral. The process hosting it (the `/wire`
  WebSocket through `WebSock`, or a WebTransport connection from the
  gate) calls `open/1` once, `frame/2` with every whole frame the peer
  sends, and `info/2` with every other message it receives; each answers
  `{:ok, state}`, `{:push, frames, state}` or `{:stop, reason, frames,
  state}` (send the frames, then close). The hosting process is the
  subscriber of the account's sequencer and of its PubSub topic.

  - HELLO first, within 10 s. A ticket (a browser) needs an allowed
    `Origin` and makes the operator's session; a key makes a session bounded
    by the key's masks. Any failure is a `BYE revoked` and the end.
  - WELCOME, then the initial train from the sequencer (a BOOT, or a PATCH
    when the snapshot is current), its last frame flagged END.
  - OPS go to the sequencer; ACK and NACK come back after the PATCH that
    carries the writes.
  - RPC: `schema`, `find`, `get`, `history`, `text` (`Hireme.World`),
    `lease.claim`, `lease.release` (`Hireme.Lease`), `account.*`
    (`HiremeWeb.Account`, browser sessions only; `account.watch` is parked
    and answered `{changed: true}` at the account's next audited change).
  - Liveness: a PING every 15 s each way; 45 s without any frame from the
    peer ends the session, and with it the lease.
  - A key revoked or its masks changed, the session revoked, the account
    suspended, or the node draining: a BYE with the reason, then the end.

  The session never touches a table.
  """

  @behaviour WebSock

  require Logger
  alias Hireme.{Grants, Lease, Security, Sequencer}
  alias HiremeWeb.Wire.Codec

  @hello_ms 10_000
  @world ~w(schema find get history text)
  @tick_ms 60_000

  # --------------------------------------------------- carrier-neutral

  @doc "A new session for a peer: `%{peer_ip, origin, carrier}`."
  def open(peer) when is_map(peer) do
    Process.send_after(self(), {__MODULE__, :hello_deadline}, @hello_ms)

    # One address holds at most this many wire sessions, authenticated or
    # not; the one past it is told to retry (it is never refused at open).
    counted = Security.peer(to_string(peer[:peer_ip] || ""))
    {:ok, _} = Registry.register(HiremeWeb.Session.Peers, counted, nil)

    if Registry.count_match(HiremeWeb.Session.Peers, counted, :_) >
         Security.wire_sessions_per_peer(),
       do: send(self(), {__MODULE__, :too_many})

    Phoenix.PubSub.subscribe(Hireme.PubSub, "wire:drain")

    {:ok,
     %{
       peer: peer,
       phase: :hello,
       last_in: now_ms(),
       account_id: nil,
       session: nil,
       rev: 0,
       parked: nil,
       sequencer: nil,
       touched: now_ms()
     }}
  end

  @doc "One whole frame from the peer."
  # Whatever goes wrong inside a frame ends this session and nothing else,
  # and the log never holds the frame: a HELLO carries an API key.
  def frame(bin, state) do
    handle_frame(bin, state)
  rescue
    e ->
      Logger.error("wire session: a #{inspect(e.__struct__)} handling a frame")
      {:stop, :internal, [], state}
  catch
    :exit, _reason ->
      Logger.error("wire session: an exit handling a frame")
      {:stop, :internal, [], state}
  end

  defp handle_frame(bin, state) do
    state = %{state | last_in: now_ms()}

    case Codec.decode(bin, Codec.max_up()) do
      {:ok, kind, _flags, _rev, body} when kind in [:OPS, :RPC] and state.phase == :live ->
        on_frame(kind, body, active(state, state.last_in))

      {:ok, kind, _flags, _rev, body} ->
        on_frame(kind, body, state)

      {:error, :hash} ->
        bye(:schema, "the wire changed; reload", state)

      {:error, reason} ->
        {:stop, {:protocol, reason}, [], state}
    end
  end

  @doc "Any other message the hosting process received."
  def info({:sequencer, :patch, rev, body}, %{phase: :live} = state),
    do: {:push, [Codec.frame(:PATCH, rev, body, end: true, deflate: true)], %{state | rev: rev}}

  def info({:sequencer, :verdicts, rev, acks, nacks}, %{phase: :live} = state) do
    frames =
      if(acks == [], do: [], else: [Codec.acks(rev, acks)]) ++
        if(nacks == [], do: [], else: [Codec.nacks(rev, nacks)])

    {:push, frames, %{state | rev: rev}}
  end

  def info({:bye, {:key, id}, reason}, %{session: %{key_id: id}} = state) when id != nil,
    do: bye(reason, "", state)

  def info({:bye, {:session, id}, reason}, %{session: %{session_id: id}} = state) when id != nil,
    do: bye(reason, "", state)

  def info({:bye, :account, reason}, %{phase: :live} = state), do: bye(reason, "", state)

  # An audited change (a factor enrolled, a session revoked) re-checks the
  # credential at once, not at the next tick; then wakes a parked watch.
  def info({Hireme.Audit, :changed}, %{phase: :live} = state) do
    cond do
      not credential_live?(state.session) ->
        bye(:revoked, "credential lapsed", state)

      state.parked ->
        {:push, [reply(state.parked, true, %{changed: true}, state)], %{state | parked: nil}}

      true ->
        {:ok, state}
    end
  end

  def info({__MODULE__, :too_many}, state),
    do: bye(:restart, "too many sessions from this address; retry later", state)

  def info({__MODULE__, :hello_deadline}, %{phase: :hello} = state),
    do: {:stop, :hello_deadline, [], state}

  def info({__MODULE__, :ping}, %{phase: :live} = state) do
    if now_ms() - state.last_in > Security.carrier_timeout() do
      {:stop, :carrier_timeout, [], state}
    else
      Process.send_after(self(), {__MODULE__, :ping}, Security.ping_interval())
      {:push, [Codec.ping(:PING, now_ms())], state}
    end
  end

  # Each tick re-checks the credential the session stands on: a browser
  # session's lifetime, idle limit and revocation (and wire activity counts
  # as its activity), a key's expiry. A lapsed one ends the session.
  def info({__MODULE__, :tick}, %{phase: :live} = state) do
    if credential_live?(state.session) do
      Process.send_after(self(), {__MODULE__, :tick}, @tick_ms)
      {:push, [Codec.frame(:TICK, state.rev, clock(), end: true)], state}
    else
      bye(:revoked, "credential lapsed", state)
    end
  end

  def info(:drain, state), do: bye(:restart, "the node is restarting", state)

  def info({:sequencer, :lost}, state),
    do: bye(:restart, "the account lost track of this session; reconnect", state)

  def info({:DOWN, ref, :process, _, _}, %{sequencer: ref} = state),
    do: bye(:restart, "the account restarted; reconnect", state)

  def info(_msg, state), do: {:ok, state}

  # ------------------------------------------------------------ frames

  defp on_frame(:HELLO, body, %{phase: :hello} = state) do
    with {:ok, hello} <- Codec.hello(body),
         {:ok, who} <- authenticate(hello, state.peer) do
      live(hello, who, state)
    else
      # A throttled peer may come back; a bad credential may not.
      {:error, :rate_limited} -> bye(:restart, "rate limited; retry in a minute", state)
      _ -> bye(:revoked, "credential", state)
    end
  end

  defp on_frame(_kind, _body, %{phase: :hello} = state),
    do: {:stop, {:protocol, :hello_first}, [], state}

  defp on_frame(:OPS, body, state) do
    case Codec.ops(body) do
      {:ok, []} ->
        {:ok, state}

      {:ok, ops} ->
        Sequencer.submit(state.account_id, ops)
        {:ok, state}

      {:error, reason} ->
        {:stop, {:protocol, reason}, [], state}
    end
  end

  defp on_frame(:PING, body, state) do
    case Codec.nonce(body) do
      {:ok, n} -> {:push, [Codec.ping(:PONG, n)], state}
      _ -> {:stop, {:protocol, :ping}, [], state}
    end
  end

  defp on_frame(:PONG, _body, state), do: {:ok, state}

  defp on_frame(:RPC, body, state) do
    case Codec.rpc(body) do
      {:ok, id, method, json} ->
        case params(json) do
          {:ok, params} ->
            case metered(method, state) do
              :ok ->
                rpc(id, method, params, state)

              {:error, retry_ms} ->
                {:push, [reply(id, false, error(:rate, %{retry_ms: retry_ms}), state)], state}
            end

          :error ->
            {:push,
             [reply(id, false, error(:type, %{reason: "params are a JSON object"}), state)],
             state}
        end

      {:error, _} ->
        {:stop, {:protocol, :rpc}, [], state}
    end
  end

  # Down frames sent up, or a kind with no meaning up.
  defp on_frame(kind, _body, state), do: {:stop, {:protocol, kind}, [], state}

  # Real activity from a browser (ops, RPC) counts against its idle limit,
  # touched at most once a minute.
  defp active(%{session: %{key_id: nil, session_id: id}} = state, now) when is_integer(id) do
    if now - state.touched > 60_000 do
      Hireme.Accounts.live_session(id)
      %{state | touched: now}
    else
      state
    end
  end

  defp active(state, _now), do: state

  # A key's reads (and lease requests) are metered like its writes.
  defp metered(method, %{session: %{key_id: key_id}}) when key_id != nil do
    if method in @world or String.starts_with?(method, "lease."),
      do: Security.hit(:agent_read, key_id, 1),
      else: :ok
  end

  defp metered(_method, _state), do: :ok

  defp params(""), do: {:ok, %{}}

  defp params(json) do
    case JSON.decode(json) do
      {:ok, %{} = p} -> {:ok, p}
      _ -> :error
    end
  end

  # ------------------------------------------------------------- HELLO

  defp authenticate(%{cred: :ticket, credential: ticket, label: label}, peer) do
    with true <- allowed_origin?(peer[:origin]),
         {:ok, %{account_id: account_id, session_id: session_id}} <-
           Hireme.Accounts.redeem_ticket(ticket) do
      {:ok,
       %{
         account_id: account_id,
         session_id: session_id,
         key_id: nil,
         grants: Grants.operator(),
         label: label(label, "browser")
       }}
    else
      _ -> :error
    end
  end

  defp authenticate(%{cred: :key, credential: secret, label: label}, peer) do
    ip = to_string(peer[:peer_ip] || "")

    case Hireme.Keys.authenticate(secret, ip) do
      {:ok, key} ->
        # A connect loop is bounded per key, before anything is audited.
        if Security.limit(:key_hello, key.id) != :ok, do: throw(:rate_limited)
        meta = %{key: key.key_id, label: label(label, key.name), carrier: peer[:carrier]}

        Hireme.Audit.record(:wire_key, meta, %{
          account_id: key.account_id,
          key_id: key.id,
          ip: ip,
          user_agent: peer[:user_agent]
        })

        {:ok,
         %{
           account_id: key.account_id,
           session_id: nil,
           key_id: key.id,
           grants: Grants.key(key),
           label: label(label, key.name)
         }}

      # A failed key is audited with its peer; how many is bounded by the
      # api_key_peer limit, past which the answer is rate_limited, not audited.
      :error ->
        # Past the global refusal budget a refused key is still refused,
        # only no longer recorded.
        if Security.limit(:refusal_global, :all) == :ok,
          do:
            Hireme.Audit.record(:wire_key_refused, %{carrier: peer[:carrier]}, %{
              ip: ip,
              user_agent: peer[:user_agent]
            })

        :error

      refused ->
        refused
    end
  catch
    :rate_limited -> {:error, :rate_limited}
  end

  defp authenticate(_, _), do: :error

  # The tick only looks: idle time is the browser's own activity, not the
  # session's clock (that touch is in `active/2`).
  defp credential_live?(%{key_id: nil, session_id: id}), do: Hireme.Accounts.session_live?(id)

  defp credential_live?(%{key_id: key_id, account_id: account_id}),
    do: Hireme.Keys.usable?(key_id, account_id)

  defp allowed_origin?(nil), do: false

  defp allowed_origin?(origin),
    do: String.trim_trailing(origin, "/") in HiremeWeb.Endpoint.origins()

  # A label is shown to the operator and to other agents (leases, refusals):
  # control characters (newlines, escapes) are dropped so it cannot pose as
  # anything but a name.
  defp label(given, fallback) do
    case given
         |> String.replace(~r/[\p{Cc}\p{Cf}]/u, " ")
         |> String.trim()
         |> String.slice(0, 64) do
      "" -> fallback
      l -> l
    end
  end

  defp live(hello, who, state) do
    Phoenix.PubSub.subscribe(Hireme.PubSub, Hireme.Audit.topic(who.account_id))
    session = Map.put(who, :id, System.unique_integer([:positive, :monotonic]))

    case Sequencer.subscribe(
           who.account_id,
           session
           |> Map.take([:id, :label, :grants, :key_id, :session_id])
           |> Map.merge(%{ip: state.peer[:peer_ip], user_agent: state.peer[:user_agent]}),
           # A snapshot taken under another schema is no base for a PATCH.
           if(hello.schema_rev == Hireme.Schema.schema_rev(), do: hello.snapshot_rev, else: 0)
         ) do
      {:ok, joined} ->
        welcome(joined, who, session, state)

      {:error, :too_many} ->
        bye(:restart, "this key holds as many sessions as it may; retry later", state)

      {:error, _} ->
        bye(:restart, "the account is unavailable; retry", state)
    end
  end

  defp welcome(%{rev: rev, lease: lease, frames: train, pid: sequencer}, who, session, state) do
    welcome =
      Codec.welcome(rev, %{
        account_id: who.account_id,
        session_id: session.id,
        schema_rev: Hireme.Schema.schema_rev(),
        read_mask: who.grants.read_mask,
        write_mask: who.grants.write_mask,
        may_delete: who.grants.may_delete,
        lease: lease,
        label: session.label
      })

    Process.send_after(self(), {__MODULE__, :ping}, Security.ping_interval())
    Process.send_after(self(), {__MODULE__, :tick}, @tick_ms)
    # A restarted sequencer has forgotten this session; the client reconnects.
    ref = Process.monitor(sequencer)

    state = %{
      state
      | phase: :live,
        account_id: who.account_id,
        session: session,
        rev: rev,
        sequencer: ref
    }

    {:push, [welcome | train], state}
  end

  # --------------------------------------------------------------- RPC

  defp rpc(id, method, params, state) when method in @world do
    ctx = %{account_id: state.account_id, grants: state.session.grants}

    case Hireme.World.call(method, params, ctx) do
      {:ok, result} -> {:push, [reply(id, true, result, state)], state}
      {:error, refusal, data} -> {:push, [reply(id, false, error(refusal, data), state)], state}
    end
  end

  defp rpc(id, "lease.claim", params, state) do
    with :ok <- claim_shape(params),
         :ok <- claim_grants(params, state.session.grants) do
      answer(id, Lease.claim(state.account_id, state.session.id, params), state)
    else
      {:refused, refusal, data} -> {:push, [reply(id, false, error(refusal, data), state)], state}
    end
  end

  defp rpc(id, "lease.release", params, state) do
    ids = params["ids"]

    if ids == nil or (is_list(ids) and Enum.all?(ids, &is_integer/1)),
      do: answer(id, Lease.release(state.account_id, state.session.id, ids), state),
      else: {:push, [reply(id, false, error(:type, %{column: "ids"}), state)], state}
  end

  defp rpc(id, "account." <> _ = method, params, state) do
    ctx = %{
      account_id: state.account_id,
      session_id: state.session.session_id,
      key: if(state.session.key_id, do: %{id: state.session.key_id}),
      ip: state.peer[:peer_ip],
      user_agent: state.peer[:user_agent]
    }

    case HiremeWeb.Account.call(method, params, ctx) do
      {:ok, result} -> {:push, [reply(id, true, result, state)], state}
      {:error, err} -> {:push, [reply(id, false, err, state)], state}
      {:park, :account} -> park(id, state)
    end
  end

  defp rpc(id, method, _params, state),
    do: {:push, [reply(id, false, error(:not_found, %{method: method}), state)], state}

  # `{count, stage?}`, `{ids}` or `{}`, each of its type.
  defp claim_shape(params) do
    ok =
      Enum.all?(params, fn
        {"count", n} ->
          is_integer(n) and n >= 0

        {"ids", ids} ->
          is_list(ids) and length(ids) <= 1_000 and Enum.all?(ids, &(is_integer(&1) and &1 > 0))

        {"stage", st} ->
          is_binary(st) and Codec.enum_code("stage", st) != nil

        _ ->
          false
      end)

    if ok, do: :ok, else: {:refused, :type, %{expected: "{count, stage?} | {ids} | {}"}}
  end

  # The channel is for writing: a key with no write bit may not take it, and
  # only one that writes the desk may claim applications.
  defp claim_grants(params, grants) do
    claims = params["count"] not in [nil, 0] or params["ids"] not in [nil, []]

    cond do
      grants.write_mask == 0 ->
        {:refused, :scope, %{reason: "the lease is for writing"}}

      # Claiming ranks and names applications: it needs the desk both ways.
      claims and
          not (Grants.write?(grants, Hireme.Schema.table(:applications)) and
                   Grants.read?(grants, Hireme.Schema.table(:applications))) ->
        {:refused, :scope, %{table: "applications"}}

      true ->
        :ok
    end
  end

  # account.watch goes through HiremeWeb.Account first (it answers at once
  # when the audit cursor has moved past `since`); only then is it parked.
  # One parked watch per browser session: a new one answers the old.
  defp park(id, %{session: %{key_id: nil}} = state) do
    old = if state.parked, do: [reply(state.parked, true, %{changed: false}, state)], else: []
    {:push, old, %{state | parked: id}}
  end

  defp park(id, state), do: {:push, [reply(id, false, error(:scope, %{}), state)], state}

  defp answer(id, {:ok, result}, state), do: {:push, [reply(id, true, result, state)], state}
  defp answer(id, :ok, state), do: {:push, [reply(id, true, %{}, state)], state}

  defp answer(id, {:refused, refusal, data}, state),
    do: {:push, [reply(id, false, error(refusal, data), state)], state}

  defp answer(id, {:error, reason}, state),
    do: {:push, [reply(id, false, error(reason, %{}), state)], state}

  defp error(refusal, data), do: %{code: refusal, message: to_string(refusal), data: data}

  defp reply(id, ok?, result, state), do: Codec.reply(state.rev, id, ok?, JSON.encode!(result))

  # --------------------------------------------------------------- BYE

  defp bye(reason, message, state),
    do: {:stop, {:bye, reason}, [Codec.bye(state.rev, reason, message)], state}

  defp clock do
    t = Hireme.Schema.table(:clock)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Codec.rows_block(t, t.cols, [%{today: DateTime.to_date(now), now: now}])
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # ------------------------------------------------------- WebSock host

  @impl WebSock
  def init(peer) when is_map(peer), do: peer |> Map.put(:carrier, :ws) |> open() |> ws()

  @impl WebSock
  def handle_in({bin, opcode: :binary}, state), do: bin |> frame(state) |> ws()
  def handle_in({_text, opcode: :text}, state), do: ws({:stop, {:protocol, :text}, [], state})

  @impl WebSock
  def handle_info(msg, state), do: msg |> info(state) |> ws()

  @impl WebSock
  def terminate(_reason, _state), do: :ok

  defp ws({:ok, state}), do: {:ok, state}
  defp ws({:push, [], state}), do: {:ok, state}
  defp ws({:push, frames, state}), do: {:push, Enum.map(frames, &{:binary, &1}), state}

  defp ws({:stop, {:bye, _}, frames, state}),
    do: {:stop, :normal, 1000, Enum.map(frames, &{:binary, &1}), state}

  defp ws({:stop, reason, frames, state}),
    do: {:stop, :normal, close_code(reason), Enum.map(frames, &{:binary, &1}), state}

  defp close_code({:protocol, _}), do: 1002
  defp close_code(_), do: 1000
end

defmodule HiremeWeb.Session.Drain do
  @moduledoc """
  The last child of the node: on shutdown, before anything under it
  stops, every wire session is told `BYE restart` and given up to 5 s to
  go; then shutdown continues and the gate stops after it.
  """

  use GenServer

  @grace_ms 5_000

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl GenServer
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, nil}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    Phoenix.PubSub.broadcast(Hireme.PubSub, "wire:drain", :drain)
    wait(System.monotonic_time(:millisecond) + @grace_ms)
  end

  # Sessions leave the drain topic as they exit.
  defp wait(deadline) do
    if Registry.count_match(Hireme.PubSub, "wire:drain", :_) > 0 and
         System.monotonic_time(:millisecond) < deadline do
      Process.sleep(50)
      wait(deadline)
    end

    :ok
  end

  def child_spec(arg),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, shutdown: @grace_ms + 1_000}
end
