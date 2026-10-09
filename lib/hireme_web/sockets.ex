defmodule HiremeWeb.Sockets do
  @moduledoc false
  # What the agent sockets share: one JSON object per text frame, and
  # the question every agent socket asks at upgrade: whose key is this?

  alias Hireme.ApiKeys

  def reply(text, state, respond) do
    response =
      case Jason.decode(text) do
        {:ok, message} -> respond.(message)
        _ -> %{error: %{code: -32700, message: "parse error"}}
      end

    {:reply, :ok, {:text, Jason.encode!(response)}, state}
  end

  @doc "Subscribe this process to the key's revoke, and recheck expiry once a minute."
  def watch(%{key_id: key_id}) when is_binary(key_id) do
    Phoenix.PubSub.subscribe(Hireme.PubSub, ApiKeys.topic(key_id))
    Process.send_after(self(), :recheck_key, 60_000)
    :ok
  end

  def watch(_state), do: :ok

  @doc "Run `fun` only while the key that opened the socket is still live."
  def gate(%{key_id: key_id, account_id: account_id} = state, fun) when is_binary(key_id) do
    if ApiKeys.usable?(key_id, account_id), do: fun.(), else: {:stop, :revoked, state}
  end

  def gate(_state, fun), do: fun.()

  def recheck(%{key_id: key_id, account_id: account_id} = state) when is_binary(key_id) do
    if ApiKeys.usable?(key_id, account_id) do
      Process.send_after(self(), :recheck_key, 60_000)
      {:ok, state}
    else
      {:stop, :expired, state}
    end
  end

  def recheck(state), do: {:ok, state}

  def push(payload, state), do: {:push, {:text, Jason.encode!(payload)}, state}

  @doc """
  The account an agent's upgrade authenticates for, from the
  `x-api-key` header or the bearer subprotocol, or `:error`. An upgrade
  without a live key is refused before any socket state exists.
  """
  @spec agent(map()) ::
          {:ok,
           %{
             account_id: pos_integer(),
             key_id: String.t(),
             expires_at: DateTime.t() | nil
           }}
          | :error
  def agent(%{connect_info: info}) when is_map(info) do
    token = Map.get(info, :auth_token) || header(Map.get(info, :x_headers, []), "x-api-key")

    peer =
      case Map.get(info, :peer_data) do
        %{address: address} -> address |> :inet.ntoa() |> to_string()
        _ -> ""
      end

    agent_key(token, peer)
  end

  def agent(_info), do: :error

  @doc """
  The agent a presented API key names, counted once against the peer's
  key limiter. A WebTransport agent session calls this once for its
  HELLO; every letterbox stream it opens afterwards rides that one
  authentication.
  """
  @spec agent_key(term(), String.t()) ::
          {:ok, %{account_id: pos_integer(), key_id: String.t(), expires_at: DateTime.t() | nil}}
          | :error
  def agent_key(token, peer) when is_binary(peer) do
    case ApiKeys.authenticate(token, peer) do
      {:ok, key} ->
        {:ok, %{account_id: key.account_id, key_id: key.key_id, expires_at: key.expires_at}}

      :error ->
        :error
    end
  end

  defp header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  defp header(_, _), do: nil
end

defmodule HiremeWeb.McpDirectorySocket do
  @moduledoc """
  Read-only directory of one account's letterboxes.

  Connect at `/mcp/websocket` with an API key. This socket cannot lease
  and cannot write, and it lists nothing outside the key's account.
  """

  @behaviour Phoenix.Socket.Transport

  alias Hireme.Repo
  alias HiremeWeb.Sockets

  def child_spec(_opts), do: :ignore
  def connect(info), do: Sockets.agent(info)

  def init(%{account_id: account_id} = state) do
    Repo.put_account(account_id)
    Sockets.watch(state)
    {:ok, state}
  end

  def handle_in({text, _opts}, state),
    do: Sockets.gate(state, fn -> Sockets.reply(text, state, &HiremeWeb.Mcp.directory/1) end)

  def handle_info(:api_key_dead, state), do: {:stop, :revoked, state}
  def handle_info(:recheck_key, state), do: Sockets.recheck(state)
  def handle_info(_message, state), do: {:ok, state}
  def terminate(_reason, _state), do: :ok
end

