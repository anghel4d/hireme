defmodule HiremeWeb.Sockets do
  @moduledoc false
  # What the three transports share: one JSON object per text frame, and
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
  @spec agent(map()) :: {:ok, %{account_id: pos_integer(), key_id: String.t()}} | :error
  def agent(%{connect_info: info}) when is_map(info) do
    token = Map.get(info, :auth_token) || header(Map.get(info, :x_headers, []), "x-api-key")

    peer =
      case Map.get(info, :peer_data) do
        %{address: address} -> address |> :inet.ntoa() |> to_string()
        _ -> ""
      end

    case ApiKeys.authenticate(token, peer) do
      {:ok, key} ->
        {:ok, %{account_id: key.account_id, key_id: key.key_id, expires_at: key.expires_at}}

      :error ->
        :error
    end
  end

  def agent(_info), do: :error

  defp header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  defp header(_, _), do: nil
end

defmodule HiremeWeb.FeedSocket do
  @moduledoc """
  Push-only feed of desk signals for the browser shell.

  Connect at `/feed/websocket` with the session cookie; a connection
  without a live session is refused. Every `Hireme.Desk.Signal` on the
  account's topic arrives as one JSON text frame. Frames from the client
  are ignored; writes go over HTTP.
  """

  @behaviour Phoenix.Socket.Transport

  alias Hireme.Accounts
  alias Hireme.Desk
  alias Hireme.Desk.Signal
  alias Hireme.Repo
  alias HiremeWeb.Auth
  alias HiremeWeb.Sockets

  def child_spec(_opts), do: :ignore

  def connect(%{connect_info: %{session: %{} = session}}) do
    case Accounts.session(session[Auth.session_key()]) do
      {_session, account} -> {:ok, %{account_id: account.id}}
      nil -> :error
    end
  end

  def connect(_info), do: :error

  def init(%{account_id: account_id} = state) do
    Repo.put_account(account_id)
    Phoenix.PubSub.subscribe(Hireme.PubSub, Desk.topic(account_id))
    {:ok, state}
  end

  def handle_in(_frame, state), do: {:ok, state}

  def handle_info({:desk_event, %Signal{} = signal}, state),
    do: Sockets.push(Signal.to_json(signal), state)

  def handle_info(_message, state), do: {:ok, state}
  def terminate(_reason, _state), do: :ok
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
