defmodule HiremeWeb.Session do
  @moduledoc """
  One live connection to the desk, whatever carries it.

  A session is hosted by the process that owns its connection: the gate's
  connection process for WebTransport (`HiremeWeb.Gate`), Phoenix's socket
  process for the WebSocket fallback (`HiremeWeb.WireSocket`). The host
  feeds it carrier events and every other message it receives, and the
  session writes back through the carrier module's functions, so a frame
  costs no hop between processes.

  What travels is the account's raw rows (`priv/wire/schema.txt`): the
  browser holds them in memory and derives every view itself, so the
  server never computes one for it. A BOOT carries every table (or, for
  a snapshot the sequencer's ring still covers, the revisions since);
  each write's delta carries the rows it changed.

  Streams: client bidi 0 is control (HELLO, OPs and account RPC up;
  BOOT, PATCH, ACK, NACK and RPC replies down, in one order, so a PATCH
  always lands before the ACK of the op that caused it). Other client
  bidi streams are reset.

  An agent's session is the agent's one process on the server, and it
  holds the agent's leases itself (`Hireme.Letterbox`): a lease is a lane
  of control, numbered by the frames' header `rev`. LEASE takes a job,
  OPs on the lane write that job and nothing else, BYE gives it back;
  the key being revoked or the session ending gives back every lease.

  Order: `Hireme.Ops` serializes every write per account and broadcasts
  `{:ops_delta, rev, delta}` before it answers. A delta at or below the
  session's rev is dropped; an ACK waits until the delta of its rev has
  gone out.
  """

  require Logger

  alias Hireme.ApiKeys
  alias Hireme.Letterbox
  alias Hireme.Ops
  alias Hireme.Repo
  alias HiremeWeb.Packet

  @control 0
  @agent 0x80
  @end_flag 0x02
  # HELLO's option word: bit 0 asks for raw tables (the client derives every view).
  @raw_opt 0x01
  @ticket_age 60
  @recheck_ms 60_000
  @hello_deadline_ms 5_000
  @max_leases 64
  # The first server-opened uni stream (QUIC ids 4n+3) carries an early BOOT.
  @early_stream 3

  defstruct [
    :carrier,
    :mod,
    :account_id,
    :session_id,
    :agent,
    :peer,
    role: :pending,
    rev: 0,
    hello: false,
    client_id: 0,
    buffer: <<>>,
    acks: [],
    leases: %{},
    raw: false,
    early: false,
    acct_dirty: false
  ]

  # ---- Tickets: how a browser reaches the gate ----

  @doc "A single-use ticket, good for #{@ticket_age} s, for this signed-in browser session."
  @spec ticket(pos_integer(), pos_integer()) :: String.t()
  def ticket(account_id, session_id) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    Phoenix.Token.encrypt(HiremeWeb.Endpoint, "wire ticket", {account_id, session_id, nonce})
  end

  @doc "The account and session a ticket names, once, while that session is live."
  @spec redeem(String.t()) :: {:ok, pos_integer(), pos_integer()} | :error
  def redeem(ticket) when is_binary(ticket) do
    with {:ok, {account_id, session_id, nonce}} <-
           Phoenix.Token.decrypt(HiremeWeb.Endpoint, "wire ticket", ticket, max_age: @ticket_age),
         {:allow, 1} <- Hireme.RateLimit.hit("wire_ticket:" <> nonce, @ticket_age * 2_000, 1),
         true <- live?(account_id, session_id) do
      {:ok, account_id, session_id}
    else
      _ -> :error
    end
  end

  def redeem(_), do: :error

  @doc "Opaque per-account key the browser files its resident snapshot under."
  @spec scope(pos_integer()) :: String.t()
  def scope(account_id) do
    secret = HiremeWeb.Endpoint.config(:secret_key_base)

    :crypto.mac(:hmac, :sha256, secret, "wire scope #{account_id}")
    |> binary_part(0, 12)
    |> Base.encode16(case: :lower)
  end

  defp live?(account_id, session_id) do
    now = DateTime.utc_now()

    case Repo.get(Hireme.Accounts.Session, session_id, skip_account: true) do
      %{account_id: ^account_id, revoked_at: nil, expires_at: expires} ->
        DateTime.compare(now, expires) == :lt

      _ ->
        false
    end
  end

  # ---- Host interface ----

  @doc """
  A session for a carrier. `meta` holds `ip`, `origin` and `path` from the
  gate's CONNECT, or `account_id` and `session_id` from the WebSocket's
  cookie. A browser authenticates here, before anything is allocated;
  an agent (no Origin, no ticket) must send an API-key HELLO first.
  """
  @spec init(term(), map()) :: {:ok, %__MODULE__{}} | {:refuse, 403 | 404}
  def init(carrier, meta) do
    s = %__MODULE__{carrier: carrier, mod: carrier_mod(carrier), peer: Map.get(meta, :ip, "")}

    case meta do
      %{account_id: account_id, session_id: session_id} ->
        {:ok, browser(s, account_id, session_id)}

      %{path: path, origin: origin} ->
        query = URI.decode_query(URI.parse(path).query || "")

        cond do
          not String.starts_with?(URI.parse(path).path || "", "/wt") -> {:refuse, 404}
          origin == "" and not Map.has_key?(query, "t") -> {:ok, pending(s)}
          not allowed_origin?(origin) -> {:refuse, 403}
          true -> by_ticket(s, query)
        end
    end
  end

  # An agent proves itself with its HELLO; one that never does is closed.
  defp pending(s) do
    Process.send_after(self(), {__MODULE__, :hello_deadline}, @hello_deadline_ms)
    s
  end

  # A ticketed browser is authenticated before ACCEPT, so the gate lifts
  # its pre-HELLO caps and deadline at once.
  defp by_ticket(s, query) do
    case redeem(query["t"]) do
      {:ok, account_id, session_id} ->
        s.mod.ready(s.carrier)
        {:ok, s |> browser(account_id, session_id) |> early(query)}

      :error ->
        {:refuse, 403}
    end
  end

  # A browser that names its snapshot and asks for raw tables in the
  # CONNECT query gets its BOOT pushed on a stream of the server's own the
  # moment it is accepted, a round trip before it could send HELLO; its
  # HELLO then only opens control.
  defp early(s, %{"raw" => "1"} = query) do
    snapshot = int_param(query["rev"])
    send(self(), {__MODULE__, :early_boot, snapshot})
    %{s | raw: true, client_id: int_param(query["cid"])}
  end

  defp early(s, _query), do: s

  defp int_param(value) do
    case Integer.parse(value || "") do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  defp browser(s, account_id, session_id) do
    Repo.put_account(account_id)
    Process.send_after(self(), {__MODULE__, :recheck}, @recheck_ms)
    %{s | role: :browser, account_id: account_id, session_id: session_id}
  end

  defp allowed_origin?(origin) do
    allowed = Application.get_env(:hireme, :wire_origins) || [HiremeWeb.Endpoint.url()]
    origin in allowed
  end

  defp carrier_mod(%mod{}), do: mod
  defp carrier_mod({mod, _}), do: mod

  @doc "One carrier event: a stream opened, bytes, a FIN, a reset, a datagram, or the end."
  @spec event(tuple(), %__MODULE__{}) :: {:ok, %__MODULE__{}} | {:stop, term(), %__MODULE__{}}
  def event({:stream, @control}, s), do: {:ok, s}

  def event({:stream, id}, s), do: reset(s, id)

  def event({:data, @control, bytes}, s) do
    case Packet.split(s.buffer <> bytes) do
      {:ok, frames, rest} -> frames(frames, %{s | buffer: rest})
      {:error, reason} -> bye(s, Atom.to_string(reason))
    end
  end

  def event({:data, _id, _bytes}, s), do: {:ok, s}

  def event({:fin, @control}, s), do: {:stop, :normal, s}
  def event({:reset, @control, _}, s), do: {:stop, :normal, s}

  def event({tag, id, _}, s) when tag in [:reset, :stop], do: event({:fin, id}, s)

  def event({:fin, _id}, s), do: {:ok, s}

  def event({:dgram, bytes}, s) do
    case Packet.split(bytes) do
      {:ok, frames, _} -> frames(frames, s)
      {:error, _} -> {:ok, s}
    end
  end

  def event({:closed, _code, _reason}, s), do: {:stop, :normal, s}

  @doc "Any other message the host received: deltas, account changes, key revocations, timers."
  @spec info(term(), %__MODULE__{}) :: {:ok, %__MODULE__{}} | {:stop, term(), %__MODULE__{}}
  def info({:ops_delta, rev, _delta}, %{rev: seen} = s) when rev <= seen, do: {:ok, s}

  def info({:ops_delta, rev, delta}, %{hello: true, raw: true} = s),
    do: {:ok, raw_patch(s, rev, delta)}

  # Account changes from elsewhere (a sign-in, a revoke, a factor) arrive in
  # bursts; one re-push covers them all.
  def info({Hireme.Audit, :changed}, %{acct_dirty: true} = s), do: {:ok, s}

  def info({Hireme.Audit, :changed}, %{hello: true, raw: true} = s) do
    send(self(), {__MODULE__, :acct_push})
    {:ok, %{s | acct_dirty: true}}
  end

  def info({__MODULE__, :acct_push}, s) do
    control(s, Packet.frame(:patch, s.rev, account_tables(s)))
    {:ok, %{s | acct_dirty: false}}
  end

  def info({:ops_delta, _, _}, s), do: {:ok, s}

  def info({__MODULE__, :tick}, %{hello: true} = s) do
    control(s, Packet.frame(:tick, s.rev, clock()))
    schedule_tick()
    {:ok, s}
  end

  def info({__MODULE__, :hello_deadline}, %{hello: false} = s), do: bye(s, "hello")

  def info({__MODULE__, :early_boot, snapshot}, %{hello: false} = s) do
    id = @early_stream
    s.mod.open_uni(s.carrier, id)
    s = start(s, snapshot, &s.mod.send(s.carrier, id, &1))
    s.mod.fin(s.carrier, id)
    {:ok, %{s | early: true}}
  end

  def info({__MODULE__, :recheck}, %{role: :browser} = s) do
    if live?(s.account_id, s.session_id) do
      Process.send_after(self(), {__MODULE__, :recheck}, @recheck_ms)
      {:ok, s}
    else
      bye(s, "signed_out")
    end
  end

  def info(:api_key_dead, %{role: :agent} = s), do: bye(s, "revoked")

  def info({__MODULE__, :recheck}, %{role: :agent, agent: agent} = s) do
    if ApiKeys.usable?(agent.key_id, agent.account_id) do
      Process.send_after(self(), {__MODULE__, :recheck}, @recheck_ms)
      {:ok, s}
    else
      bye(s, "expired")
    end
  end

  def info(_message, s), do: {:ok, s}

  @doc "The session is ending: an agent's leases go back now, not when the registry notices."
  @spec terminate(term(), %__MODULE__{}) :: :ok
  def terminate(_reason, s) do
    Enum.each(s.leases, fn {_lane, pair} -> Letterbox.release(pair) end)
  end

  # ---- Frames from the client ----

  defp frames([], s), do: {:ok, s}

  defp frames([frame | rest], s) do
    case frame(frame, s) do
      {:ok, s} -> frames(rest, s)
      stop -> stop
    end
  end

  defp frame({:hello, flags, _rev, body}, %{hello: false} = s) do
    with <<cred_len::little-16, rest::binary>> <- body,
         <<cred::binary-size(^cred_len), _::binary>> <- rest,
         skip = align8(2 + cred_len) - 2 - cred_len,
         <<_::binary-size(^skip), _::binary-size(^cred_len), snapshot::little-64,
           client::little-32, opts::little-32,
           _::binary>> <-
           rest do
      s = %{s | raw: Bitwise.band(opts, @raw_opt) != 0}
      hello(s, Bitwise.band(flags, @agent) != 0, cred, snapshot, client)
    else
      _ -> bye(s, "hello")
    end
  end

  # After an early BOOT the browser's HELLO only opens control.
  defp frame({:hello, _, _, _}, %{early: true} = s), do: {:ok, s}
  defp frame({:hello, _, _, _}, s), do: bye(s, "hello")
  defp frame(_frame, %{hello: false} = s), do: bye(s, "hello")

  # An agent's leases are lanes of control (header rev ≥ 1).
  defp frame({:lease, _, lane, <<job_id::little-64, _::binary>>}, %{role: :agent} = s)
       when lane > 0,
       do: lease(s, lane, job_id)

  defp frame({:op, _, lane, body}, %{role: :agent} = s) when lane > 0,
    do: lease_op(s, lane, body)

  defp frame({:bye, _, lane, _}, %{role: :agent} = s) when lane > 0,
    do: {:ok, release(s, lane)}

  defp frame({:op, _, _, body}, %{role: role} = s) when role in [:browser, :agent],
    do: op(s, body)

  defp frame(
         {:rpc, _, _, <<len::little-32, _::32, json::binary-size(len), _::binary>>},
         %{role: :browser} = s
       ),
       do: rpc(s, json)

  defp frame({:ping, _, _, <<t::little-64, _::binary>>}, s) do
    control(
      s,
      Packet.frame(:pong, s.rev, <<t::little-64, System.system_time(:millisecond)::little-64>>)
    )

    {:ok, s}
  end

  defp frame(_frame, s), do: {:ok, s}

  defp hello(%{role: :pending} = s, true, key, _snapshot, client) do
    case Letterbox.agent_key(key, s.peer) do
      {:ok, agent} ->
        Repo.put_account(agent.account_id)
        Phoenix.PubSub.subscribe(Hireme.PubSub, ApiKeys.topic(agent.key_id))
        Process.send_after(self(), {__MODULE__, :recheck}, @recheck_ms)
        s = %{s | role: :agent, agent: agent, account_id: agent.account_id, client_id: client}
        s.mod.ready(s.carrier)

        # An agent is a client like the browser: the same raw BOOT, the
        # same deltas, and it derives its own views from them.
        {:ok, rev, {:boot, %{tables: tables}}} = Ops.attach(agent.account_id, nil)
        s = %{s | rev: rev, hello: true, raw: true}
        boot(&control(s, &1), rev, tables, [])
        {:ok, s}

      :error ->
        bye(s, "key")
    end
  end

  defp hello(%{role: :browser, raw: true} = s, false, _cred, snapshot, client) do
    s.mod.ready(s.carrier)
    {:ok, start(%{s | client_id: client}, snapshot, &control(s, &1))}
  end

  # A browser that does not ask for raw tables runs a bundle from before
  # them; BYE "schema" reloads it onto the current one.
  defp hello(%{role: :browser} = s, false, _cred, _snapshot, _client), do: bye(s, "schema")

  defp hello(s, _agent?, _cred, _snapshot, _client), do: bye(s, "hello")

  # Attach to the account's guild and send the BOOT (or the revisions a
  # known snapshot misses), then a ticket for the next reconnect.
  defp start(s, snapshot, write) do
    Phoenix.PubSub.subscribe(Hireme.PubSub, Hireme.Audit.topic(s.account_id))
    {:ok, rev, snap} = Ops.attach(s.account_id, if(snapshot == 0, do: nil, else: snapshot))
    s = %{s | rev: rev, hello: true}

    case snap do
      {:boot, %{tables: tables}} ->
        boot(write, rev, tables, account_tables(s))

      {:replay, deltas} ->
        for {r, delta} <- deltas, do: write.(Packet.frame(:patch, r, raw_delta(delta)))
        write.(Packet.frame(:patch, rev, [clock(), account_tables(s)], flags: @end_flag))
    end

    write.(Packet.frame(:ticket, rev, sized(ticket(s.account_id, s.session_id))))
    schedule_tick()
    s
  end

  # ---- Raw tables (round two): rows as the database holds them ----

  @raw_tables ~w(job_apps profiles items cv_variants cv_lineages overlays batches events kv_pairs
                 narratives scoreboard_snapshots gym_problems gym_reps net_entries leases)a

  # Every raw table the snapshot holds, then the server's clock.
  @board ~w(job_apps profiles batches cv_variants leases scoreboard_snapshots)a

  # The board first: what the cards are drawn from, without the job
  # listings. The rest (CV items, events, gym and net, the listings)
  # follows at the same rev, so the first paint waits for neither.
  defp boot(write, rev, tables, account) do
    {board, rest} = split_boot(tables)
    body = [Packet.static_lookups(), raw_boot(board), account]
    write.(Packet.frame(:boot, rev, body, deflate: true, flags: @end_flag))
    if rest != [], do: write.(Packet.frame(:patch, rev, rest, deflate: true))
  end

  defp split_boot(tables) do
    jobs =
      Enum.map(
        Map.get(tables, :job_apps, []),
        &if(is_struct(&1), do: Map.from_struct(&1), else: &1)
      )

    board =
      tables |> Map.take(@board) |> Map.put(:job_apps, Enum.map(jobs, &Map.delete(&1, :listing)))

    listings =
      for j <- jobs, Map.get(j, :listing) not in [nil, ""], do: %{id: j.id, listing: j.listing}

    rest =
      for {t, rows} <- Map.drop(tables, @board), rows != [], do: Packet.raw(t, rows)

    {board, if(listings == [], do: rest, else: [rest, Packet.raw(:job_apps, listings)])}
  end

  defp raw_boot(tables) do
    [
      for(t <- @raw_tables, rows = Map.get(tables, t), rows != nil, do: Packet.raw(t, rows)),
      clock()
    ]
  end

  # One delta's raw rows (upserts by id) and deletions.
  defp raw_delta(delta) do
    rows = Map.get(delta, :rows, %{})
    gone = Map.get(delta, :gone, %{})

    [
      for(
        t <- @raw_tables,
        list = Map.get(rows, t),
        list not in [nil, []],
        do: Packet.raw(t, list)
      ),
      case for({t, ids} <- gone, id <- ids, do: %{table: table_id(t), id: id}) do
        [] -> []
        gone_rows -> Packet.table(:gone, gone_rows)
      end
    ]
  end

  defp table_id(name), do: Packet.table_id(name)

  defp clock do
    Packet.table(:clock, [%{today: Date.utc_today(), now: DateTime.utc_now()}])
  end

  # The UTC day turns: every client derivation of "today" moves with it.
  defp schedule_tick do
    now = DateTime.utc_now()
    midnight = DateTime.new!(Date.add(Date.utc_today(), 1), ~T[00:00:00], "Etc/UTC")

    Process.send_after(
      self(),
      {__MODULE__, :tick},
      DateTime.diff(midnight, now, :millisecond) + 50
    )
  end

  # Raw rows out before the ACKs they settle, as with derived cards.
  defp raw_patch(s, rev, delta) do
    # The PATCH and the ACKs it settles leave as one write.
    {due, held} = Enum.split_with(s.acks, fn {r, _, _} -> r <= rev end)
    acks = for {_r, op_id, stamp} <- Enum.reverse(due), do: Packet.ack(op_id, stamp)
    control(s, [Packet.frame(:patch, rev, raw_delta(delta)) | acks])
    %{s | rev: rev, acks: held}
  end

  defp account_tables(s), do: HiremeWeb.Account.tables(s.account_id, s.session_id)

  # An account command (`account/<name>`) as JSON-RPC: a change re-pushes
  # the account's tables before the reply, so the reply lands on current
  # tables; a session that signed itself out hears BYE after its answer.
  defp rpc(s, json) do
    with {:ok, %{"id" => id, "method" => method} = req} <- Jason.decode(json) do
      ctx = %{account_id: s.account_id, session_id: s.session_id, ip: s.peer}

      case HiremeWeb.Account.call(method, req["params"] || %{}, ctx) do
        {:ok, result, changed} ->
          if changed == :changed, do: control(s, Packet.frame(:patch, s.rev, account_tables(s)))
          rpc_reply(s, %{id: id, result: result})
          {:ok, s}

        {:error, code, message} ->
          rpc_reply(s, %{id: id, error: %{code: code, message: message}})
          {:ok, s}

        {:signed_out, result} ->
          rpc_reply(s, %{id: id, result: result})
          bye(s, "signed_out")
      end
    else
      _ -> {:ok, s}
    end
  end

  defp rpc_reply(s, reply), do: control(s, HiremeWeb.Account.rpc_frame(Jason.encode!(reply)))

  # ---- Ops ----

  defp op(s, body) do
    case Packet.op(body) do
      {:ok, op} ->
        case Ops.run(s.account_id, op) do
          {:ok, rev} when rev <= s.rev ->
            ack(s, op.op_id, rev)
            {:ok, s}

          {:ok, rev} ->
            {:ok, %{s | acks: [{rev, op.op_id, rev} | s.acks]}}

          {:error, reason} ->
            control(s, Packet.nack(op.op_id, reason, s.rev))
            {:ok, s}
        end

      {:error, op_id} ->
        control(s, Packet.nack(op_id, {:argument, "op"}, s.rev))
        {:ok, s}

      :error ->
        bye(s, "op")
    end
  end

  defp ack(s, op_id, rev), do: control(s, Packet.ack(op_id, rev))

  # ---- Leases: an agent's lanes ----

  # As many lanes as the gate allows streams: a key cannot hold more.
  defp lease(%{leases: leases} = s, lane, _job_id)
       when map_size(leases) >= @max_leases or is_map_key(leases, lane) do
    control(s, Packet.frame(:bye, lane, sized("busy")))
    {:ok, s}
  end

  defp lease(s, lane, job_id) do
    case Letterbox.claim(job_id) do
      {:ok, pair} ->
        control(s, Packet.ack(0, lane))
        {:ok, %{s | leases: Map.put(s.leases, lane, pair)}}

      {:error, reason} ->
        control(s, Packet.nack(0, reason, lane))
        {:ok, s}
    end
  end

  # A lane's op writes its own job, with the session as the lease's
  # holder; its ACK waits for the delta, as a browser's does, and comes
  # back on the lane.
  defp lease_op(s, lane, body) do
    pair = s.leases[lane]

    case Packet.op(body) do
      {:ok, op} when pair != nil ->
        if Letterbox.lease_op?(op, pair) do
          case Ops.run(s.account_id, op) do
            {:ok, rev} when rev <= s.rev ->
              ack(s, op.op_id, lane)
              {:ok, s}

            {:ok, rev} ->
              {:ok, %{s | acks: [{rev, op.op_id, lane} | s.acks]}}

            {:error, reason} ->
              control(s, Packet.nack(op.op_id, reason, lane))
              {:ok, s}
          end
        else
          control(s, Packet.nack(op.op_id, {:argument, "op for the leased job"}, lane))
          {:ok, s}
        end

      {:ok, op} ->
        control(s, Packet.nack(op.op_id, {:argument, "lease"}, lane))
        {:ok, s}

      {:error, op_id} ->
        control(s, Packet.nack(op_id, {:argument, "op"}, lane))
        {:ok, s}

      :error ->
        bye(s, "op")
    end
  end

  defp release(s, lane) do
    {pair, leases} = Map.pop(s.leases, lane)
    if pair, do: Letterbox.release(pair)
    %{s | leases: leases}
  end

  # ---- Writing ----

  defp control(s, io), do: s.mod.send(s.carrier, @control, io)

  defp reset(s, id) do
    s.mod.reset(s.carrier, id, 0)
    {:ok, s}
  end

  defp bye(s, reason) do
    control(s, Packet.frame(:bye, s.rev, sized(reason)))
    s.mod.close(s.carrier, 0, reason)
    {:stop, :normal, s}
  end

  defp sized(text), do: [<<byte_size(text)::little-16>>, text]
  defp align8(n), do: div(n + 7, 8) * 8