defmodule HiremeWeb.McpSocket do
  @moduledoc """
  Full-duplex websocket for one leased letterbox.

  Connect at `/mcp/letterbox/:letterbox_id/websocket` with an API key
  for the account that owns the letterbox; any other key sees no such
  letterbox. The connection process is the single producer. The
  letterbox process is the single consumer. A second connection for
  that id is refused.
  """

  @behaviour Phoenix.Socket.Transport

  alias Hireme.Desk.Signal
  alias Hireme.Letterbox
  alias Hireme.Letterbox.Handle
  alias Hireme.Repo
  alias HiremeWeb.Sockets

  def child_spec(_opts), do: :ignore

  def connect(%{params: %{"letterbox_id" => raw}} = info) do
    with {:ok, agent} <- Sockets.agent(info),
         {id, ""} when id > 0 <- Integer.parse(to_string(raw)) do
      Repo.put_account(agent.account_id)

      cond do
        not Letterbox.exists?(id) -> :error
        Letterbox.leased?(id) -> {:error, :busy}
        true -> {:ok, Map.put(agent, :id, id)}
      end
    else
      _ -> :error
    end
  end

  def connect(_info), do: :error

  def init(%{id: id, account_id: account_id} = state) do
    Repo.put_account(account_id)

    case Letterbox.lease(id, self()) do
      {:ok, %Handle{} = handle} ->
        Sockets.watch(state)
        {:ok, Map.put(state, :handle, handle)}

      {:error, reason} ->
        {:stop, reason, %{}}
    end
  end

  def handle_in({text, _opts}, %{handle: %Handle{} = handle} = state) do
    Sockets.gate(state, fn -> Sockets.reply(text, state, &HiremeWeb.Mcp.handle(handle, &1)) end)
  end

  def handle_info(:api_key_dead, state), do: {:stop, :revoked, state}
  def handle_info(:recheck_key, state), do: Sockets.recheck(state)

  def handle_info({:desk_event, %Signal{} = signal}, state) do
    Sockets.gate(state, fn ->
      Sockets.push(%{method: "notifications/desk", params: Signal.to_json(signal)}, state)
    end)
  end

  def handle_info(_message, state), do: {:ok, state}

  def terminate(_reason, %{handle: %Handle{} = handle}) do
    Letterbox.release(handle)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end

