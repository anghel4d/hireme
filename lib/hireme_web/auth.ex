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
  # The column store is a WebAssembly module, so script-src allows that
  # compile (`wasm-unsafe-eval`) and not `eval`; the one inline script is
  # the desk's early connect, allowed by its hash. Fetch and websocket stay
  # on this origin, plus the WebTransport gate when one is configured.
  # Nothing frames the desk.
  @csp_rest [
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "font-src 'self'",
    "frame-ancestors 'none'",
    "base-uri 'none'",
    "object-src 'none'",
    "form-action 'self'"
  ]

  @doc "The WebTransport URL browsers connect to, or nil when no gate is configured."
  @spec wire_gate() :: String.t() | nil
  def wire_gate, do: get_in(HiremeWeb.Gate.client() || %{}, [:url])

  @doc "Certificate hashes for a development gate's self-signed certificate, hex, space-separated."
  @spec wire_hashes() :: String.t()
  def wire_hashes, do: Enum.join(get_in(HiremeWeb.Gate.client() || %{}, [:hashes]) || [], " ")

  @doc "The inline early-connect script, or nothing when the build has none."
  @spec early_script() :: String.t()
  def early_script do
    case early() do
      {js, _hash} -> "<script>#{js}</script>"
      nil -> ""
    end
  end

  defp early do
    case :persistent_term.get({__MODULE__, :early}, :unread) do
      :unread ->
        path = Application.app_dir(:hireme, "priv/static/assets/js/early.js")

        early =
          case File.read(path) do
            {:ok, js} -> {String.trim_trailing(js), nil}
            _ -> nil
          end

        early = early && {elem(early, 0), Base.encode64(:crypto.hash(:sha256, elem(early, 0)))}
        :persistent_term.put({__MODULE__, :early}, early)
        early

      early ->
        early
    end
  end

  defp csp do
    case :persistent_term.get({__MODULE__, :csp}, nil) do
      nil ->
        script = [
          "'self'",
          "'wasm-unsafe-eval'" | (early() && ["'sha256-#{elem(early(), 1)}'"]) || []
        ]

        gate =
          case wire_gate() && URI.parse(wire_gate()) do
            %URI{scheme: "https", host: host, port: port} -> ["https://#{host}:#{port}"]
            _ -> []
          end

        csp =
          Enum.join(
            [
              "default-src 'self'",
              "script-src " <> Enum.join(script, " "),
              "connect-src " <> Enum.join(["'self'" | gate], " ")
            ] ++
              @csp_rest,
            "; "
          )

        :persistent_term.put({__MODULE__, :csp}, csp)
        csp

      csp ->
        csp
    end
  end

  @spec session_key() :: String.t()
  def session_key, do: @session_key

  def fetch_account(conn, _opts) do
    case Accounts.session(get_session(conn, @session_key)) do
      {session, account} ->
        Repo.put_account(account.id)

        conn
        |> assign(:account, account)
        |> assign(:session, session)
        |> assign(:pending, Hireme.Mfa.required?(session))

      nil ->
        Repo.put_account(nil)
        conn |> assign(:account, nil) |> assign(:session, nil) |> assign(:pending, false)
    end
  end

  @doc "A live session that has presented its second factor, if the account has one."
  def require_account(conn, _opts) do
    cond do
      conn.assigns[:account] && not conn.assigns.pending -> conn
      conn.assigns[:account] -> refuse(conn, 401, "second_factor", "/sign-in/factor")
      true -> refuse(conn, 401, "unauthenticated", "/sign-in")
    end
  end

  @doc "A live session that still owes a second factor; anyone else is sent where they belong."
  def require_pending(conn, _opts) do
    cond do
      conn.assigns[:account] && conn.assigns.pending -> conn
      conn.assigns[:account] -> refuse(conn, 409, "signed_in", "/")
      true -> refuse(conn, 401, "unauthenticated", "/sign-in")
    end
  end

  @doc "A second factor presented within the step-up window (ASVS 7.5.1); JSON only."
  def require_step_up(conn, _opts) do
    if Hireme.Mfa.fresh?(conn.assigns.session),
      do: conn,
      else: conn |> put_status(403) |> json(%{error: "step_up"}) |> halt()
  end

  defp refuse(conn, status, error, to) do
    if get_format(conn) == "json",
      do: conn |> put_status(status) |> json(%{error: error}) |> halt(),
      else: conn |> redirect(to: to) |> halt()
  end

  def security_headers(conn, _opts) do
    conn
    |> put_resp_header("content-security-policy", csp())
    |> put_resp_header(
      "permissions-policy",
      "camera=(), microphone=(), geolocation=(), payment=()"
    )
    |> put_resp_header("cross-origin-opener-policy", "same-origin")
    |> put_resp_header("x-frame-options", "DENY")
  end

  @doc """
  Put a session's token in a renewed cookie (ASVS 7.2.4): the token
  `Hireme.Accounts.sign_in_with/3` returns, or a new session for `account`.
  """
  @spec sign_in(Plug.Conn.t(), String.t() | Account.t()) :: Plug.Conn.t()
  def sign_in(conn, %Account{} = account) do
    {token, _session} = Accounts.start_session(account, meta(conn))
    sign_in(conn, token)
  end

  def sign_in(conn, token) when is_binary(token) do
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

  @doc """
  Answer a refusal. A reason atom or changeset maps to the status and
  message the shell expects; `{status, message}` says both outright.
  """
  @spec refuse(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def refuse(conn, reason) do
    {status, message} =
      case reason do
        {status, message} when is_integer(status) -> {status, message}
        :not_found -> {404, "not found"}
        :batch -> {404, "batch"}
        :leased -> {423, "leased"}
        {:argument, name} -> {400, "bad argument #{name}"}
        %Ecto.Changeset{} -> {422, "invalid"}
        other when is_atom(other) -> {409, Atom.to_string(other)}
        other -> {400, inspect(other)}
      end

    conn |> put_status(status) |> json(%{error: message})
  end
end

defmodule HiremeWeb.AuthController do
  @moduledoc """
  Sign-out. The sign-in page and its methods are
  `HiremeWeb.SignInController`. In development only, a button there signs
  into the local desk's account so the desk can be used before any method
  is configured; that route is not compiled into other environments.
  """

  use Phoenix.Controller, formats: [:html]
  alias Hireme.Accounts
  alias HiremeWeb.Auth

  def sign_out(conn, _params), do: conn |> Auth.sign_out() |> redirect(to: "/sign-in")

  def dev_sign_in(conn, _params) do
    conn |> Auth.sign_in(Accounts.use_default!()) |> redirect(to: "/")
  end
end
