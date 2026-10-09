defmodule HiremeWeb.Session do
  @moduledoc """
  One live connection to the desk, whatever carries it.

  A session is hosted by the process that owns its connection: the gate's
  connection process for WebTransport (`HiremeWeb.Gate`), Phoenix's socket
  process for the WebSocket fallback (`HiremeWeb.WireSocket`). The host
  feeds it carrier events and every other message it receives, and the
  session writes back through the carrier module's functions, so a frame
  costs no hop between processes.

  Streams: client bidi 0 is control (HELLO and OPs up; BOOT, PATCH, ACK,
  NACK, urgent FOCUS down, in one order, so a PATCH always lands before
  the ACK of the op that caused it). The session opens one server uni
  stream, bulk, at low priority for the background FOCUS stream. Every
  other client bidi stream on an agent session is a letterbox lease
  (`HiremeWeb.LetterboxStream`); on a browser session it is reset.

  Order: `Hireme.Ops` serializes every write per account and broadcasts
  `{:ops_delta, rev, delta}` before it answers. A delta at or below the
  session's rev is dropped; an ACK waits until the delta of its rev has
  gone out.
  """

  require Logger

  alias Hireme.Ops
  alias Hireme.Repo
  alias HiremeWeb.JSON
  alias HiremeWeb.LetterboxStream
  alias HiremeWeb.Packet

  @control 0
  @agent 0x80
  @end_flag 0x02
  @ticket_age 60
  @recheck_ms 60_000

  defstruct [
    :carrier,
    :mod,
    :account_id,
    :session_id,
    :agent,
    :peer,
    :warmer,
    :bulk,
    role: :pending,
    rev: 0,
    hello: false,
    client_id: 0,
    buffer: <<>>,
    acks: [],
    intern: %{},
    batches: [],
    profiles: [],
    letters: %{},
    chrome: %{},
    next_uni: 3
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
          origin == "" and not Map.has_key?(query, "t") -> {:ok, s}
          not allowed_origin?(origin) -> {:refuse, 403}
          true -> by_ticket(s, query["t"])
        end
    end
  end

  defp by_ticket(s, ticket) do
    case redeem(ticket) do
      {:ok, account_id, session_id} -> {:ok, browser(s, account_id, session_id)}
      :error -> {:refuse, 403}
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
    send_fun = fn io -> send(me, {__MODULE__, :letter, id, io}) end
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

  @doc "Any other message the host received: deltas, the warmer's focuses, letters, timers."
  @spec info(term(), %__MODULE__{}) :: {:ok, %__MODULE__{}} | {:stop, term(), %__MODULE__{}}
  def info({:ops_delta, rev, _delta}, %{rev: seen} = s) when rev <= seen, do: {:ok, s}
  def info({:ops_delta, rev, delta}, %{hello: true} = s), do: {:ok, patch(s, rev, delta)}
  def info({:ops_delta, _, _}, s), do: {:ok, s}

  def info({__MODULE__, :chrome, kind, rev, io}, s), do: {:ok, chrome_out(s, kind, rev, io)}

  def info({__MODULE__, :focus, focus, rev, urgent}, s),
    do: {:ok, focus_out(s, focus, rev, urgent)}

  def info({__MODULE__, :letter, id, io}, s) do
    s.mod.send(s.carrier, id, io)
    {:ok, s}
  end

  def info({__MODULE__, :letter_closed, id, _reason}, s) do
    s.mod.fin(s.carrier, id)
    {:ok, %{s | letters: Map.delete(s.letters, id)}}
  end

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
  def terminate(_reason, s) do
    if s.warmer, do: Process.exit(s.warmer, :shutdown)
    :ok
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
           client::little-32,
           _::binary>> <-
           rest do
      hello(s, Bitwise.band(flags, @agent) != 0, cred, snapshot, client)
    else
      _ -> bye(s, "hello")
    end
  end

  defp frame({:hello, _, _, _}, s), do: bye(s, "hello")
  defp frame(_frame, %{hello: false} = s), do: bye(s, "hello")

  defp frame({:op, _, _, body}, %{role: :browser} = s), do: op(s, body)

  defp frame({:hint, _, _, <<n::little-32, ids::binary-size(n)-unit(32), _::binary>>}, s) do
    if s.warmer, do: send(s.warmer, {:hint, for(<<id::little-32 <- ids>>, do: id)})
    {:ok, s}
  end

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
        {:ok, rev, snap} = Ops.attach(agent.account_id)
        s = %{s | rev: rev, hello: true, batches: snap.batches, profiles: snap.profiles}

        control(
          s,
          Packet.frame(:boot, rev, Packet.lookups(snap.batches, snap.profiles), flags: @end_flag)
        )

        {:ok, s}

      :error ->
        bye(s, "key")
    end
  end

  defp hello(%{role: :browser} = s, false, _cred, snapshot, client) do
    s.mod.ready(s.carrier)
    {:ok, rev, snap} = Ops.attach(s.account_id)

    s = %{
      s
      | rev: rev,
        hello: true,
        client_id: client,
        batches: snap.batches,
        profiles: snap.profiles
    }

    # A current snapshot already holds every focus as of this rev, so the
    # focus stream then carries only what later deltas touch.
    {s, ids} =
      if snapshot != 0 and snapshot == rev do
        control(s, Packet.frame(:patch, rev, [], flags: @end_flag))
        {s, []}
      else
        {boot(s, rev, snap), Enum.map(snap.cards, & &1.id)}
      end

    control(s, Packet.frame(:ticket, rev, sized(ticket(s.account_id, s.session_id))))
    {:ok, warm(s, ids)}
  end

  defp hello(s, _agent?, _cred, _snapshot, _client), do: bye(s, "hello")

  # Every profile's root CV: the roots tables are replaced whole, so a
  # change to one root sends them all (a handful of profiles).
  defp root_tables(profiles, intern) do
    {roots, intern} =
      Enum.map_reduce(profiles, intern, fn p, intern ->
        Packet.root_rows(p.id, JSON.root(Hireme.Desk.root(p.id)), intern)
      end)

    merged =
      Enum.reduce(roots, %{}, fn r, acc -> Map.merge(acc, r, fn _k, a, b -> a ++ b end) end)

    tables =
      for t <- [:lines, :roots, :root_sections, :root_lines],
          t != :lines or Map.get(merged, :lines, []) != [],
          do: Packet.table(t, Map.get(merged, t, []))

    {tables, intern}
  end

  # The board first: cards, lookups and roots. The scoreboard and lanes
  # (tens of ms of reads) follow as a PATCH from `chrome/3`.
  defp boot(s, rev, snap) do
    {roots, intern} = root_tables(snap.profiles, s.intern)

    body = [
      Packet.lookups(snap.batches, snap.profiles),
      Packet.table(:cards, Packet.card_rows(snap.cards, snap.batches, snap.profiles)),
      roots,
      Packet.table(:narratives, narratives(snap.profiles)),
      Packet.table(
        :kv,
        Enum.map(Hireme.Kv.list("global"), &%{scope: 0, key: &1.key, value: &1.value})
      )
    ]

    control(s, Packet.frame(:boot, rev, body, deflate: true, flags: @end_flag))
    chrome(%{s | intern: intern}, rev, [:score, :lanes])
  end

  defp narratives(profiles) do
    for p <- profiles, n = Hireme.Narrative.for_profile(p), n != nil, uniq: true do
      %{id: n.id, profile: p.id, body: n.body, version: n.version}
    end
  end

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

  # ---- Deltas out ----

  # Cards, gone ids and batches go out before the ACKs they settle; the
  # scoreboard and lanes are never predicted, so `chrome/3` reads them off
  # this process and they follow when ready.
  defp patch(s, rev, delta) do
    batches = if delta[:batches], do: Hireme.Desk.list_batches(), else: s.batches
    s = %{s | batches: batches}
    browser? = s.role == :browser

    {roots, intern} =
      if browser? and delta[:roots] not in [nil, []],
        do: root_tables(s.profiles, s.intern),
        else: {[], s.intern}

    body = [
      if(delta[:cards] not in [nil, []],
        do: Packet.table(:cards, Packet.card_rows(delta.cards, batches, s.profiles)),
        else: []
      ),
      if(delta[:deleted] not in [nil, []],
        do: Packet.table(:cards_gone, Enum.map(delta.deleted, &%{id: &1})),
        else: []
      ),
      if(delta[:batches], do: Packet.batch_table(batches), else: []),
      if(delta[:narrative] && browser?,
        do: Packet.table(:narratives, narratives(s.profiles)),
        else: []
      ),
      roots
    ]

    control(s, Packet.frame(:patch, rev, body))
    {due, held} = Enum.split_with(s.acks, fn {r, _} -> r <= rev end)
    Enum.each(Enum.reverse(due), fn {r, op_id} -> ack(s, op_id, r) end)

    if delta[:focus] not in [nil, []] do
      HiremeWeb.Session.Cache.dirty(s.account_id, delta.focus, rev)
      if s.warmer, do: send(s.warmer, {:urgent, delta.focus, rev})
    end

    s = %{s | rev: rev, acks: held, intern: intern}
    kinds = for {k, flag} <- [score: :scoreboard, lanes: :lanes], delta[flag], do: k
    if browser? and kinds != [], do: chrome(s, rev, kinds), else: s
  end

  # The scoreboard and lanes as of `rev`, read by a linked process and
  # shared across the account's sessions; a result older than one already
  # sent is dropped, so the browser never steps back.
  defp chrome(s, rev, kinds) do
    me = self()
    account = s.account_id

    spawn_link(fn ->
      Repo.put_account(account)

      for kind <- kinds,
          do:
            send(
              me,
              {__MODULE__, :chrome, kind, rev, HiremeWeb.Session.Cache.chrome(account, kind, rev)}
            )
    end)

    s
  end

  defp chrome_out(s, kind, rev, io) do
    if rev >= Map.get(s.chrome, kind, 0) do
      control(s, Packet.frame(:patch, max(rev, s.rev), io))
      %{s | chrome: Map.put(s.chrome, kind, rev)}
    else
      s
    end
  end

  # ---- The focus stream ----

  # A linked process reads focuses in board order, the ids the browser
  # hints first, and the jobs a delta touched before anything else; the
  # session encodes them, so line interning stays in one place.
  defp warm(s, ids) do
    me = self()
    account = s.account_id
    rev = s.rev

    warmer =
      spawn_link(fn ->
        Repo.put_account(account)
        warmer(me, ids, [], rev)
      end)

    {bulk, s} = open_bulk(s)
    %{s | warmer: warmer, bulk: bulk}
  end

  defp open_bulk(s) do
    id = s.next_uni
    s.mod.open_uni(s.carrier, id, -1)
    {id, %{s | next_uni: id + 4}}
  end

  @batch 32

  defp warmer(session, queue, urgent, rev) do
    receive do
      {:hint, ids} ->
        warmer(session, ids ++ (queue -- ids), urgent, rev)

      {:urgent, ids, at} ->
        warmer(session, queue, urgent ++ ids, max(rev, at))
    after
      0 ->
        case {urgent, queue} do
          {[_ | _], _} ->
            {now, later} = Enum.split(Enum.uniq(urgent), @batch)
            read_focus(session, now, rev, true)
            warmer(session, queue, later, rev)

          {[], [_ | _]} ->
            {now, later} = Enum.split(queue, @batch)
            read_focus(session, now, rev, false)
            warmer(session, later, [], rev)

          {[], []} ->
            receive do
              {:urgent, ids, at} -> warmer(session, [], ids, max(rev, at))
              {:hint, _} -> warmer(session, [], [], rev)
            end
        end
    end
  end

  defp read_focus(session, ids, rev, urgent) do
    account = Hireme.Repo.account_id!()

    for {_id, focus} <- HiremeWeb.Session.Cache.focuses(account, ids, rev),
        do: send(session, {__MODULE__, :focus, focus, rev, urgent})

    :ok
  end

  defp focus_out(s, focus, rev, urgent) do
    {frames, intern} = Packet.focus_frames(focus, rev, s.intern, urgent)
    if urgent, do: control(s, frames), else: s.mod.send(s.carrier, s.bulk, frames)
    %{s | intern: intern}
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

defmodule HiremeWeb.Session.Cache do
  @moduledoc """
  Focuses as JSON maps, shared by every session on the node, so a second
  tab or a reload streams the desk's focuses without reading them again.
  An entry read at rev r serves while no delta after r touched its job;
  a delta marks the jobs it touched dirty at its rev. Without the table
  (it is not started) every read goes to `Hireme.Desk.focus/1`.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end

  @doc """
  The focuses of `job_ids` as of `rev` or later, as `{id, json}`: kept
  ones from the table, the rest read in one batch against the
  sequencer's heat snapshot and kept. Unknown ids are left out.
  """
  @spec focuses(pos_integer(), [pos_integer()], non_neg_integer()) :: [{pos_integer(), map()}]
  def focuses(account_id, job_ids, rev) do
    {kept, missing} =
      Enum.reduce(job_ids, {[], []}, fn id, {kept, missing} ->
        case kept(account_id, id) do
          nil -> {kept, [id | missing]}
          json -> {[{id, json} | kept], missing}
        end
      end)

    read =
      case missing do
        [] ->
          []

        ids ->
          for focus <- Hireme.Desk.focuses(Enum.reverse(ids), Hireme.Ops.heat(account_id)) do
            json = HiremeWeb.JSON.focus(focus)
            if table?(), do: :ets.insert(@table, {{account_id, focus.job.id}, rev, json})
            {focus.job.id, json}
          end
      end

    Enum.reverse(kept) ++ read
  end

  @doc "One focus, as `focuses/3` reads it, or nil."
  @spec focus(pos_integer(), pos_integer(), non_neg_integer()) :: map() | nil
  def focus(account_id, job_id, rev) do
    case focuses(account_id, [job_id], rev) do
      [{_, json}] -> json
      [] -> nil
    end
  end

  defp kept(account_id, job_id) do
    key = {account_id, job_id}

    with true <- table?(),
         [{^key, at, json}] <- :ets.lookup(@table, key),
         true <- at >= dirty(account_id, job_id) do
      json
    else
      _ -> nil
    end
  end

  @doc """
  The scoreboard or lanes tables as of `rev` or later, encoded once for
  every session of the account.
  """
  @spec chrome(pos_integer(), :score | :lanes, non_neg_integer()) :: iodata()
  def chrome(account_id, kind, rev) do
    key = {:chrome, account_id, kind}

    case table?() && :ets.lookup(@table, key) do
      [{^key, at, io}] when at >= rev ->
        io

      _ ->
        io = IO.iodata_to_binary(encode(kind))
        if table?(), do: :ets.insert(@table, {key, rev, io})
        io
    end
  end

  defp encode(:score),
    do: HiremeWeb.Packet.score_tables(HiremeWeb.JSON.scoreboard(Hireme.Campaign.scoreboard()))

  defp encode(:lanes), do: HiremeWeb.Packet.lane_tables(HiremeWeb.JSON.lanes())

  @doc "Mark `job_ids` changed at `rev`."
  @spec dirty(pos_integer(), [pos_integer()], non_neg_integer()) :: :ok
  def dirty(account_id, job_ids, rev) do
    if table?(), do: :ets.insert(@table, Enum.map(job_ids, &{{:dirty, account_id, &1}, rev}))
    :ok
  end

  defp dirty(account_id, job_id) do
    case :ets.lookup(@table, {:dirty, account_id, job_id}) do
      [{_, rev}] -> rev
      [] -> 0
    end
  end

  defp table?, do: :ets.whereis(@table) != :undefined
end

defmodule HiremeWeb.WireSocket do
  @moduledoc """
  The desk session over a WebSocket, for networks that block UDP: the
  same frames as WebTransport, in binary messages. The session cookie
  authenticates at upgrade; there is one stream, so the bulk focuses and
  the control frames share it in the order they are written.
  """

  @behaviour Phoenix.Socket.Transport

  alias Hireme.Accounts
  alias HiremeWeb.Auth
  alias HiremeWeb.Session

  def child_spec(_opts), do: :ignore

  def connect(%{connect_info: %{session: %{} = cookie}}) do
    case Accounts.session(cookie[Auth.session_key()]) do
      {session, account} ->
        Hireme.Repo.put_account(account.id)

        if Hireme.Mfa.required?(session),
          do: :error,
          else: {:ok, %{account_id: account.id, session_id: session.id}}

      nil ->
        :error
    end
  end

  def connect(_info), do: :error

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
  def open_uni(_c, _id, _priority), do: :ok
  def open_bi(_c, _id, _priority), do: :ok
  def priority(_c, _id, _priority), do: :ok
  def datagram(c, io), do: send(c, 0, io)
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
