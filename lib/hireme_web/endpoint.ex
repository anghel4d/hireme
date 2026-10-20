defmodule HiremeWeb do
  @moduledoc """
  The web layer: one endpoint, one router, one page, the HTTP-only
  ceremonies (sign-in and the factor page), and the wire's WebSocket
  carrier. Everything else is one wire session per tab or agent
  (`HiremeWeb.Session`), over WebTransport through the gate or `/wire`.
  A browser is an account's session; an agent is an account's key;
  neither sees another account.
  """
  import Plug.Conn

  def static_paths, do: ~w(assets wasm)

  @doc "A JSON body, at the conn's status (200 unless one was put)."
  def json(conn, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(conn.status || 200, JSON.encode_to_iodata!(data))
  end

  @doc "A redirect to a path on this origin, or with `external:` to another site."
  def redirect(conn, to: "/" <> _ = path), do: found(conn, path)
  def redirect(conn, external: url), do: found(conn, url)

  defp found(conn, url), do: conn |> put_resp_header("location", url) |> send_resp(302, "")
end

defmodule HiremeWeb.Endpoint do
  @moduledoc """
  The HTTP front door, a plug Bandit serves: static files, who is asking,
  the wire's WebSocket upgrade, then the session cookie and the router.
  It serves only when HIREME_SERVER is set; tests call it directly or
  start their own Bandit.
  """
  use Plug.Builder
  import Bitwise, only: [>>>: 2, &&&: 2]
  alias HiremeWeb.Wire.Codec

  # The one cookie. `__Host-` pins it to this origin, path `/`, over https
  # (localhost counts). Encrypted and signed with keys derived from the
  # application secret; it holds the session token, the CSRF token, and an
  # OAuth trip or an address being added while one is in flight. It lives as
  # long as the longest session (a remembered one's 90 days); the session
  # row, not the cookie, decides when a sign-in ends.
  @session_options [
    store: :cookie,
    key: "__Host-hireme",
    signing_salt: "hireme cookie sign",
    encryption_salt: "hireme cookie seal",
    same_site: "Lax",
    secure: true,
    http_only: true,
    max_age: 90 * 24 * 60 * 60
  ]

  @ssl Application.compile_env(:hireme, [__MODULE__, :force_ssl])
  @manifest Application.compile_env(:hireme, [__MODULE__, :cache_static_manifest])

  @doc "Bandit on the configured address when this node serves (`HIREME_SERVER`)."
  def child_spec(_) do
    if System.get_env("HIREME_SERVER"),
      do: Bandit.child_spec([plug: __MODULE__] ++ config(:http)),
      else: %{id: __MODULE__, start: {Function, :identity, [:ignore]}}
  end

  @doc "This endpoint's setting `key`."
  def config(key), do: Application.get_env(:hireme, __MODULE__, [])[key]

  @doc "The URL this node is reached at, from `url:` (the port falls back to the listener's)."
  @spec url() :: String.t()
  def url do
    u = config(:url) || []
    scheme = u[:scheme] || "http"
    port = u[:port] || config(:http)[:port]
    base = "#{scheme}://#{u[:host] || "localhost"}"
    if port in [nil, 80, 443], do: base, else: "#{base}:#{port}"
  end

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

  @doc "A static file's path; in a release its digested name (`mix hireme.digest`), which browsers keep for good."
  @spec static_path(String.t()) :: String.t()
  if @manifest do
    def static_path("/" <> name = path) do
      case Map.fetch(manifest(), name) do
        {:ok, digested} -> "/" <> digested <> "?vsn=d"
        :error -> path
      end
    end

    # Read once: a release's manifest does not change under it.
    defp manifest do
      with nil <- :persistent_term.get({__MODULE__, :manifest}, nil) do
        read = Application.app_dir(:hireme, @manifest) |> File.read!() |> JSON.decode!()
        :persistent_term.put({__MODULE__, :manifest}, read)
        read
      end
    end
  else
    def static_path(path), do: path
  end

  if @ssl, do: plug(Plug.SSL, @ssl)
  plug :peer
  plug :secret
  plug Plug.Static, at: "/", from: :hireme, gzip: true, only: HiremeWeb.static_paths()
  plug Plug.RequestId
  plug Plug.Logger
  plug :wire
  plug :mcp
  plug :blobs

  # Pages post forms (urlencoded, carrying `_csrf_token`); scripts post JSON.
  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    length: 1_048_576,
    json_decoder: JSON

  plug Plug.Head
  plug Plug.Session, @session_options
  plug HiremeWeb.Router

  # The cookie's keys derive from the application secret.
  defp secret(conn, _opts),
    do: %{conn | secret_key_base: Application.fetch_env!(:hireme, :secret_key_base)}

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

  # MCP over HTTP (`HiremeWeb.Mcp`), ahead of the cookie and the body
  # parsers: an API key is its only credential, checked before the body
  # is read.
  defp mcp(%Plug.Conn{path_info: ["mcp"]} = conn, _opts),
    do: conn |> HiremeWeb.Mcp.call() |> halt()

  defp mcp(conn, _opts), do: conn

  # A CV file asked for with a key, like /mcp ahead of the cookie and the
  # body parsers; a browser's goes on to the router.
  defp blobs(%Plug.Conn{path_info: ["blobs" | _]} = conn, _opts) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> _ | _] -> conn |> HiremeWeb.Blobs.keyed() |> halt()
      _ -> conn
    end
  end

  defp blobs(conn, _opts), do: conn

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
          max_frame_size: Codec.max_up()
        )
        |> Plug.Conn.halt()

      {:error, :rate_limited} ->
        conn |> Plug.Conn.send_resp(429, "") |> Plug.Conn.halt()
    end
  end

  defp wire(conn, _opts), do: conn

  defp header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()
end
