defmodule HiremeWeb do
  @moduledoc """
  The web layer: one endpoint, one router, the page the shell draws on,
  the cookie-bound sign-in routes, and the sockets. The desk itself is
  one wire session per tab or agent (`HiremeWeb.Session`), over
  WebTransport through the gate or the `/wire` WebSocket: raw rows down,
  ops and account commands up. A browser is an account's session; an
  agent is an account's API key; neither sees another account.
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

  # The desk session where UDP is blocked: the WebTransport frames, binary.
  socket "/wire", HiremeWeb.WireSocket,
    websocket: [connect_info: [:peer_data, session: @session_options], max_frame_size: 1_048_576],
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
