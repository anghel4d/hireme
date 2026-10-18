defmodule HiremeWeb do
  @moduledoc """
  The web layer: one endpoint, one router, one page, the HTTP-only
  ceremonies (sign-in and the factor page), and the wire's WebSocket
  carrier. Everything else is one wire session per tab or agent
  (`HiremeWeb.Session`), over WebTransport through the gate or `/wire`.
  A browser is an account's session; an agent is an account's key;
  neither sees another account.
  """

  def static_paths, do: ~w(assets wasm)
end

defmodule HiremeWeb.ErrorHTML do
  @moduledoc """
  Error pages, named by status, as plain text. It is also the html format
  encoder (`config :phoenix, :format_encoders`): the node renders no
  templates, so there is nothing for an HTML engine to do.
  """
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)

  def encode_to_iodata!(text) when is_binary(text), do: text
end

defmodule HiremeWeb.ErrorJSON do
  @moduledoc "Error bodies for JSON requests, named by status."
  def render(template, _assigns),
    do: %{error: Phoenix.Controller.status_message_from_template(template)}
end

defmodule HiremeWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :hireme
  import Bitwise, only: [>>>: 2, &&&: 2]

  # The one cookie. `__Host-` pins it to this origin, path `/`, over https
  # (localhost counts). Encrypted and signed with keys derived from the
  # application secret; it holds the session token, the CSRF token, and an
  # OAuth trip or an address being added while one is in flight.
  @session_options [
    store: :cookie,
    key: "__Host-hireme",
    signing_salt: "hireme cookie sign",
    encryption_salt: "hireme cookie seal",
    same_site: "Lax",
    secure: true,
    http_only: true,
    max_age: 24 * 60 * 60
  ]

  @doc "Origins a browser's wire session may come from: this endpoint's own URL, plus `check_origin` in dev."
  @spec origins() :: [String.t()]
  def origins do
    own = url()

    case config(:check_origin) do
      list when is_list(list) ->
        port = config(:url)[:port]
        others = for o <- list, do: "http:" <> o <> if(port, do: ":#{port}", else: "")
        Enum.uniq([own | others])

      _ ->
        [own]
    end
  end

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
  end

  plug :peer
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug :wire

  # Pages post forms (urlencoded, carrying `_csrf_token`); scripts post JSON.
  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    length: 1_048_576,
    json_decoder: Phoenix.json_library()

  plug Plug.Head
  plug Plug.Session, @session_options
  plug HiremeWeb.Router

  # Who is asking. Behind the host's nginx every request arrives from
  # loopback, so per-peer limits and the trail would see one peer: from
  # loopback only, nginx's X-Real-IP ($remote_addr, which it overwrites)
  # names the client. X-Forwarded-For is never read; its left end is the
  # client's to write. The process account is cleared here too: Bandit
  # reuses a connection's process across requests, and nothing about the
  # last request's account may reach the next (or the wire session an
  # upgrade turns this process into).
  defp peer(conn, _opts) do
    Hireme.Repo.put_account(nil)

    with true <- loopback?(conn.remote_ip),
         [real | _] <- Plug.Conn.get_req_header(conn, "x-real-ip"),
         {:ok, ip} <-
           real |> String.trim() |> String.to_charlist() |> :inet.parse_strict_address() do
      %{conn | remote_ip: canonical(ip)}
    else
      _ -> %{conn | remote_ip: canonical(conn.remote_ip)}
    end
  end

  # A v4 client a dual-stack socket reports as ::ffff:a.b.c.d is that v4
  # address, to the limits and on the trail.
  defp canonical({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}

  defp canonical(ip), do: ip

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # ::ffff:127.0.0.0/104, loopback as a dual-stack socket reports it.
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, hi, _}) when hi >>> 8 == 127, do: true
  defp loopback?(_), do: false

  # The wire's WebSocket carrier, for when UDP (and so the gate) is
  # blocked. The credential travels in HELLO, never in the upgrade, so no
  # cookie is read here; the session checks a ticket's origin itself.
  # A connection may buffer a whole frame before HELLO, so upgrades are
  # metered per peer (`wire_peer`); the session caps how many a peer holds
  # open (`Hireme.Security.wire_sessions_per_peer/0`).
  defp wire(%Plug.Conn{path_info: ["wire"], method: "GET"} = conn, _opts) do
    peer = conn.remote_ip |> :inet.ntoa() |> to_string()

    case Hireme.Security.limit(:wire_peer, peer) do
      :ok ->
        state = %{
          peer_ip: peer,
          origin: header(conn, "origin"),
          user_agent: conn |> header("user-agent") |> then(&(&1 && Hireme.Security.clip(&1)))
        }

        conn
        |> WebSockAdapter.upgrade(HiremeWeb.Session, state,
          timeout: 60_000,
          max_frame_size: HiremeWeb.Wire.Codec.max_up()
        )
        |> Plug.Conn.halt()

      {:error, :rate_limited} ->
        conn |> Plug.Conn.send_resp(429, "") |> Plug.Conn.halt()
    end
  end

  defp wire(conn, _opts), do: conn

  defp header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()
end
