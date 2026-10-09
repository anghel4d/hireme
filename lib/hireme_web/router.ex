defmodule HiremeWeb.Router do
  use Phoenix.Router, helpers: false
  import Plug.Conn
  import Phoenix.Controller

  import HiremeWeb.Auth,
    only: [
      fetch_account: 2,
      require_account: 2,
      require_pending: 2,
      require_step_up: 2,
      security_headers: 2
    ]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :security_headers
    plug :fetch_account
  end

  # JSON for the signed-in shell: the same cookie, the same CSRF token
  # (sent as a header), and no account means 401.
  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :fetch_account
    plug :require_account
  end

  pipeline :signed_in do
    plug :require_account
  end

  # A session that owes its second factor may reach only the factor page.
  pipeline :factor do
    plug :require_pending
  end

  pipeline :factor_json do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :fetch_account
    plug :require_pending
  end

  # A sensitive change needs a second factor presented within the window.
  pipeline :step_up do
    plug :require_step_up
  end

  scope "/", HiremeWeb do
    pipe_through :browser

    get "/sign-in", SignInController, :index
    post "/sign-in/email", SignInController, :request_email
    get "/sign-in/email", SignInController, :confirm_email
    post "/sign-in/email/confirm", SignInController, :redeem_email
    get "/auth/:provider", SignInController, :authorize
    get "/auth/:provider/callback", SignInController, :callback
    post "/sign-out", AuthController, :sign_out
  end

  scope "/", HiremeWeb do
    pipe_through [:browser, :signed_in]

    get "/", DeskController, :index
  end

  scope "/sign-in/factor", HiremeWeb do
    pipe_through [:browser, :factor]

    get "/", MfaController, :factor
    post "/totp", MfaController, :factor_totp
    post "/recovery", MfaController, :factor_recovery
  end

  scope "/sign-in/factor", HiremeWeb do
    pipe_through :factor_json

    post "/webauthn", MfaController, :factor_webauthn
    post "/webauthn/confirm", MfaController, :factor_webauthn_confirm
  end

  # Development only: sign into the local desk with one click. Not
  # compiled into any other environment.
  if Application.compile_env(:hireme, :dev_routes) do
    scope "/dev", HiremeWeb do
      pipe_through :browser

      post "/sign-in", AuthController, :dev_sign_in
    end

    # The local mail adapter's inbox, where a development sign-in link lands.
    scope "/dev" do
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  scope "/api", HiremeWeb do
    pipe_through :api

    # The account page rides the wire session (`HiremeWeb.Account`). Only
    # adding a way in stays here: it keeps its OAuth trip or the expected
    # address in the cookie.
    scope "/account" do
      pipe_through :step_up

      post "/identities", AccountController, :link
    end

    post "/wire/ticket", DeskController, :wire_ticket
  end
end

defmodule HiremeWeb.DeskController do
  @moduledoc """
  The page the shell draws on and the ticket that reconnects it. The
  desk itself travels as frames over the wire session (`HiremeWeb.Session`);
  only the account's settings and factors stay HTTP.
  """

  use Phoenix.Controller, formats: [:html, :json]

  use Phoenix.VerifiedRoutes,
    endpoint: HiremeWeb.Endpoint,
    router: HiremeWeb.Router,
    statics: HiremeWeb.static_paths()

  import Plug.Conn

  def index(conn, _params) do
    %{account: account, session: session} = conn.assigns
    # The board travels in the page, so the first card waits on no socket.
    {rev, board} = HiremeWeb.Session.board(account.id, session.id)

    page = """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Desk · Hireme</title>
        <meta name="csrf-token" content="#{Plug.CSRFProtection.get_csrf_token()}" />
        <meta name="wire-ticket" content="#{HiremeWeb.Session.ticket(account.id, session.id)}" />
        <meta name="wire-gate" content="#{HiremeWeb.Auth.wire_gate() || ""}" />
        <meta name="wire-gate-hashes" content="#{HiremeWeb.Auth.wire_hashes()}" />
        <meta name="wire-scope" content="#{HiremeWeb.Session.scope(account.id)}" />
        <meta name="wire-schema" content="#{HiremeWeb.Packet.schema_hash()}" />
        <meta name="wire-board" content="#{rev}:#{Base.encode64(board)}" />
        <link rel="preload" href="/wasm/kernel.wasm" as="fetch" crossorigin />
        #{HiremeWeb.Auth.early_script()}
        <link rel="stylesheet" href="#{~p"/assets/js/app.css"}" />
        <script defer type="module" src="#{~p"/assets/js/app.js"}"></script>
      </head>
      <body>
        <div id="desk" class="desk"></div>
      </body>
    </html>
    """

    conn |> put_resp_content_type("text/html") |> send_resp(200, page)
  end

  # A fresh single-use ticket for a reconnect after the last one was spent.
  def wire_ticket(conn, _params) do
    %{account: account, session: session} = conn.assigns

    json(conn, %{
      ticket: HiremeWeb.Session.ticket(account.id, session.id),
      gate: HiremeWeb.Auth.wire_gate()
    })
  end
end
