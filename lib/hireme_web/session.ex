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

  alias Hireme.{Grants, Lease, Security, Sequencer}
  alias HiremeWeb.Wire.Codec

  @hello_ms 10_000
  @tick_ms 60_000

  # --------------------------------------------------- carrier-neutral

  @doc "A new session for a peer: `%{peer_ip, origin, carrier}`."
  def open(peer) when is_map(peer) do
    Process.send_after(self(), {__MODULE__, :hello_deadline}, @hello_ms)
    Phoenix.PubSub.subscribe(Hireme.PubSub, "wire:drain")
    {:ok, %{peer: peer, phase: :hello, last_in: now_ms(), account_id: nil, session: nil, rev: 0, parked: nil}}
  end

  @doc "One whole frame from the peer."
  def frame(bin, state) do
    state = %{state | last_in: now_ms()}

    case Codec.decode(bin) do
      {:ok, kind, _flags, _rev, body} -> on_frame(kind, body, state)
      {:error, :hash} -> bye(:schema, "the wire changed; reload", state)
      {:error, reason} -> {:stop, {:protocol, reason}, [], state}
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

  def info({Hireme.Audit, :changed}, %{parked: id} = state) when id != nil,
    do: {:push, [reply(id, true, %{changed: true}, state)], %{state | parked: nil}}

  def info({__MODULE__, :hello_deadline}, %{phase: :hello} = state), do: {:stop, :hello_deadline, [], state}

  def info({__MODULE__, :ping}, %{phase: :live} = state) do
    if now_ms() - state.last_in > Security.carrier_timeout() do
      {:stop, :carrier_timeout, [], state}
    else
      Process.send_after(self(), {__MODULE__, :ping}, Security.ping_interval())
      {:push, [Codec.ping(:PING, now_ms())], state}
    end
  end

  def info({__MODULE__, :tick}, %{phase: :live} = state) do
    Process.send_after(self(), {__MODULE__, :tick}, @tick_ms)
    {:push, [Codec.frame(:TICK, state.rev, clock(), end: true)], state}
  end

  def info(:drain, state), do: bye(:restart, "the node is restarting", state)

  def info(_msg, state), do: {:ok, state}

  # ------------------------------------------------------------ frames

  defp on_frame(:HELLO, body, %{phase: :hello} = state) do
    with {:ok, hello} <- Codec.hello(body),
         {:ok, who} <- authenticate(hello, state.peer) do
      live(hello, who, state)
    else
      _ -> bye(:revoked, "credential", state)
    end
  end

  defp on_frame(_kind, _body, %{phase: :hello} = state), do: {:stop, {:protocol, :hello_first}, [], state}

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
          {:ok, params} -> rpc(id, method, params, state)
          :error -> {:push, [reply(id, false, error(:type, %{reason: "params are a JSON object"}), state)], state}
        end

      {:error, _} ->
        {:stop, {:protocol, :rpc}, [], state}
    end
  end

  # Down frames sent up, or a kind with no meaning up.
  defp on_frame(kind, _body, state), do: {:stop, {:protocol, kind}, [], state}

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
         {:ok, %{account_id: account_id, session_id: session_id}} <- Hireme.Accounts.redeem_ticket(ticket) do
      {:ok, %{account_id: account_id, session_id: session_id, key_id: nil, grants: Grants.operator(), label: label(label, "browser")}}
    else
      _ -> :error
    end
  end

  defp authenticate(%{cred: :key, credential: secret, label: label}, peer) do
    case Hireme.Keys.authenticate(secret, to_string(peer[:peer_ip] || "")) do
      {:ok, key} ->
        {:ok, %{account_id: key.account_id, session_id: nil, key_id: key.id, grants: Grants.key(key), label: label(label, key.name)}}

      :error ->
        :error
    end
  end

  defp authenticate(_, _), do: :error

  defp allowed_origin?(nil), do: false
  defp allowed_origin?(origin), do: String.trim_trailing(origin, "/") in HiremeWeb.Endpoint.origins()

  defp label(given, fallback) do
    case String.slice(String.trim(given), 0, 64) do
      "" -> fallback
      l -> l
    end
  end

  defp live(hello, who, state) do
    Phoenix.PubSub.subscribe(Hireme.PubSub, "account:#{who.account_id}")
    session = Map.put(who, :id, System.unique_integer([:positive, :monotonic]))

    {:ok, %{rev: rev, lease: lease, frames: train}} =
      Sequencer.subscribe(who.account_id, Map.take(session, [:id, :label, :grants, :key_id, :session_id]), hello.snapshot_rev)

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
    state = %{state | phase: :live, account_id: who.account_id, session: session, rev: rev}
    {:push, [welcome | train], state}
  end

  # --------------------------------------------------------------- RPC

  @world ~w(schema find get history text)

  defp rpc(id, method, params, state) when method in @world do
    ctx = %{account_id: state.account_id, grants: state.session.grants}

    case Hireme.World.call(method, params, ctx) do
      {:ok, result} -> {:push, [reply(id, true, result, state)], state}
      {:error, refusal, data} -> {:push, [reply(id, false, error(refusal, data), state)], state}
    end
  end

  defp rpc(id, "lease.claim", params, state) do
    answer(id, Lease.claim(state.account_id, state.session.id, params), state)
  end

  defp rpc(id, "lease.release", params, state) do
    ids = params["ids"]

    if ids == nil or (is_list(ids) and Enum.all?(ids, &is_integer/1)),
      do: answer(id, Lease.release(state.account_id, state.session.id, ids), state),
      else: {:push, [reply(id, false, error(:type, %{column: "ids"}), state)], state}
  end

  defp rpc(id, "account.watch", _params, %{session: %{key_id: nil}} = state) do
    old = if state.parked, do: [reply(state.parked, true, %{changed: false}, state)], else: []
    {:push, old, %{state | parked: id}}
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
      {:park, :account} -> rpc(id, "account.watch", params, state)
    end
  end

  defp rpc(id, method, _params, state),
    do: {:push, [reply(id, false, error(:not_found, %{method: method}), state)], state}

  defp answer(id, {:ok, result}, state), do: {:push, [reply(id, true, result, state)], state}
  defp answer(id, :ok, state), do: {:push, [reply(id, true, %{}, state)], state}
  defp answer(id, {:refused, refusal, data}, state), do: {:push, [reply(id, false, error(refusal, data), state)], state}
  defp answer(id, {:error, reason}, state), do: {:push, [reply(id, false, error(reason, %{}), state)], state}

  defp error(refusal, data), do: %{code: refusal, message: to_string(refusal), data: data}

  defp reply(id, ok?, result, state), do: Codec.reply(state.rev, id, ok?, JSON.encode!(result))

  # --------------------------------------------------------------- BYE

  defp bye(reason, message, state), do: {:stop, {:bye, reason}, [Codec.bye(state.rev, reason, message)], state}

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
  defp ws({:stop, {:bye, _}, frames, state}), do: {:stop, :normal, 1000, Enum.map(frames, &{:binary, &1}), state}
  defp ws({:stop, reason, frames, state}), do: {:stop, :normal, close_code(reason), Enum.map(frames, &{:binary, &1}), state}

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
    if Registry.count_match(Hireme.PubSub, "wire:drain", :_) > 0 and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(50)
      wait(deadline)
    end

    :ok
  end

  def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, shutdown: @grace_ms + 1_000}
end