defmodule HiremeWeb.LetterboxStream do
  @moduledoc """
  One letterbox lease on one bidi stream of an agent session.

  An agent authenticates once, in its session's HELLO. After that it can
  open any number of bidi streams, and each one is a lease. The Session
  calls `open/3` for every client bidi stream that is not the control
  stream. It then feeds the stream's bytes to `data/2` and calls `fin/1`
  when the stream ends or is reset. The returned process is the lease's
  single producer, so the rule in `Hireme.Letterbox`, one producer and
  one lease, holds per stream: parallel leases run in parallel processes.
  Closing the stream releases the lease, and so does the death of the
  session.

  The stream carries frames with the shared 16-byte header (`u32 len |
  u8 kind | u8 flags | u16 schema_hash | u64 rev`, little-endian). `len`
  is the whole frame, header included, always a multiple of 8; the body
  is zero-padded to it.

    * `LEASE` (0x20) is client to server, and only as the first frame.
      Its body is `u64 letterbox_id`. Id 0 opens the read-only directory
      instead of a lease.
    * `RPC` (0x21) goes both ways. Its body is `u32 json_len | u32 0`
      and then one JSON-RPC message in UTF-8.

  The first server frame always answers the LEASE. It is an RPC
  notification `notifications/lease`. Its params are the lease's ids,
  or `{"error": reason}`, in which case the stream closes. The
  stream then carries tool calls and their replies in order, plus
  `notifications/desk` for the application this lease holds. The desk
  rows themselves reach the agent once per session as columnar PATCH
  frames on the control stream, not once per lease.
  """

  use GenServer

  import Bitwise

  alias Hireme.ApiKeys
  alias Hireme.CvPair
  alias Hireme.Desk.Signal
  alias Hireme.Letterbox
  alias Hireme.Letterbox.Handle
  alias Hireme.Repo
  alias HiremeWeb.Mcp
  alias HiremeWeb.Sockets

  @lease 0x20
  @rpc 0x21
  @header 16
  # One tool call or reply. A CV line is short; a megabyte is a bug.
  @max_body 1 <<< 20

  @type agent :: %{account_id: pos_integer(), key_id: String.t(), expires_at: term()}
  @type sender :: (iodata() -> any())
  @type closer :: (atom() -> any())

  @doc """
  Start the producer for one stream. `send` writes bytes to the stream
  and `close` ends it with a reason; both are called from the stream
  process. The calling process is the session, and the stream dies with
  it.
  """
  @spec open(agent(), sender(), closer()) :: {:ok, pid()} | {:error, term()}
  def open(%{account_id: account_id} = agent, send, close)
      when is_integer(account_id) and is_function(send, 1) and is_function(close, 1) do
    callers = [self() | Process.get(:"$callers", [])]
    GenServer.start(__MODULE__, {agent, send, close, self(), callers})
  end

  @doc "Bytes the client wrote on this stream, in order."
  @spec data(pid(), binary()) :: :ok
  def data(pid, bytes) when is_binary(bytes), do: GenServer.cast(pid, {:data, bytes})

  @doc "The client finished or reset the stream: release the lease."
  @spec fin(pid()) :: :ok
  def fin(pid), do: GenServer.cast(pid, :fin)

  @doc "One RPC frame carrying `json`, as this stream writes it."
  @spec rpc(iodata()) :: iodata()
  def rpc(json) do
    size = IO.iodata_length(json)
    unpadded = @header + 8 + size
    len = unpadded + pad(unpadded)

    [
      <<len::32-little, @rpc, 0, schema_hash()::16-little, 0::64-little, size::32-little, 0::32>>,
      json,
      :binary.copy(<<0>>, pad(unpadded))
    ]
  end

  @impl true
  def init({agent, send, close, session, callers}) do
    Process.put(:"$callers", callers)
    Repo.put_account(agent.account_id)
    Process.monitor(session)

    {:ok,
     %{
       key_id: agent[:key_id],
       account_id: agent.account_id,
       send: send,
       close: close,
       buffer: <<>>,
       mode: :opening
     }}
  end

  @impl true
  def handle_cast({:data, bytes}, state), do: drain(%{state | buffer: state.buffer <> bytes})
  def handle_cast(:fin, state), do: {:stop, :normal, state}

  @impl true
  def handle_info({:desk_event, %Signal{} = signal}, %{mode: {:lease, _}} = state) do
    notify(state, "notifications/desk", Signal.to_json(signal))
    {:noreply, state}
  end

  def handle_info(:api_key_dead, state), do: shut(state, :revoked)

  def handle_info(:recheck_key, state) do
    case Sockets.recheck(state) do
      {:ok, state} -> {:noreply, state}
      {:stop, reason, state} -> shut(state, reason)
    end
  end

  def handle_info({:DOWN, _ref, :process, _session, _reason}, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{mode: {:lease, %Handle{} = handle}}) do
    Letterbox.release(handle)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Run every whole frame in the buffer, in order.
  defp drain(%{buffer: <<len::32-little, kind, _f, _h::16, _r::64, rest::binary>>} = state)
       when len >= @header and rem(len, 8) == 0 and len - @header <= @max_body do
    size = len - @header

    if byte_size(rest) >= size do
      <<body::binary-size(size), more::binary>> = rest

      case frame_in(kind, body, %{state | buffer: more}) do
        {:ok, state} -> drain(state)
        stop -> stop
      end
    else
      {:noreply, state}
    end
  end

  defp drain(%{buffer: buffer} = state) when byte_size(buffer) < @header, do: {:noreply, state}
  defp drain(state), do: shut(state, :frame)

  defp frame_in(@lease, <<0::64-little, _::binary>>, %{mode: :opening} = state) do
    notify(state, "notifications/lease", %{"letterbox_id" => 0, "directory" => true})
    {:ok, %{state | mode: :directory}}
  end

  defp frame_in(@lease, <<id::64-little, _::binary>>, %{mode: :opening} = state) do
    case lease(id) do
      {:ok, %Handle{} = handle} ->
        Sockets.watch(state)
        notify(state, "notifications/lease", lease_params(handle))
        {:ok, %{state | mode: {:lease, handle}}}

      {:error, reason} ->
        notify(state, "notifications/lease", %{"letterbox_id" => id, "error" => to_string(reason)})

        shut(state, reason)
    end
  end

  defp frame_in(@rpc, <<size::32-little, _::32, rest::binary>>, %{mode: mode} = state)
       when mode != :opening and size <= byte_size(rest) do
    if live?(state) do
      reply =
        case Jason.decode(binary_part(rest, 0, size)) do
          {:ok, message} -> answer(mode, message)
          _ -> %{error: %{code: -32700, message: "parse error"}}
        end

      state.send.(rpc(Jason.encode_to_iodata!(Map.put(reply, :jsonrpc, "2.0"))))
      {:ok, state}
    else
      shut(state, :revoked)
    end
  end

  defp frame_in(_kind, _body, state), do: shut(state, :protocol)

  defp answer(:directory, message), do: Mcp.directory(message)
  defp answer({:lease, handle}, message), do: Mcp.handle(handle, message)

  # A letterbox in another account does not exist for this one.
  defp lease(id) when id > 0 and id < 1 <<< 31 do
    if Letterbox.exists?(id), do: Letterbox.lease(id, self()), else: {:error, :letterbox}
  end

  defp lease(_id), do: {:error, :letterbox}

  defp lease_params(%Handle{id: id, pair: pair}) do
    %{
      "letterbox_id" => id,
      "job_id" => CvPair.job_id(pair),
      "variant_id" => CvPair.variant_id(pair),
      "employer_id" => CvPair.employer_id(pair),
      "lineage_id" => CvPair.lineage_id(pair)
    }
  end

  defp live?(%{key_id: key_id, account_id: account_id}) when is_binary(key_id),
    do: ApiKeys.usable?(key_id, account_id)

  defp live?(_state), do: true

  defp notify(state, method, params) do
    body = Jason.encode_to_iodata!(%{jsonrpc: "2.0", method: method, params: params})
    state.send.(rpc(body))
  end

  defp shut(state, reason) do
    state.close.(reason)
    {:stop, :normal, state}
  end

  defp pad(len), do: rem(8 - rem(len, 8), 8)

  defp schema_hash, do: HiremeWeb.Packet.schema_hash()
end
