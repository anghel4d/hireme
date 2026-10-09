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
  always lands before the ACK of the op that caused it). Every other
  client bidi stream on an agent session is a letterbox lease
  (`HiremeWeb.LetterboxStream`); on a browser session it is reset.

  Order: `Hireme.Ops` serializes every write per account and broadcasts
  `{:ops_delta, rev, delta}` before it answers. A delta at or below the
  session's rev is dropped; an ACK waits until the delta of its rev has
  gone out.
  """

  require Logger

  alias Hireme.Ops
  alias Hireme.Repo
  alias HiremeWeb.LetterboxStream
  alias HiremeWeb.Packet

  @control 0
  @agent 0x80
  @end_flag 0x02
  # HELLO's option word: bit 0 asks for raw tables (the client derives every view).
  @raw_opt 0x01
  @ticket_age 60
  @recheck_ms 60_000
  @hello_deadline_ms 5_000

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
    letters: %{},
    raw: false,
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
          true -> by_ticket(s, query["t"])
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
  defp by_ticket(s, ticket) do
    case redeem(ticket) do
      {:ok, account_id, session_id} ->
        s.mod.ready(s.carrier)
        {:ok, browser(s, account_id, session_id)}

      :error ->
        {:refuse, 403}
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

  def event({:stream, id}, %{role: :agent} = s) do
    me = self()
    send_fun = letter_sender(s, id, me)
    close_fun = fn reason -> send(me, {__MODULE__, :letter_closed, id, reason}) end

    case LetterboxStream.open(s.agent, send_fun, close_fun) do
      {:ok, pid} -> {:ok, %{s | letters: Map.put(s.letters, id, pid)}}
      {:error, _} -> reset(s, id)
    end
  end

  def event({:stream, id}, s), do: reset(s, id)

  def event({:data, @control, bytes}, s) do
    case Packet.split(s.buffer <> bytes) do
      {:ok, frames, rest} -> frames(frames, %{s | buffer: rest})
      {:error, reason} -> bye(s, Atom.to_string(reason))
    end
  end

  def event({:data, id, bytes}, s) do
    if pid = s.letters[id], do: LetterboxStream.data(pid, bytes)
    {:ok, s}
  end

  def event({:fin, @control}, s), do: {:stop, :normal, s}
  def event({:reset, @control, _}, s), do: {:stop, :normal, s}

  def event({tag, id, _}, s) when tag in [:reset, :stop], do: event({:fin, id}, s)

  def event({:fin, id}, s) do
    {pid, letters} = Map.pop(s.letters, id)
    if pid, do: LetterboxStream.fin(pid)
    {:ok, %{s | letters: letters}}
  end

  def event({:dgram, bytes}, s) do
    case Packet.split(bytes) do
      {:ok, frames, _} -> frames(frames, s)
      {:error, _} -> {:ok, s}
    end
  end

  def event({:closed, _code, _reason}, s), do: {:stop, :normal, s}

  # A lease's replies do not order against the desk's frames, so on the
  # gate (whose socket any process may write, one whole packet per send)
  # the lease writes its stream directly instead of queueing behind a
  # PATCH in this process; the WebSocket carrier buffers per callback, so
  # there it goes through the session.
  defp ensure_lane(%{letters: letters} = s, lane) when is_map_key(letters, {:lane, lane}), do: s

  defp ensure_lane(s, lane) do
    me = self()
    id = {:lane, lane}
    send_fun = fn io -> send(me, {__MODULE__, :letter, id, io}) end
    close_fun = fn reason -> send(me, {__MODULE__, :letter_closed, id, reason}) end
    {:ok, pid} = LetterboxStream.open(s.agent, send_fun, close_fun)
    %{s | letters: Map.put(s.letters, id, pid)}
  end

  # A lane's replies carry the lane in the header's rev.
  defp stamp(io, lane) do
    {:ok, frames, _} = Packet.split(IO.iodata_to_binary(io))
    for {kind, flags, _rev, body} <- frames, do: Packet.frame(kind, lane, body, flags: flags)
  end

  defp letter_sender(%{mod: HiremeWeb.Gate, carrier: carrier}, id, _me),
    do: fn io -> HiremeWeb.Gate.send(carrier, id, io) end

  defp letter_sender(_s, id, me), do: fn io -> send(me, {__MODULE__, :letter, id, io}) end

  @doc "Any other message the host received: deltas, account changes, letters, timers."
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

  def info({__MODULE__, :letter, {:lane, lane}, io}, s) do
    control(s, stamp(io, lane))
    {:ok, s}
  end

  def info({__MODULE__, :letter, id, io}, s) do
    s.mod.send(s.carrier, id, io)
    {:ok, s}
  end

  def info({__MODULE__, :letter_closed, {:lane, lane} = id, reason}, s) do
    control(s, Packet.frame(:bye, lane, sized(to_string(reason))))
    {:ok, %{s | letters: Map.delete(s.letters, id)}}
  end

  def info({__MODULE__, :letter_closed, id, _reason}, s) do
    s.mod.fin(s.carrier, id)
    {:ok, %{s | letters: Map.delete(s.letters, id)}}
  end

  def info({__MODULE__, :tick}, %{hello: true} = s) do
    control(s, Packet.frame(:tick, s.rev, clock()))
    schedule_tick()
    {:ok, s}
  end

  def info({__MODULE__, :hello_deadline}, %{hello: false} = s), do: bye(s, "hello")

  def info({__MODULE__, :recheck}, %{role: :browser} = s) do
    if live?(s.account_id, s.session_id) do
      Process.send_after(self(), {__MODULE__, :recheck}, @recheck_ms)
      {:ok, s}
    else
      bye(s, "signed_out")
    end
  end

  def info(_message, s), do: {:ok, s}

  @spec terminate(term(), %__MODULE__{}) :: :ok
  def terminate(_reason, _s), do: :ok

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

  defp frame({:hello, _, _, _}, s), do: bye(s, "hello")
  defp frame(_frame, %{hello: false} = s), do: bye(s, "hello")

  # Where an agent has no streams (the WebSocket), a lease rides control
  # as a lane: its frames carry the lane (≥ 1) in the header's rev, go to
  # that lane's lease process, and its replies come back stamped with it.
  # BYE on a lane releases that lease.
  defp frame({:bye, _, lane, _}, %{role: :agent} = s) when lane > 0,
    do: event({:fin, {:lane, lane}}, s)

  defp frame({kind, flags, lane, body}, %{role: :agent} = s)
       when lane > 0 and kind in [:lease, :op, :rpc] do
    s = ensure_lane(s, lane)

    LetterboxStream.data(
      s.letters[{:lane, lane}],
      IO.iodata_to_binary(Packet.frame(kind, lane, body, flags: flags))
    )

    {:ok, s}
  end

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
    case HiremeWeb.Sockets.agent_key(key, s.peer) do
      {:ok, agent} ->
        Repo.put_account(agent.account_id)
        s = %{s | role: :agent, agent: agent, account_id: agent.account_id, client_id: client}
        s.mod.ready(s.carrier)

        # An agent is a client like the browser: the same raw BOOT, the
        # same deltas, and it derives its own views from them.
        {:ok, rev, {:boot, %{tables: tables}}} = Ops.attach(agent.account_id, nil)
        s = %{s | rev: rev, hello: true, raw: true}
        boot(s, rev, tables, [])
        {:ok, s}

      :error ->
        bye(s, "key")
    end
  end

  defp hello(%{role: :browser, raw: true} = s, false, _cred, snapshot, client) do
    s.mod.ready(s.carrier)
    Phoenix.PubSub.subscribe(Hireme.PubSub, Hireme.Audit.topic(s.account_id))
    {:ok, rev, snap} = Ops.attach(s.account_id, if(snapshot == 0, do: nil, else: snapshot))
    s = %{s | rev: rev, hello: true, client_id: client}

    case snap do
      {:boot, %{tables: tables}} ->
        boot(s, rev, tables, account_tables(s))

      {:replay, deltas} ->
        for {r, delta} <- deltas, do: control(s, Packet.frame(:patch, r, raw_delta(delta)))
        control(s, Packet.frame(:patch, rev, [clock(), account_tables(s)], flags: @end_flag))
    end

    control(s, Packet.frame(:ticket, rev, sized(ticket(s.account_id, s.session_id))))
    schedule_tick()
    {:ok, s}
  end

  # A browser that does not ask for raw tables runs a bundle from before
  # them; BYE "schema" reloads it onto the current one.
  defp hello(%{role: :browser} = s, false, _cred, _snapshot, _client), do: bye(s, "schema")

  defp hello(s, _agent?, _cred, _snapshot, _client), do: bye(s, "hello")

  # ---- Raw tables (round two): rows as the database holds them ----

  @raw_tables ~w(job_apps profiles items cv_variants cv_lineages overlays batches events kv_pairs
                 narratives scoreboard_snapshots gym_problems gym_reps net_entries leases)a

  # Every raw table the snapshot holds, then the server's clock.
  @board ~w(job_apps profiles batches cv_variants leases scoreboard_snapshots)a

  # The board first: what the cards are drawn from, without the job
  # listings. The rest (CV items, events, gym and net, the listings)
  # follows at the same rev, so the first paint waits for neither.
  defp boot(s, rev, tables, account) do
    {board, rest} = split_boot(tables)
    body = [Packet.static_lookups(), raw_boot(board), account]
    control(s, Packet.frame(:boot, rev, body, deflate: true, flags: @end_flag))
    if rest != [], do: control(s, Packet.frame(:patch, rev, rest, deflate: true))
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
    control(s, Packet.frame(:patch, rev, raw_delta(delta)))
    {due, held} = Enum.split_with(s.acks, fn {r, _} -> r <= rev end)
    Enum.each(Enum.reverse(due), fn {r, op_id} -> ack(s, op_id, r) end)
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

  defp rpc_reply(s, reply), do: control(s, LetterboxStream.rpc(Jason.encode!(reply)))

  # ---- Ops ----

  defp op(s, <<op_id::little-64, kind::8, n::8, _::16, target::little-32, fields::binary>>) do
    with name when not is_nil(name) <- Packet.op_kind(kind),
         {:ok, fields} <- fields(fields, n, []) do
      case Ops.run(s.account_id, %{op_id: op_id, kind: name, target: target, fields: fields}) do
        {:ok, rev} when rev <= s.rev ->
          ack(s, op_id, rev)
          {:ok, s}

        {:ok, rev} ->
          {:ok, %{s | acks: [{rev, op_id} | s.acks]}}

        {:error, reason} ->
          nack(s, op_id, reason)
          {:ok, s}
      end
    else
      _ ->
        nack(s, op_id, {:argument, "op"})
        {:ok, s}
    end
  end

  defp op(s, _body), do: bye(s, "op")

  defp fields(_rest, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp fields(<<len::little-16, field::binary-size(len), rest::binary>>, n, acc),
    do: fields(rest, n - 1, [field | acc])

  defp fields(_, _, _), do: :error

  defp ack(s, op_id, rev), do: control(s, Packet.frame(:ack, rev, <<op_id::little-64>>))

  defp nack(s, op_id, reason) do
    {name, message} = refusal(reason)
    msg = String.slice(message, 0, 400)

    control(
      s,
      Packet.frame(:nack, s.rev, [
        <<op_id::little-64, Packet.refusal_code(name)::8, 0::8, byte_size(msg)::little-16>>,
        msg
      ])
    )
  end

  defp refusal({:argument, name}), do: {:argument, "Need a #{name}."}
  defp refusal({name, message}) when is_atom(name) and is_binary(message), do: {name, message}
  defp refusal(%Ecto.Changeset{}), do: {:invalid, "That did not save."}
  defp refusal(name) when is_atom(name), do: {name, Atom.to_string(name)}
  defp refusal(_), do: {:internal, "internal"}

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
