defmodule HiremeWeb.Router do
  @moduledoc """
  Every route, matched on method and path. A page request (`html`) and a
  page's script (`json`) both read the session cookie, check the CSRF
  token, get the browser policy and name their account; then a route may
  ask for a signed-in session (`:account`), one that still owes its
  second factor (`:pending`, the factor page alone), or one fresh for a
  sensitive change (`:step_up`).
  """
  @behaviour Plug
  import Plug.Conn
  alias HiremeWeb.{Auth, FactorController, PageController, SignInController}

  @csrf Plug.CSRFProtection.init([])
  @gates %{
    account: &Auth.require_account/2,
    pending: &Auth.require_pending/2,
    step_up: &Auth.require_step_up/2
  }
  # The one page, under every lens's address; the lens is the client's to read.
  @lenses ~w(desk focus world atlas outreach lanes account)
  @lens_params ~w(focus world lanes)

  @impl true
  def init(opts), do: opts

  @dev Application.compile_env(:hireme, :dev_routes)

  @impl true
  # The local mail adapter's inbox, where a development sign-in link lands.
  if @dev do
    def call(%{path_info: ["dev", "mailbox" | rest]} = conn, _opts),
      do:
        Plug.forward(conn, rest, Plug.Swoosh.MailboxPreview, Plug.Swoosh.MailboxPreview.init([]))
  end

  def call(conn, _opts) do
    case route(conn.method, conn.path_info) do
      {format, gates, action} -> pipe(conn, format, gates, action, %{})
      {format, gates, action, params} -> pipe(conn, format, gates, action, params)
      nil -> send_resp(conn, 404, "Not Found")
    end
  end

  defp route("GET", ["sign-in"]), do: {:html, [], &SignInController.index/2}
  defp route("POST", ["sign-in", "email"]), do: {:html, [], &SignInController.request_email/2}
  defp route("GET", ["sign-in", "email"]), do: {:html, [], &SignInController.confirm_email/2}

  defp route("POST", ["sign-in", "email", "confirm"]),
    do: {:html, [], &SignInController.redeem_email/2}

  defp route("GET", ["auth", p]),
    do: {:html, [], &SignInController.authorize/2, %{"provider" => p}}

  defp route("GET", ["auth", p, "callback"]),
    do: {:html, [], &SignInController.callback/2, %{"provider" => p}}

  defp route("POST", ["sign-out"]), do: {:html, [], &SignInController.sign_out/2}
  defp route("GET", ["sign-in", "factor"]), do: {:html, [:pending], &FactorController.show/2}

  defp route("POST", ["sign-in", "factor", "totp"]),
    do: {:html, [:pending], &FactorController.totp/2}

  defp route("POST", ["sign-in", "factor", "recovery"]),
    do: {:html, [:pending], &FactorController.recovery/2}

  defp route("POST", ["sign-in", "factor", "webauthn"]),
    do: {:json, [:pending], &FactorController.webauthn/2}

  defp route("POST", ["sign-in", "factor", "webauthn", "verify"]),
    do: {:json, [:pending], &FactorController.webauthn_verify/2}

  defp route("GET", []), do: {:html, [:account], &PageController.shell/2}

  defp route("GET", [lens | rest])
       when lens in @lenses and (rest == [] or (lens in @lens_params and length(rest) == 1)),
       do: {:html, [:account], &PageController.shell/2}

  defp route("POST", ["api", "wire", "ticket"]), do: {:json, [:account], &PageController.ticket/2}

  # Adding a way in stays HTTP: it keeps its OAuth trip or the address it
  # expects in the cookie. Everything else on the account rides the wire.
  defp route("POST", ["api", "account", "identities"]),
    do: {:json, [:account, :step_up], &SignInController.start_link/2}

  if @dev,
    do: defp(route("POST", ["dev", "sign-in"]), do: {:html, [], &SignInController.dev_sign_in/2})

  defp route(_, _), do: nil

  defp pipe(conn, format, gates, action, params) do
    conn =
      %{conn | path_params: params, params: Map.merge(conn.params, params)}
      |> put_private(:format, Atom.to_string(format))
      |> fetch_session()
      |> Plug.CSRFProtection.call(@csrf)
      |> Auth.security_headers([])
      |> Auth.fetch_account([])
      |> then(
        &Enum.reduce(gates, &1, fn gate, c -> if c.halted, do: c, else: @gates[gate].(c, []) end)
      )

    if conn.halted, do: conn, else: action.(conn, conn.params)
  end
end

defmodule HiremeWeb.PageController do
  @moduledoc """
  The one page and the ticket that reconnects it. The page is a shell:
  everything it shows arrives over the wire session its early script
  opens with the ticket in its head. A page reload mints a new ticket; a
  reconnect asks `ticket/2` for one.
  """

  import Plug.Conn
  import HiremeWeb, only: [json: 2]
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
