defmodule HiremeWeb.SignInTest do
  use HiremeWeb.ConnCase, async: false

  defp mailed_token do
    assert_receive {:email, mail}, 1_000
    [_, token] = Regex.run(~r/token=([A-Za-z0-9_%-]+)/, mail.text_body)
    URI.decode_www_form(token)
  end

  test "the sign-in page is plain HTML under a strict policy", %{conn: conn} do
    conn = get(conn, "/sign-in")
    assert html_response(conn, 200) =~ ~s(action="/sign-in/email")
    [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "frame-ancestors 'none'"
    assert csp =~ "script-src 'self' 'wasm-unsafe-eval'"
    refute csp =~ "unsafe-inline"
    refute csp =~ "'unsafe-eval'"
  end

  test "a mailed link: the GET shows, only the POST spends, and the page then opens with a ticket",
       %{conn: conn} do
    conn =
      conn
      |> get("/sign-in")
      |> recycle()
      |> post("/sign-in/email", %{"email" => "web@example.com", "_csrf_token" => csrf(conn)})

    assert html_response(conn, 200) =~ "on its way"
    token = mailed_token()

    shown =
      build_conn(:get, "https://www.example.com/") |> get("/sign-in/email", %{"token" => token})

    assert html_response(shown, 200) =~ "Sign in as web@example.com?"
    assert {:ok, "web@example.com"} = Hireme.Accounts.peek_link(token)

    signed =
      shown
      |> recycle()
      |> post("/sign-in/email/confirm", %{"token" => token, "_csrf_token" => csrf(shown)})

    assert redirected_to(signed) == "/"

    page = signed |> recycle() |> get("/desk")
    html = html_response(page, 200)
    assert [_, ticket] = Regex.run(~r/name="hireme-ticket" content="([^"]+)"/, html)
    assert {:ok, _} = Hireme.Accounts.redeem_ticket(ticket)
    assert html =~ ~s(<div id="app"></div>)

    again =
      build_conn(:get, "https://www.example.com/") |> get("/sign-in/email", %{"token" => token})

    assert html_response(again, 410)
  end

  test "every lens address serves the page to a signed-in browser and sends a visitor to sign in",
       %{conn: conn} do
    %{token: token} = sign_in()

    for path <- ~w(/ /desk /focus/12 /world/places /atlas /outreach /lanes/gym /account) do
      assert html_response(conn |> signed_in(token) |> get(path), 200) =~ "hireme-wire"
      assert redirected_to(get(build_conn(:get, "https://www.example.com/"), path)) == "/sign-in"
    end
  end

  test "a session that owes its factor reaches only the factor page", %{conn: conn} do
    %{session: s, token: token, email: email} = sign_in()
    Hireme.Repo.put_account(s.account_id)
    {:ok, %{secret: secret}} = Hireme.Mfa.begin_totp(s, "me")
    code = secret |> Base.decode32!(padding: false) |> NimbleTOTP.verification_code()
    {:ok, _, _} = Hireme.Mfa.confirm_totp(s, code, "phone")
    {:ok, pending, _} = Hireme.Accounts.sign_in_with(:email, %{subject: email, display: email})
    _ = token

    assert redirected_to(conn |> signed_in(pending) |> get("/desk")) == "/sign-in/factor"

    assert html_response(conn |> signed_in(pending) |> get("/sign-in/factor"), 200) =~
             "authenticator app"

    refused =
      conn
      |> signed_in(pending)
      |> put_req_header("accept", "application/json")
      |> post("/api/wire/ticket")

    assert refused.status in [401, 403]
  end

  test "the ticket endpoint wants the CSRF token", %{conn: conn} do
    %{token: token} = sign_in()

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> signed_in(token)
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("accept", "application/json")
      |> post("/api/wire/ticket")
    end
  end

  defp csrf(conn) do
    conn = if conn.state == :unset, do: get(conn, "/sign-in"), else: conn
    [_, token] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, conn.resp_body)
    token
  end
end
