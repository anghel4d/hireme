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

    s =
      if snapshot == rev do
        control(s, Packet.frame(:boot, rev, [], flags: @end_flag))
        s
      else
        boot(s, rev, snap)
      end

    control(s, Packet.frame(:ticket, rev, sized(ticket(s.account_id, s.session_id))))
    {:ok, warm(s, Enum.map(snap.cards, & &1.id))}
  end

  defp hello(s, _agent?, _cred, _snapshot, _client), do: bye(s, "hello")

  defp boot(s, rev, snap) do
    {roots, intern} =
      Enum.map_reduce(snap.profiles, s.intern, fn p, intern ->
        Packet.root_rows(p.id, JSON.root(Hireme.Desk.root(p.id)), intern)
      end)

    merged =
      Enum.reduce(roots, %{}, fn r, acc -> Map.merge(acc, r, fn _k, a, b -> a ++ b end) end)

    narratives = narratives(snap.profiles)

    body = [
      Packet.lookups(snap.batches, snap.profiles),
      Packet.table(:cards, Packet.card_rows(snap.cards, snap.batches, snap.profiles)),
      Packet.score_tables(JSON.scoreboard(Hireme.Campaign.scoreboard())),
      Packet.lane_tables(JSON.lanes()),
      Packet.table(:lines, Map.get(merged, :lines, [])),
      Packet.table(:roots, Map.get(merged, :roots, [])),
      Packet.table(:root_sections, Map.get(merged, :root_sections, [])),
      Packet.table(:root_lines, Map.get(merged, :root_lines, [])),
      Packet.table(:narratives, narratives),
      Packet.table(
        :kv,
        Enum.map(Hireme.Kv.list("global"), &%{scope: 0, key: &1.key, value: &1.value})
      )
    ]

    control(s, Packet.frame(:boot, rev, body, deflate: true, flags: @end_flag))
    %{s | intern: intern}
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

  defp patch(s, rev, delta) do
    batches = if delta[:batches], do: Hireme.Desk.list_batches(), else: s.batches
    s = %{s | batches: batches}

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
      if(delta[:scoreboard],
        do: Packet.score_tables(JSON.scoreboard(Hireme.Campaign.scoreboard())),
        else: []
      ),
      if(delta[:lanes] && s.role == :browser, do: Packet.lane_tables(JSON.lanes()), else: []),
      if(delta[:narrative] && s.role == :browser,
        do: Packet.table(:narratives, narratives(s.profiles)),
        else: []
      )
    ]

    control(s, Packet.frame(:patch, rev, body))
    {due, held} = Enum.split_with(s.acks, fn {r, _} -> r <= rev end)
    Enum.each(Enum.reverse(due), fn {r, op_id} -> ack(s, op_id, r) end)

    if s.warmer && delta[:focus] not in [nil, []], do: send(s.warmer, {:urgent, delta.focus, rev})
    %{s | rev: rev, acks: held}
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

  defp warmer(session, queue, urgent, rev) do
    receive do
      {:hint, ids} ->
        warmer(session, ids ++ (queue -- ids), urgent, rev)

      {:urgent, ids, at} ->
        warmer(session, queue, urgent ++ Enum.map(ids, &{&1, at}), max(rev, at))
    after
      0 ->
        case {urgent, queue} do
          {[{id, at} | more], _} ->
            read_focus(session, id, at, true)
            warmer(session, queue, more, rev)

          {[], [id | more]} ->
            read_focus(session, id, rev, false)
            warmer(session, more, [], rev)

          {[], []} ->
            receive do
              {:urgent, ids, at} -> warmer(session, [], Enum.map(ids, &{&1, at}), max(rev, at))
              {:hint, _} -> warmer(session, [], [], rev)
            end
        end
    end
  end

  defp read_focus(session, id, rev, urgent) do
    case Hireme.Desk.focus(id) do
      nil -> :ok
      focus -> send(session, {__MODULE__, :focus, JSON.focus(focus), rev, urgent})
    end
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
