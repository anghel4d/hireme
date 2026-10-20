defmodule HiremeWeb.Auth do
  @moduledoc """
  Who is asking, and the browser policy.

  `fetch_account/2` reads the session cookie, finds the live session row,
  and names its account on the process so every read after it is that
  account's. `require_account/2` lets through a session that is past its
  second factor; `require_pending/2` only one that still owes it;
  `require_step_up/2` only one fresh for a sensitive change (ASVS 7.5.1).
  A JSON request is refused with a status and `{"error": ...}`; a page is
  redirected where it belongs.

  The cookie is `__Host-hireme`: Secure, HttpOnly, SameSite=Lax, path
  `/`, no Domain (ASVS 3.3.1, 3.3.3, 3.3.4). It holds the session token;
  the session itself is a row (ASVS 7.2.1).

  The CSP: scripts are this origin's plus the inlined early script by its
  hash, and WebAssembly may compile (`wasm-unsafe-eval`), never `eval`;
  styles are this origin's only; fetch and sockets stay on this origin
  plus the gate when one runs; nothing frames the page (ASVS 3.4).
  """

  import Plug.Conn
  import HiremeWeb, only: [json: 2, redirect: 2]

  alias Hireme.{Accounts, Repo}
  alias HiremeWeb.Gate

  @session_key "hireme_session"

  @csp_rest [
    "style-src 'self'",
    "img-src 'self' data:",
    "font-src 'self'",
    "worker-src 'none'",
    "frame-ancestors 'none'",
    "base-uri 'none'",
    "object-src 'none'",
    "form-action 'self'"
  ]

  @doc "The WebTransport URL a page connects to, or nil when no gate runs."
  @spec wire_gate() :: String.t() | nil
  def wire_gate, do: if(gate?(), do: Gate.url())

  @doc "The development gate's self-signed certificate hashes, hex, space-separated."
  @spec wire_hashes() :: String.t()
  def wire_hashes, do: (gate?() && Gate.cert_hash()) || ""

  defp gate?,
    do: Application.get_env(:hireme, :gate, true) and Code.ensure_loaded?(Gate)

  @doc "A static path through the digest manifest in production."
  @spec static(String.t()) :: String.t()
  def static(path), do: HiremeWeb.Endpoint.static_path(path)

  @doc "The inlined early script, or nothing before the first asset build."
  @spec early_script() :: String.t()
  def early_script do
    case early() do
      {js, _hash} -> "<script>#{js}</script>"
      nil -> ""
    end
  end

  # Read once per node: the script and its hash are a release's constants.
  defp early do
    memo(:early, fn ->
      case File.read(Application.app_dir(:hireme, "priv/static/assets/early.js")) do
        {:ok, js} ->
          js = String.trim_trailing(js)
          {js, Base.encode64(:crypto.hash(:sha256, js))}

        _ ->
          nil
      end
    end)
  end

  # A release constant read from priv once; nothing is kept before the first asset build.
  defp memo(key, read) do
    case :persistent_term.get({__MODULE__, key}, :unread) do
      :unread ->
        value = read.()
        if value, do: :persistent_term.put({__MODULE__, key}, value)
        value

      value ->
        value
    end
  end

  @doc "The Content-Security-Policy header value."
  @spec csp() :: String.t()
  def csp do
    script = [
      "'self'",
      "'wasm-unsafe-eval'" | for({_, hash} <- List.wrap(early()), do: "'sha256-#{hash}'")
    ]

    gate =
      case wire_gate() && URI.parse(wire_gate()) do
        %URI{scheme: "https", host: host, port: port} -> ["https://#{host}:#{port}"]
        _ -> []
      end

    Enum.join(
      [
        "default-src 'self'",
        "script-src " <> Enum.join(script, " "),
        "connect-src " <> Enum.join(["'self'" | gate], " ")
      ] ++
        @csp_rest,
      "; "
    )
  end

  def security_headers(conn, _opts) do
    conn
    |> put_resp_header("content-security-policy", csp())
    |> put_resp_header(
      "permissions-policy",
      "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
    )
    |> put_resp_header("cross-origin-opener-policy", "same-origin")
    |> put_resp_header("cross-origin-resource-policy", "same-origin")
    |> put_resp_header("referrer-policy", "same-origin")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-permitted-cross-domain-policies", "none")
  end

  @spec session_key() :: String.t()
  def session_key, do: @session_key

  def fetch_account(conn, _opts) do
    token = get_session(conn, @session_key)

    case Accounts.session(token) do
      {session, account} ->
        Repo.put_account(account.id)

        conn
        |> assign(:account, account)
        |> assign(:session, session)
        |> assign(:pending, Hireme.Mfa.required?(session))

      nil ->
        Repo.put_account(nil)

        conn
        |> ended(token)
        |> assign(:account, nil)
        |> assign(:session, nil)
        |> assign(:pending, false)
    end
  end

  # A cookie whose session ended elsewhere (revoked, expired, idle, the
  # account suspended) is a sign-out the browser did not ask for: its token
  # goes, and with it the desk the page stored, as on /sign-out; but a
  # remembered session that only ran out of time keeps it for the next
  # sign-in (Accounts.keeps_desk?/1).
  defp ended(conn, nil), do: conn

  defp ended(conn, token) do
    conn = delete_session(conn, @session_key)

    if Accounts.keeps_desk?(token),
      do: conn,
      else: put_resp_header(conn, "clear-site-data", ~s("storage"))
  end

  def require_account(conn, _opts), do: need(conn, false, 401, "second_factor", "/sign-in/factor")
  def require_pending(conn, _opts), do: need(conn, true, 409, "signed_in", "/")

  defp need(conn, pending?, status, error, to) do
    cond do
      conn.assigns[:account] && conn.assigns.pending == pending? -> conn
      conn.assigns[:account] -> refuse(conn, status, error, to)
      true -> refuse(conn, 401, "unauthenticated", "/sign-in")
    end
  end

  def require_step_up(conn, _opts) do
    if Hireme.Mfa.fresh?(conn.assigns.session),
      do: conn,
      else: conn |> put_status(403) |> json(%{error: "step_up"}) |> halt()
  end

  defp refuse(conn, status, error, to) do
    if conn.private[:format] == "json",
      do: conn |> put_status(status) |> json(%{error: error}) |> halt(),
      else: conn |> redirect(to: to) |> halt()
  end

  @doc "Put a new session's token in a renewed cookie (ASVS 7.2.4)."
  @spec sign_in(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def sign_in(conn, token) when is_binary(token) do
    conn |> configure_session(renew: true) |> put_session(@session_key, token)
  end

  @doc """
  Revoke this session's row, which ends its wire sessions, drop the cookie,
  and have the browser clear the desk's stored snapshot (Clear-Site-Data,
  ASVS 7.4.1): the snapshot holds the account's rows.
  """
  @spec sign_out(Plug.Conn.t()) :: Plug.Conn.t()
  def sign_out(conn) do
    if s = conn.assigns[:session], do: Accounts.revoke_session(s.account_id, s.id, meta(conn))

    conn
    |> configure_session(drop: true)
    |> put_resp_header("clear-site-data", ~s("storage"))
  end

  @doc "Where a request came from, for the trail."
  @spec meta(Plug.Conn.t()) :: Accounts.meta()
  def meta(conn) do
    %{
      ip: conn.remote_ip |> :inet.ntoa() |> to_string(),
      user_agent: conn |> get_req_header("user-agent") |> List.first() |> to_string()
    }
  end

  @spec esc(term()) :: String.t()
  def esc(text), do: text |> to_string() |> Plug.HTML.html_escape() |> IO.iodata_to_binary()

  @doc """
  An HTTP-only ceremony page: no script unless `script` names one, no
  inline style, the auth card the stylesheet draws.
  """
  @spec page(Plug.Conn.t(), pos_integer(), String.t(), iodata(), keyword()) :: Plug.Conn.t()
  def page(conn, status, title, body, opts \\ []) do
    script =
      if s = opts[:script], do: ~s(<script type="module" src="#{static(s)}"></script>), else: ""

    document(conn, status, "#{esc(title)} · Hireme", script, """
    <body class="auth"><main class="auth-card"><h1>hireme</h1>
    #{body}
    </main></body>
    """)
  end

  @doc "A whole page, never cached: the CSRF token, `head`, then the stylesheet."
  @spec document(Plug.Conn.t(), pos_integer(), String.t(), iodata(), iodata() | (-> iodata())) ::
          Plug.Conn.t()
  def document(conn, status, title, head, body) do
    conn =
      conn
      |> put_resp_content_type("text/html")
      |> put_resp_header("cache-control", "no-store")

    top = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link rel="icon" href="data:," />
    <meta name="csrf-token" content="#{Plug.CSRFProtection.get_csrf_token()}" />
    <title>#{title}</title>
    #{head}
    <link rel="stylesheet" href="#{static("/assets/app.css")}" />
    </head>
    """

    # A body made by a function follows the head, sent first so the page's fetches start meanwhile.
    if is_function(body, 0) do
      conn = send_chunked(conn, status)

      with {:ok, conn} <- chunk(conn, top),
           {:ok, conn} <- chunk(conn, [body.(), "\n</html>\n"]),
           do: conn,
           else: (_ -> conn)
    else
      send_resp(conn, status, [top, body, "\n</html>\n"])
    end
  end

  @doc "A form's hidden CSRF field."
  @spec csrf_field() :: String.t()
  def csrf_field,
    do:
      ~s(<input type="hidden" name="_csrf_token" value="#{Plug.CSRFProtection.get_csrf_token()}" />)

  @doc "A notice line, or nothing."
  @spec notice(String.t() | nil) :: String.t()
  def notice(nil), do: ""
  def notice(text), do: ~s(<p class="notice" role="alert">#{esc(text)}</p>)
end
