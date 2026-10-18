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

  # JSON for a signed-in page: the same cookie, the CSRF token as a header.
  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :security_headers
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
    plug :put_secure_browser_headers
    plug :security_headers
    plug :fetch_account
    plug :require_pending
  end

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
    post "/sign-out", SignInController, :sign_out
  end

  scope "/sign-in/factor", HiremeWeb do
    pipe_through [:browser, :factor]

    get "/", FactorController, :show
    post "/totp", FactorController, :totp
    post "/recovery", FactorController, :recovery
  end

  scope "/sign-in/factor", HiremeWeb do
    pipe_through :factor_json

    post "/webauthn", FactorController, :webauthn
    post "/webauthn/verify", FactorController, :webauthn_verify
  end

  # The one page, under every lens's address; the lens is the client's to read.
  scope "/", HiremeWeb do
    pipe_through [:browser, :signed_in]

    get "/", PageController, :shell
    get "/desk", PageController, :shell
    get "/focus", PageController, :shell
    get "/focus/:no", PageController, :shell
    get "/world", PageController, :shell
    get "/world/:table", PageController, :shell
    get "/atlas", PageController, :shell
    get "/outreach", PageController, :shell
    get "/lanes", PageController, :shell
    get "/lanes/:lane", PageController, :shell
    get "/account", PageController, :shell
  end

  scope "/api", HiremeWeb do
    pipe_through :api

    post "/wire/ticket", PageController, :ticket

    # Adding a way in stays HTTP: it keeps its OAuth trip or the address it
    # expects in the cookie. Everything else on the account rides the wire.
    scope "/account" do
      pipe_through :step_up
      post "/identities", SignInController, :start_link
    end
  end

  if Application.compile_env(:hireme, :dev_routes) do
    scope "/dev", HiremeWeb do
      pipe_through :browser
      post "/sign-in", SignInController, :dev_sign_in
    end

    # The local mail adapter's inbox, where a development sign-in link lands.
    scope "/dev" do
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end

defmodule HiremeWeb.PageController do
  @moduledoc """
  The one page and the ticket that reconnects it. The page is a shell:
  everything it shows arrives over the wire session its early script
  opens with the ticket in its head. A page reload mints a new ticket; a
  reconnect asks `ticket/2` for one.
  """

  use Phoenix.Controller, formats: [:html, :json]
  import Plug.Conn
  alias HiremeWeb.Auth

  def shell(conn, _params) do
    %{account: account, session: session} = conn.assigns
    gate = Auth.wire_gate()

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <link rel="icon" href="data:," />
        <title>Hireme</title>
        <meta name="csrf-token" content="#{Plug.CSRFProtection.get_csrf_token()}" />
        <meta name="hireme-ticket" content="#{Hireme.Accounts.ticket(session)}" />
        <meta name="hireme-gate" content="#{Auth.esc(gate || "")}" />
        <meta name="hireme-gate-hashes" content="#{Auth.esc(Auth.wire_hashes())}" />
        <meta name="hireme-wire" content="#{wire_hash()}" />
        <meta name="hireme-scope" content="#{Hireme.Accounts.scope(account.id)}" />
        <link rel="preload" href="/wasm/kernel.wasm" as="fetch" crossorigin />
        <link rel="modulepreload" href="#{Auth.static("/assets/app.js")}" />
        #{Auth.early_script()}
        <link rel="stylesheet" href="#{Auth.static("/assets/app.css")}" />
        <script type="module" src="#{Auth.static("/assets/app.js")}"></script>
      </head>
      <body>
        <div id="app"></div>
      </body>
    </html>
    """)
  end

  def ticket(conn, _params) do
    case Hireme.Security.limit(:ticket_peer, Auth.meta(conn).ip) do
      :ok ->
        json(conn, %{ticket: Hireme.Accounts.ticket(conn.assigns.session), gate: Auth.wire_gate()})

      {:error, :rate_limited} ->
        conn |> put_status(429) |> json(%{error: "rate_limited"})
    end
  end

  defp wire_hash,
    do:
      Hireme.Schema.wire_hash()
      |> Integer.to_string(16)
      |> String.pad_leading(4, "0")
      |> String.downcase()
end
