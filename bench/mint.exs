# Credentials for the browser and MCP benchmarks, minted by a second VM on a
# running testbed's database: MINT=session prints a fresh session cookie
# (signed in now, so key writes are inside the step-up window), MINT=key
# prints a new API key. Run with the testbed's environment:
#
#   MINT=session bin/hireme eval 'Code.eval_file("bench/mint.exs")'
Logger.configure(level: :error)
Application.put_env(:hireme, Hireme.Mailer, adapter: Swoosh.Adapters.Test)
{:ok, _} = Application.ensure_all_started(:hireme)
account = Hireme.Accounts.use_default!()

case System.get_env("MINT", "session") do
  "session" ->
    {token, _session} = Hireme.Accounts.start_session(account, %{user_agent: "isolated-performance-testbed"})

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

    IO.puts(conn.resp_cookies["__Host-hireme"].value)

  "key" ->
    Hireme.Repo.put_account(account.id)
    {:ok, %{secret: secret}} = Hireme.ApiKeys.create("bench-mcp", nil, %{})
    IO.puts(secret)
end
