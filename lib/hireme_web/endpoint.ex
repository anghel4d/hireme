defmodule HiremeWeb do
  @moduledoc """
  The web layer: one endpoint, one router, a push feed, two agent
  sockets, and the page the shell draws on. Reads are JSON or one
  columnar packet; every write answers with the new focus or a status
  code that says why not.
  """

  def static_paths, do: ~w(assets wasm fonts images favicon.ico robots.txt)
end

defmodule HiremeWeb.ErrorHTML do
  @moduledoc "Plain-text error pages, named by status."
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule HiremeWeb.ErrorJSON do
  @moduledoc "Error bodies for JSON requests, named by status."
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end

defmodule HiremeWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :hireme

  socket "/feed", HiremeWeb.FeedSocket, websocket: true, longpoll: false
  socket "/mcp", HiremeWeb.McpDirectorySocket, websocket: true, longpoll: false
  socket "/mcp/letterbox/:letterbox_id", HiremeWeb.McpSocket, websocket: true, longpoll: false

  plug Plug.Static,
    at: "/",
    from: :hireme,
    gzip: not code_reloading?,
    only: HiremeWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :hireme
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Phoenix.json_library()
  plug Plug.Head
  plug HiremeWeb.Router
end
