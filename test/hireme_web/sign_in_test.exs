defmodule HiremeWeb.SignInTest do
  use HiremeWeb.ConnCase, async: false

  # A signed-in account with an authenticator app enrolled; a new sign-in to
  # it is pending the factor. Answers `{pending token, totp seed, a recovery code}`.
  defp owing_factor do
    %{session: s, email: email} = sign_in()
    Hireme.Repo.put_account(s.account_id)
    {:ok, %{secret: secret}} = Hireme.Mfa.begin_totp(s, "me")
    raw = Base.decode32!(secret, padding: false)

    {:ok, _, [recovery | _]} =
      Hireme.Mfa.confirm_totp(s, NimbleTOTP.verification_code(raw), "phone")

    {:ok, pending, _} = Hireme.Accounts.sign_in_with(:email, %{subject: email, display: email})
    {pending, raw, recovery, email}
  end

  test "the sign-in page is plain HTML under a strict policy; an unknown page is a plain 404", %{
    conn: conn
  } do
    conn = get(conn, "/sign-in")
    assert html_response(conn, 200) =~ ~s(action="/sign-in/email")
    [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "frame-ancestors 'none'"
    assert csp =~ "script-src 'self' 'wasm-unsafe-eval'"
    refute csp =~ "unsafe-inline"
    refute csp =~ "'unsafe-eval'"
    assert %{status: 404, resp_body: "Not Found"} = get(build_conn(), "/nope")
  end

  test "a mailed link: the GET shows, only the POST spends, and the page then opens with a ticket",
       %{conn: conn} do
    {signed, token} = email_sign_in(conn, "web@example.com")
    assert html_response(get(build_conn(), "/sign-in/email", %{"token" => token}), 410)
    {ticket, html} = ticket(signed)
    assert {:ok, _} = Hireme.Accounts.redeem_ticket(ticket)
    assert html =~ ~s(<div id="app"></div>)
  end

  test "a remembered device outlives an hour idle and keeps its desk when it runs out; a plain sign-in ends at an hour, and a revoke always clears",
       %{conn: conn} do
    newest = fn -> Enum.max_by(Hireme.Repo.all(Hireme.Rows.Session, skip_account: true), & &1.id) end
    cleared? = &(get_resp_header(&1, "clear-site-data") != [])

    {kept, _} = email_sign_in(conn, "kept@example.com", %{"remember" => "1"})
    s = age(newest.(), :last_seen_at, Hireme.Security.session_idle() + 60)
    assert html_response(kept |> recycle() |> get("/desk"), 200)
    age(s, :last_seen_at, Hireme.Security.session_idle(true) + 60)
    out = kept |> recycle() |> get("/desk")
    assert redirected_to(out) == "/sign-in" and not cleared?.(out)

    {plain, _} = email_sign_in(build_conn(), "plain@example.com")
    age(newest.(), :last_seen_at, Hireme.Security.session_idle() + 60)
    out = plain |> recycle() |> get("/desk")
    assert redirected_to(out) == "/sign-in" and cleared?.(out)

    {revoked, _} = email_sign_in(build_conn(), "revoked@example.com", %{"remember" => "1"})
    s = newest.()
    :ok = Hireme.Accounts.revoke_session(s.account_id, s.id)
    assert cleared?.(revoked |> recycle() |> get("/desk"))
  end

  test "every lens address serves the page to a signed-in browser and sends a visitor to sign in; the ticket endpoint wants the CSRF token; signing out ends the session on the server",
       %{conn: conn} do
    %{token: token} = sign_in()

    for path <-
          ~w(/ /desk /desk/pro /desk/pro/12-acme /desk/12-acme-rust /world /world/places /world/places/3-berlin /world/atlas /outreach /outreach/5-ada /me /me/cv /account /focus/12 /atlas) do
      assert html_response(conn |> signed_in(token) |> get(path), 200) =~ "hireme-wire"
      assert redirected_to(get(build_conn(), path)) == "/sign-in"
    end

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> signed_in(token)
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("accept", "application/json")
      |> post("/api/wire/ticket")
    end

    out = conn |> signed_in(token) |> post("/sign-out")
    assert redirected_to(out) == "/sign-in"
    assert Hireme.Accounts.session(token) == nil
    assert get_resp_header(out, "clear-site-data") == [~s("storage")]
  end

  @tag window: :ceremony_session
  test "a session that owes its factor reaches only the factor page, which takes an app code or a recovery code, refuses a wrong one, and bounds its passkey options",
       %{conn: conn} do
    {pending, raw, recovery, email} = owing_factor()
    as = fn token -> signed_in(conn, token) end

    assert redirected_to(as.(pending) |> get("/desk")) == "/sign-in/factor"
    assert html_response(as.(pending) |> get("/sign-in/factor"), 200) =~ "authenticator app"

    refused =
      as.(pending) |> put_req_header("accept", "application/json") |> post("/api/wire/ticket")

    assert refused.status in [401, 403]

    wrong = as.(pending) |> post("/sign-in/factor/totp", %{"code" => "000000"})
    assert redirected_to(wrong) =~ "/sign-in/factor?error="
    code = NimbleTOTP.verification_code(raw, time: System.os_time(:second) + 30)
    assert redirected_to(as.(pending) |> post("/sign-in/factor/totp", %{"code" => code})) == "/"
    assert html_response(as.(pending) |> get("/desk"), 200)

    {:ok, other, _} = Hireme.Accounts.sign_in_with(:email, %{subject: email, display: email})

    assert redirected_to(as.(other) |> post("/sign-in/factor/recovery", %{"code" => recovery})) ==
             "/"

    {:ok, third, _} = Hireme.Accounts.sign_in_with(:email, %{subject: email, display: email})
    answers = for _ <- 1..31, do: as.(third) |> post("/sign-in/factor/webauthn")
    assert Enum.count(answers, &(&1.status == 200)) == 30

    assert json_response(List.last(answers), 429) == %{
             "error" => "Too many attempts. Wait a few minutes."
           }
  end

  @tag window: [:link_peer, :oauth_peer]
  test "behind the local proxy the client is X-Real-IP (a ::ffff: v4 is that v4 peer); from elsewhere it is the peer; links and OAuth callbacks are bounded per peer; a user agent of invalid UTF-8 is no failure",
       %{conn: conn} do
    ask = fn conn, ip, email ->
      conn |> put_req_header("x-real-ip", ip) |> post("/sign-in/email", %{"email" => email})
    end

    for i <- 1..20, do: ask.(conn, "203.0.113.#{i}", "a#{i}@example.com")
    # Twenty distinct clients through one proxy are twenty peers, not one.
    assert ask.(conn, "203.0.113.99", "b@example.com").status == 200

    for _ <- 1..20, do: ask.(conn, "::ffff:198.51.100.1", "mapped@example.com")
    assert ask.(conn, "::ffff:198.51.100.2", "other@example.com").status == 200
    assert ask.(conn, "198.51.100.1", "again@example.com").status == 429

    spoofed = %{conn | remote_ip: {198, 51, 100, 7}}
    for _ <- 1..20, do: ask.(spoofed, "203.0.113.99", "c@example.com")
    assert ask.(spoofed, "203.0.113.99", "d@example.com").status == 429

    bad_ua = build_conn() |> put_req_header("user-agent", <<0xFF, 0xFE, "probe">>)
    assert get(bad_ua, "/sign-in").status == 200
    assert post(bad_ua, "/sign-in/email", %{"email" => "ua@example.com"}).status == 200

    old = Application.get_env(:hireme, :oauth)
    Application.put_env(:hireme, :oauth, github: [client_id: "id", client_secret: "secret"])
    on_exit(fn -> Application.put_env(:hireme, :oauth, old) end)

    callback = fn ->
      get(conn, "/auth/github/callback", %{"code" => "c", "state" => "s"}).status
    end

    for _ <- 1..20, do: assert(callback.() == 302)
    assert callback.() == 429
  end
end
