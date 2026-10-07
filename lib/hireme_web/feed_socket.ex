defmodule HiremeWeb.FeedSocket do
  @moduledoc """
  Push-only feed of desk signals for the browser shell.

  Connect at `/feed/websocket`. Every `Hireme.Desk.Signal` arrives as
  one JSON text frame. Frames from the client are ignored; writes go
  over HTTP.
  """

  @behaviour Phoenix.Socket.Transport

  alias Hireme.Desk
  alias Hireme.Desk.Signal

  def child_spec(_opts), do: :ignore

  def connect(_info), do: {:ok, %{}}

  def init(state) do
    Phoenix.PubSub.subscribe(Hireme.PubSub, Desk.topic())
    {:ok, state}
  end

  def handle_in(_frame, state), do: {:ok, state}

  def handle_info({:desk_event, %Signal{} = signal}, state) do
    {:push, {:text, Jason.encode!(Signal.to_json(signal))}, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  def terminate(_reason, _state), do: :ok
end
