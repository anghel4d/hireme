defmodule HiremeWeb do
  @moduledoc """
  The web layer: one endpoint, one router, a push feed, two agent
  sockets, and the page the shell draws on. Reads are JSON or one
  columnar packet; every write answers with the new focus or a status
  code that says why not. A browser is an account's session; an agent
  is an account's API key; neither sees another account.
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

  # The one cookie. `__Host-` pins it to this origin and path `/` over
  # https (localhost counts). Its contents are encrypted and signed with
  # keys derived from the application secret; it holds the session token
  # and the CSRF token, nothing else.
  @session_options [
    store: :cookie,
    key: "__Host-hireme",
    signing_salt: "hireme-session-sign",
    encryption_salt: "hireme-session-seal",
    same_site: "Lax",
    secure: true,
    http_only: true,
    max_age: 24 * 60 * 60
  ]

  # The browser's feed authenticates with the same cookie; an agent's
  # socket authenticates with an API key in the `x-api-key` header or the
  # `base64url.bearer.phx.<base64 key>` websocket subprotocol.
  socket "/feed", HiremeWeb.FeedSocket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  socket "/mcp", HiremeWeb.McpDirectorySocket,
    websocket: [connect_info: [:x_headers, :peer_data], auth_token: true],
    longpoll: false

  socket "/mcp/letterbox/:letterbox_id", HiremeWeb.McpSocket,
    websocket: [connect_info: [:x_headers, :peer_data], auth_token: true],
    longpoll: false

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
  # Pages post forms (urlencoded, carrying `_csrf_token`); the shell posts JSON.
  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.Head
  plug Plug.Session, @session_options
  plug HiremeWeb.Router
end
