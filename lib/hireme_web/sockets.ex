defmodule HiremeWeb.Sockets do
  @moduledoc false
  # What the three transports share: one JSON object per text frame.

  def reply(text, state, respond) do
    response =
      case Jason.decode(text) do
        {:ok, message} -> respond.(message)
        _ -> %{error: %{code: -32700, message: "parse error"}}
      end

    {:reply, :ok, {:text, Jason.encode!(response)}, state}
  end

  def push(payload, state), do: {:push, {:text, Jason.encode!(payload)}, state}
end

defmodule HiremeWeb.FeedSocket do
  @moduledoc """
  Push-only feed of desk signals for the browser shell.

  Connect at `/feed/websocket`. Every `Hireme.Desk.Signal` arrives as
  one JSON text frame. Frames from the client are ignored; writes go
  over HTTP.
  """

  @behaviour Phoenix.Socket.Transport

  alias Hireme.Desk.Signal
  alias HiremeWeb.Sockets

  def child_spec(_opts), do: :ignore
  def connect(_info), do: {:ok, %{}}

  def init(state) do
    Phoenix.PubSub.subscribe(Hireme.PubSub, Hireme.Desk.topic())
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
  Read-only directory of letterboxes.

  Connect at `/mcp/websocket`. This socket cannot lease and cannot write.
  """

  @behaviour Phoenix.Socket.Transport

  alias HiremeWeb.Sockets

  def child_spec(_opts), do: :ignore
  def connect(_info), do: {:ok, %{}}
  def init(state), do: {:ok, state}
  def handle_in({text, _opts}, state), do: Sockets.reply(text, state, &Hireme.Mcp.directory/1)
  def handle_info(_message, state), do: {:ok, state}
  def terminate(_reason, _state), do: :ok
end

defmodule HiremeWeb.McpSocket do
  @moduledoc """
  Full-duplex websocket for one leased letterbox.

  Connect at `/mcp/letterbox/:letterbox_id/websocket`. The connection
  process is the single producer. The letterbox process is the single
  consumer. A second connection for that id is refused.
  """

  @behaviour Phoenix.Socket.Transport

  alias Hireme.Desk.Signal
  alias Hireme.Letterbox
  alias Hireme.Letterbox.Handle
  alias HiremeWeb.Sockets

  def child_spec(_opts), do: :ignore

  def connect(%{params: %{"letterbox_id" => raw}}) do
    case Integer.parse(to_string(raw)) do
      {id, ""} when id > 0 ->
        cond do
          not Letterbox.exists?(id) -> :error
          Letterbox.leased?(id) -> {:error, :busy}
          true -> {:ok, %{id: id}}
        end

      _ ->
        :error
    end
  end

  def connect(_info), do: :error

  def init(%{id: id}) do
    case Letterbox.lease(id, self()) do
      {:ok, %Handle{} = handle} -> {:ok, %{handle: handle}}
      {:error, reason} -> {:stop, reason, %{}}
    end
  end

  def handle_in({text, _opts}, %{handle: %Handle{} = handle} = state),
    do: Sockets.reply(text, state, &Hireme.Mcp.handle(handle, &1))

  def handle_info({:desk_event, %Signal{} = signal}, state),
    do: Sockets.push(%{method: "notifications/desk", params: Signal.to_json(signal)}, state)

  def handle_info(_message, state), do: {:ok, state}

  def terminate(_reason, %{handle: %Handle{} = handle}) do
    Letterbox.release(handle)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
