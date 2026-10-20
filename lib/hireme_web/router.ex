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
  # The one page, under every lens's address (a view, then an item); the lens is the
  # client's to read. focus and atlas are old addresses the client rewrites.
  @lenses ~w(desk world outreach me account focus atlas)

  @impl true
  def init(opts), do: opts

  @dev Application.compile_env(:hireme, :dev_routes)

  @impl true
  # The local mail adapter's inbox, where a development sign-in link lands.
  if @dev do
    alias Plug.Swoosh.MailboxPreview

    def call(%{path_info: ["dev", "mailbox" | rest]} = conn, _opts),
      do: Plug.forward(conn, rest, MailboxPreview, MailboxPreview.init([]))
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
       when lens in @lenses and length(rest) <= 2,
       do: {:html, [:account], &PageController.shell/2}

  defp route("POST", ["api", "wire", "ticket"]), do: {:json, [:account], &PageController.ticket/2}
  defp route("PUT", ["blobs"]), do: {:json, [:account], &HiremeWeb.Blobs.serve/2}
  defp route("GET", ["blobs", _sha]), do: {:json, [:account], &HiremeWeb.Blobs.serve/2}

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

    head = """
    <meta name="hireme-ticket" content="#{Hireme.Accounts.ticket(session)}" />
    <meta name="hireme-gate" content="#{Auth.esc(gate || "")}" />
    <meta name="hireme-gate-hashes" content="#{Auth.esc(Auth.wire_hashes())}" />
    <meta name="hireme-wire" content="#{wire_hash()}" />
    <meta name="hireme-scope" content="#{Hireme.Accounts.scope(account.id)}" />
    <link rel="preload" href="#{Auth.static("/wasm/kernel.wasm")}" as="fetch" crossorigin />
    <link rel="modulepreload" href="#{Auth.static("/assets/app.js")}" />
    #{Auth.early_script()}
    <script type="module" src="#{Auth.static("/assets/app.js")}"></script>
    """

    # The BOOT ends the body: the head is sent while it is made.
    Auth.document(conn, 200, "Hireme", head, fn ->
      ~s(<body><div id="app"></div><meta name="hireme-boot" content="#{boot(account.id)}" /></body>)
    end)
  end

  def ticket(conn, _params) do
    case Hireme.Security.limit(:ticket_peer, Auth.meta(conn).ip) do
      :ok ->
        json(conn, %{ticket: Hireme.Accounts.ticket(conn.assigns.session), gate: Auth.wire_gate()})

      {:error, :rate_limited} ->
        conn |> put_status(429) |> json(%{error: "rate_limited"})
    end
  end

  # The rows as of now, so the first cards need no round trip (v1's wire-board).
  defp boot(account_id) do
    case Hireme.Sequencer.boot(account_id) do
      {:ok, frame} -> Base.encode64(frame)
      _ -> ""
    end
  end

  defp wire_hash,
    do:
      Hireme.Schema.wire_hash()
      |> Integer.to_string(16)
      |> String.pad_leading(4, "0")
      |> String.downcase()
end

defmodule HiremeWeb.Blobs do
  @moduledoc """
  A CV's files over HTTP (`Hireme.Blobs`). `PUT /blobs` takes the raw body
  (pdf, docx, doc or markdown by its Content-Type, at most 10 MiB) and answers
  `{sha, bytes, type}`, 201 when new and 200 when the account held it;
  `GET /blobs/<sha>` serves it back, named by `?name=` or the newest
  version naming it, inline when a PDF. A browser comes through the router
  (its session and CSRF token); a key comes first (`keyed/1`) and needs
  the corpus bit, write to put and read to get.
  """
  import Bitwise
  import Plug.Conn
  import HiremeWeb, only: [json: 2]
  alias Hireme.{Blobs, Grants, Schema, Security}

  @doc "A request carrying a key, answered before the cookie and the body parsers."
  def keyed(conn) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    ["Bearer " <> secret | _] = get_req_header(conn, "authorization")

    case Hireme.Keys.authenticate(String.trim(secret), ip) do
      {:ok, key} ->
        Hireme.Repo.put_account(key.account_id)
        grants = Grants.key(key)
        may? = if conn.method == "GET", do: &Grants.read?/2, else: &Grants.write?/2

        if may?.(grants, Schema.table(:blobs)),
          do: answer(conn, key.account_id),
          else: conn |> put_status(403) |> json(%{error: "scope"})

      {:error, :rate_limited} ->
        send_resp(conn, 429, "")

      :error ->
        Security.strike(ip)

        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="hireme"))
        |> send_resp(401, "")
    end
  end

  @doc "A browser's request, its session checked by the router."
  def serve(conn, _params), do: answer(conn, conn.assigns.account.id)

  defp answer(%{method: "PUT", path_info: ["blobs"]} = conn, account_id) do
    type = conn |> get_req_header("content-type") |> List.first("") |> String.split(";") |> hd()

    with :ok <- Security.limit(:blob_writes, account_id),
         {:ok, bytes, conn} <- read_body(conn, length: Blobs.max(), read_length: 1 <<< 20),
         {:ok, b} <- Blobs.put(account_id, bytes, type |> String.trim() |> String.downcase()) do
      conn |> put_status(if(b.new, do: 201, else: 200)) |> json(Map.delete(b, :new))
    else
      {:error, :rate_limited} ->
        conn |> put_status(429) |> json(%{error: "rate"})

      {:more, _, conn} ->
        conn |> put_status(413) |> json(%{error: "too_large"})

      {:error, e} when e in [:type, :too_large, :cap] ->
        conn |> put_status(status(e)) |> json(%{error: e})

      {:error, _} ->
        send_resp(conn, 400, "")
    end
  end

  defp answer(%{method: "GET", path_info: ["blobs", sha]} = conn, account_id) do
    conn = fetch_query_params(conn)

    case Hireme.Repo.with_account(account_id, fn ->
           {Blobs.about(sha, [:data]), Blobs.name(sha)}
         end) do
      {nil, _} ->
        send_resp(conn, 404, "")

      {b, newest} ->
        name = conn.query_params["name"] || newest || sha
        how = if b.type == "application/pdf", do: "inline", else: "attachment"
        plain = String.replace(name, ~r/[^ -~]|["\\]/, "_")

        conn
        |> put_resp_content_type(b.type, nil)
        |> put_resp_header(
          "content-disposition",
          ~s(#{how}; filename="#{plain}"; filename*=UTF-8''#{URI.encode(name, &URI.char_unreserved?/1)})
        )
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
        |> send_resp(200, b.data)
    end
  end

  defp answer(conn, _account_id), do: send_resp(conn, 404, "")

  defp status(:type), do: 415
  defp status(:too_large), do: 413
  defp status(:cap), do: 409
end
