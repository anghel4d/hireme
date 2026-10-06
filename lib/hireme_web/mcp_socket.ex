defmodule HiremeWeb.McpDirectorySocket do
  @moduledoc """
  Read-only directory of letterboxes.

  Connect at `/mcp/websocket`. This socket cannot lease and cannot write.
  """

  @behaviour Phoenix.Socket.Transport

  def child_spec(_opts), do: :ignore

  def connect(_info), do: {:ok, %{}}

  def init(state), do: {:ok, state}

  def handle_in({text, _opts}, state) do
    response =
      case Jason.decode(text) do
        {:ok, message} -> Hireme.Mcp.directory(message)
        _ -> %{error: %{code: -32700, message: "parse error"}}
      end

    {:reply, :ok, {:text, Jason.encode!(response)}, state}
  end

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

  alias Hireme.Letterbox
  alias Hireme.Letterbox.Handle

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

  def handle_in({text, _opts}, %{handle: %Handle{} = handle} = state) do
    response =
      case Jason.decode(text) do
        {:ok, message} -> Hireme.Mcp.handle(handle, message)
        _ -> %{error: %{code: -32700, message: "parse error"}}
      end

    {:reply, :ok, {:text, Jason.encode!(response)}, state}
  end

  def handle_info({:desk_event, event}, state) do
    {:push, {:text, Jason.encode!(%{method: "notifications/desk", params: event})}, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  def terminate(_reason, %{handle: %Handle{} = handle}) do
    Letterbox.release(handle)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