end

defmodule HiremeWeb.WireSocket do
  @moduledoc """
  The desk session over a WebSocket, for networks that block UDP: the
  same frames as WebTransport, in binary messages. The session cookie
  authenticates at upgrade; there is one stream, the control stream.
  """

  @behaviour Phoenix.Socket.Transport

  alias Hireme.Accounts
  alias HiremeWeb.Auth
  alias HiremeWeb.Session

  def child_spec(_opts), do: :ignore

  def connect(%{connect_info: %{session: %{} = cookie}} = info) do
    case Accounts.session(cookie[Auth.session_key()]) do
      {session, account} ->
        Hireme.Repo.put_account(account.id)

        if Hireme.Mfa.required?(session),
          do: :error,
          else: {:ok, %{account_id: account.id, session_id: session.id}}

      nil ->
        agent(info_peer(info))
    end
  end

  def connect(info), do: agent(info_peer(info))

  # No browser session: an agent, which must send its API-key HELLO first.
  defp agent(ip), do: {:ok, %{ip: ip, origin: "", path: "/wt"}}

  defp info_peer(%{connect_info: %{peer_data: %{address: address}}}),
    do: address |> :inet.ntoa() |> to_string()

  defp info_peer(_), do: ""

  def init(meta) do
    {:ok, s} = Session.init({__MODULE__, self()}, meta)
    {:ok, s}
  end

  def handle_in({bytes, opcode: :binary}, s), do: out(Session.event({:data, 0, bytes}, s))
  def handle_in(_frame, s), do: {:ok, s}

  def handle_info({__MODULE__, :stop}, s), do: {:stop, :normal, s}
  def handle_info(message, s), do: out(Session.info(message, s))

  def terminate(reason, s) do
    Session.terminate(reason, s)
    :ok
  end

  # The carrier: frames written during a callback leave as one message.
  def send(_c, _id, io), do: Process.put(__MODULE__, [Process.get(__MODULE__, []) | [io]])
  def fin(_c, _id), do: :ok
  def reset(_c, _id, _code), do: :ok
  def ready(_c), do: :ok
  def close(_c, _code, _reason), do: Process.put({__MODULE__, :close}, true)

  defp out({result, s}) when result == :ok, do: push(s, nil)
  defp out({:stop, reason, s}), do: push(s, reason)

  # A closing session still says why: its last frames go out, then the
  # socket stops on the next message.
  defp push(s, stop) do
    io = Process.delete(__MODULE__)
    closing = Process.delete({__MODULE__, :close}) || stop

    cond do
      io && closing ->
        Kernel.send(self(), {__MODULE__, :stop})
        {:push, {:binary, IO.iodata_to_binary(io)}, s}

      io ->
        {:push, {:binary, IO.iodata_to_binary(io)}, s}

      closing ->
        {:stop, :normal, s}

      true ->
        {:ok, s}
    end
  end
end
