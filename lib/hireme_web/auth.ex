defmodule HiremeWeb.Auth do
  @moduledoc """
  Who is asking. `fetch_account/2` reads the session cookie, finds the
  live session row, and names its account on the process so every read
  after it is that account's. `require_account/2` answers 401 to JSON
  and sends a page to sign in. `security_headers/2` is the browser
  policy (ASVS 5.0 V3.4).

  The cookie is `__Host-hireme`: Secure, HttpOnly, SameSite=Lax, path
  `/`, no Domain (ASVS 3.3.1, 3.3.3, 3.3.4). It holds only the session
  token; the session itself is a row (ASVS 7.2.1).
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2, redirect: 2, get_format: 1]

  alias Hireme.Accounts
  alias Hireme.Accounts.Account
  alias Hireme.Repo

  @session_key "hireme_session"

  # Scripts and styles are this origin's; cards carry inline positions.
  # Fetch and websocket stay on this origin. Nothing frames the desk.
  @csp Enum.join(
         [
           "default-src 'self'",
           "script-src 'self'",
           "style-src 'self' 'unsafe-inline'",
           "img-src 'self' data:",
           "connect-src 'self'",
           "font-src 'self'",
           "frame-ancestors 'none'",
           "base-uri 'none'",
           "object-src 'none'",
           "form-action 'self'"
         ],
         "; "
       )

  @spec session_key() :: String.t()
  def session_key, do: @session_key

  def fetch_account(conn, _opts) do
    case Accounts.session(get_session(conn, @session_key)) do
      {session, account} ->
        Repo.put_account(account.id)
        conn |> assign(:account, account) |> assign(:session, session)

      nil ->
        Repo.put_account(nil)
        conn |> assign(:account, nil) |> assign(:session, nil)
    end
  end

  def require_account(conn, _opts) do
    cond do
      conn.assigns[:account] ->
        conn

      get_format(conn) == "json" ->
        conn |> put_status(401) |> json(%{error: "unauthenticated"}) |> halt()

      true ->
        conn |> redirect(to: "/sign-in") |> halt()
    end
  end

  def security_headers(conn, _opts) do
    conn
    |> put_resp_header("content-security-policy", @csp)
    |> put_resp_header(
      "permissions-policy",
      "camera=(), microphone=(), geolocation=(), payment=()"
    )
    |> put_resp_header("cross-origin-opener-policy", "same-origin")
  end

  @doc "Open a session for `account` and put its token in a renewed cookie (ASVS 7.2.4)."
  @spec sign_in(Plug.Conn.t(), Account.t()) :: Plug.Conn.t()
  def sign_in(conn, %Account{} = account) do
    {token, _session} = Accounts.start_session(account, meta(conn))

    conn
    |> configure_session(renew: true)
    |> put_session(@session_key, token)
  end

  @doc "Revoke this session's row and drop the cookie."
  @spec sign_out(Plug.Conn.t()) :: Plug.Conn.t()
  def sign_out(conn) do
    if session = conn.assigns[:session], do: Accounts.revoke_session(session)
    configure_session(conn, drop: true)
  end

  @doc "Where a request came from, for the audit trail."
  @spec meta(Plug.Conn.t()) :: Hireme.Accounts.meta()
  def meta(conn) do
    %{
      ip: conn.remote_ip |> :inet.ntoa() |> to_string(),
      user_agent: conn |> get_req_header("user-agent") |> List.first() |> to_string()
    }
  end
end

defmodule HiremeWeb.AuthController do
  @moduledoc """
  The sign-in page and sign-out. Sign-in itself is passwordless: an
  email link, GitHub, or X, each a route beside this one that ends in
  `HiremeWeb.Auth.sign_in/2`. In development only, a button signs into
  the local desk's account so the desk can be used before any of those
  is configured; that route is not compiled into other environments.
  """

  use Phoenix.Controller, formats: [:html]
  import Plug.Conn
  alias Hireme.Accounts
  alias HiremeWeb.Auth

  def sign_in(%{assigns: %{account: %{}}} = conn, _params), do: redirect(conn, to: "/")

  def sign_in(conn, _params) do
    csrf = Plug.CSRFProtection.get_csrf_token()

    dev =
      if Application.get_env(:hireme, :dev_routes) do
        """
        <form method="post" action="/dev/sign-in" class="method">
          <input type="hidden" name="_csrf_token" value="#{csrf}" />
          <button type="submit" class="primary">Sign in to the local desk (development)</button>
        </form>
        """
      else
        ""
      end

    page = """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Sign in · Hireme</title>
        <link rel="stylesheet" href="/assets/js/app.css" />
      </head>
      <body class="sign-in">
        <main class="sign-in-card">
          <h1>HIREME</h1>
          <p class="lede">No passwords. Sign in with a link to your email, with GitHub, or with X.</p>
          <form method="post" action="/sign-in/email" class="method">
            <input type="hidden" name="_csrf_token" value="#{csrf}" />
            <label for="email">Email</label>
            <input id="email" type="email" name="email" autocomplete="email" required placeholder="you@example.com" />
            <button type="submit" class="primary">Send a sign-in link</button>
          </form>
          <p class="or">or</p>
          <a class="ghost method" href="/auth/github">Continue with GitHub</a>
          <a class="ghost method" href="/auth/x">Continue with X</a>
          #{dev}
        </main>
      </body>
    </html>
    """

    conn |> put_resp_content_type("text/html") |> send_resp(200, page)
  end

  def sign_out(conn, _params), do: conn |> Auth.sign_out() |> redirect(to: "/sign-in")

  def dev_sign_in(conn, _params) do
    conn |> Auth.sign_in(Accounts.use_default!()) |> redirect(to: "/")
  end
end
