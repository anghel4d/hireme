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

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.Head
  plug HiremeWeb.Router
end
