# Credentials for the browser and MCP benchmarks, minted by a second VM on a
# running testbed's database: MINT=session prints a fresh session cookie
# (signed in now, so key writes are inside the step-up window), MINT=key
# prints a new API key. Run with the testbed's environment, BENCH_DIR
# included; the database must lie inside BENCH_DIR next to testbed.json.
#
#   MINT=session bin/hireme eval 'Code.eval_file("bench/mint.exs")'
defmodule HiremeBench.Mint do
  def run do
    dir = Path.expand(System.fetch_env!("BENCH_DIR"))

    database =
      Application.fetch_env!(:hireme, Hireme.Repo) |> Keyword.fetch!(:database) |> Path.expand()

    unless String.starts_with?(database, dir <> "/"),
      do: raise("database must be inside BENCH_DIR")

    unless File.regular?(Path.join(dir, "testbed.json")),
      do: raise("BENCH_DIR has no testbed.json")

    Logger.configure(level: :error)
    endpoint = Application.fetch_env!(:hireme, HiremeWeb.Endpoint)
    Application.put_env(:hireme, HiremeWeb.Endpoint, Keyword.put(endpoint, :server, false))
    Application.put_env(:hireme, Hireme.Mailer, adapter: Swoosh.Adapters.Test)
    {:ok, _} = Application.ensure_all_started(:hireme)
    account = Hireme.Accounts.use_default!()

    case System.get_env("MINT", "session") do
      "session" -> IO.puts(cookie(account))
      "key" -> IO.puts(key(account))
    end
  end

  defp cookie(account) do
    {token, _session} =
      Hireme.Accounts.start_session(account, %{user_agent: "isolated-performance-testbed"})

    opts =
      Plug.Session.init(
        store: :cookie,
        key: "__Host-hireme",
        signing_salt: "hireme-session-sign",
        encryption_salt: "hireme-session-seal",
        same_site: "Lax",
        secure: true,
        http_only: true,
        max_age: 86_400
      )

    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:secret_key_base, Application.fetch_env!(:hireme, :secret_key_base))
      |> Plug.Session.call(opts)
      |> Plug.Conn.fetch_session()
      |> HiremeWeb.Auth.sign_in(token)
      |> Plug.Conn.send_resp(200, "")

    conn.resp_cookies["__Host-hireme"].value
  end

  defp key(account) do
    Hireme.Repo.put_account(account.id)
    {:ok, %{secret: secret}} = Hireme.ApiKeys.create("bench-mcp", nil, %{})
    secret
  end
end

HiremeBench.Mint.run()
