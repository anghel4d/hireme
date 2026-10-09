defmodule HiremeWeb.SignInTest do
  use HiremeWeb.ConnCase, async: false

  alias Hireme.Accounts
  alias Hireme.Repo

  # A provider on the far side of the round trip: it hands out a token for
  # any code, reports the token request to the test, and answers /user (or
  # /2/users/me) with the user `users` maps that code to.
  defmodule Provider do
    @behaviour Assent.HTTPAdapter
    alias Assent.HTTPAdapter.HTTPResponse

    @impl true
    def request(:post, url, body, headers, _users) do
      form = URI.decode_query(body)
      send(self(), {:token_request, url, form, Map.new(headers)})
      json(%{"access_token" => "at-" <> form["code"], "token_type" => "bearer"})
    end

    def request(:get, _url, nil, headers, users) do
      "Bearer at-" <> code = headers |> Map.new() |> Map.fetch!("authorization")
      json(Map.fetch!(users, code))
    end

    defp json(body),
      do:
        {:ok,
         %HTTPResponse{
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: Jason.encode!(body)
         }}
  end

  @users %{
    "octo" => %{"id" => 42, "login" => "octocat"},
    "taken" => %{"id" => 77, "login" => "someone-else"},
    "jack" => %{"data" => %{"id" => "99", "username" => "jack", "name" => "Jack"}}
  }

  setup do
    previous = Application.get_env(:hireme, :oauth)
    adapter = {Provider, @users}

    Application.put_env(:hireme, :oauth,
      github: [client_id: "gh-id", client_secret: "gh-secret", http_adapter: adapter],
      x: [client_id: "x-id", client_secret: "x-secret", http_adapter: adapter]
    )

    on_exit(fn -> Application.put_env(:hireme, :oauth, previous) end)
  end

  test "a mailed link shows where it leads, signs a visitor in once, and finds the same account again" do
    page =
      anonymous() |> post("/sign-in/email", %{email: " New@Example.COM "}) |> html_response(200)

    assert page =~ "new@example.com"

    token = mailed("new@example.com")

    # Opening the page spends nothing; a scanner can follow it any number of times.
    for _ <- 1..2 do
      shown = get(anonymous(), "/sign-in/email", token: token)
      assert html_response(shown, 200) =~ "Sign in as new@example.com?"
      assert get_resp_header(shown, "cache-control") == ["no-store"]
      assert get_resp_header(shown, "referrer-policy") == ["no-referrer"]
    end

    signed = post(anonymous(), "/sign-in/email/confirm", token: token)
    assert redirected_to(signed) == "/"
    first = recycle(signed) |> get("/api/account") |> json_response(200)
    assert [%{"provider" => "email", "display" => "new@example.com"}] = first["identities"]

    assert html_response(post(anonymous(), "/sign-in/email/confirm", token: token), 410) =~
             "expired or was already used"

    post(anonymous(), "/sign-in/email", %{email: "new@example.com"})
    again = post(anonymous(), "/sign-in/email/confirm", token: mailed("new@example.com"))

    assert (recycle(again) |> get("/api/account") |> json_response(200))["account"] ==
             first["account"]

    assert anonymous() |> post("/sign-in/email", %{email: "not an address"}) |> html_response(422) =~
             "Enter a whole email address"
  end

  test "a link never joins an address to whichever account happens to open it", %{conn: victim} do
    post(anonymous(), "/sign-in/email", %{email: "attacker@evil.example"})
    token = mailed("attacker@evil.example")

    assert html_response(get(victim, "/sign-in/email", token: token), 409) =~ "sign out first"
    assert html_response(post(victim, "/sign-in/email/confirm", token: token), 409)
    assert (victim |> get("/api/account") |> json_response(200))["identities"] == []

    # Refused, not spent: the address's owner can still use it.
    assert redirected_to(post(anonymous(), "/sign-in/email/confirm", token: token)) == "/"
  end

  test "the Account page adds an address through a link opened in the browser that asked", %{
    conn: conn
  } do
    asked =
      post(conn, "/api/account/identities", %{provider: "email", email: "Second@Example.com"})

    assert json_response(asked, 200)["sent_to"] == "second@example.com"
    token = mailed("second@example.com")

    # The same account in another browser did not ask, so it may not add it.
    assert html_response(post(conn, "/sign-in/email/confirm", token: token), 409)

    here = recycle(asked)

    assert html_response(get(here, "/sign-in/email", token: token), 200) =~
             "Add second@example.com"

    added = post(here, "/sign-in/email/confirm", token: token)
    assert redirected_to(added) == "/?lens=settings&linked=email"

    assert [%{"provider" => "email", "display" => "second@example.com"}] =
             (recycle(added) |> get("/api/account") |> json_response(200))["identities"]
  end

  test "GitHub and X sign a visitor in through a state-checked round trip with PKCE" do
    {github, query} = start(anonymous(), "/auth/github")
    assert query["client_id"] == "gh-id" and query["code_challenge_method"] == "S256"
    assert query["redirect_uri"] =~ ~r{/auth/github/callback\z}
    refute Map.has_key?(query, "scope")

    signed = get(github, "/auth/github/callback", code: "octo", state: query["state"])
    assert redirected_to(signed) == "/"
    assert_received {:token_request, "https://github.com/login/oauth/access_token", form, _}
    assert pkce?(form["code_verifier"], query["code_challenge"])

    assert [%{"provider" => "github", "display" => "octocat"}] =
             (recycle(signed) |> get("/api/account") |> json_response(200))["identities"]

    {x, query} = start(anonymous(), "/auth/x")
    assert query["scope"] == "users.read tweet.read"
    signed = get(x, "/auth/x/callback", code: "jack", state: query["state"])
    assert redirected_to(signed) == "/"
    assert_received {:token_request, "https://api.x.com/2/oauth2/token", form, headers}
    assert headers["authorization"] == "Basic " <> Base.encode64("x-id:x-secret")
    assert pkce?(form["code_verifier"], query["code_challenge"])

    assert [%{"display" => "@jack"}] =
             (recycle(signed) |> get("/api/account") |> json_response(200))["identities"]
  end

  test "a callback without this browser's state is refused, and the trip is spent" do
    {github, query} = start(anonymous(), "/auth/github")
    forged = get(github, "/auth/github/callback", code: "octo", state: "not-the-state")
    assert redirected_to(forged) == "/sign-in?error=failed"

    late = get(recycle(forged), "/auth/github/callback", code: "octo", state: query["state"])
    assert redirected_to(late) == "/sign-in?error=failed"

    {github, query} = start(anonymous(), "/auth/github")
    denied = get(github, "/auth/github/callback", error: "access_denied", state: query["state"])
    assert redirected_to(denied) == "/sign-in?error=denied"

    assert response(get(anonymous(), "/auth/myspace"), 404)
    page = anonymous() |> get("/sign-in") |> html_response(200)
    assert page =~ "Continue with GitHub" and page =~ "Continue with X"
  end

  test "linking a provider starts on the Account page behind step-up, and a taken one is refused",
       %{conn: conn, account: account} do
    # A bare GET never links: a signed-in browser is just sent home.
    assert redirected_to(get(conn, "/auth/github")) == "/"

    {browser, state} = begin_link(conn, "github")
    linked = get(browser, "/auth/github/callback", code: "octo", state: state)
    assert redirected_to(linked) == "/?lens=settings&linked=github"

    other = Accounts.create!(%{name: "Other"})
    Repo.with_account(other.id, fn -> Accounts.link(:github, %{subject: "77", display: "x"}) end)

    {browser, state} = begin_link(conn, "github")
    taken = get(browser, "/auth/github/callback", code: "taken", state: state)
    assert redirected_to(taken) == "/?lens=settings&link_error=taken"

    assert [%{"provider" => "github", "display" => "octocat"}] =
             (conn |> get("/api/account") |> json_response(200))["identities"]

    stale!(account)

    assert %{"error" => "step_up"} =
             conn |> post("/api/account/identities", %{provider: "x"}) |> json_response(403)
  end

  test "removing a way in needs step-up, never removes the last, and only touches this account",
       %{conn: conn, account: account} do
    {:ok, gh} = Accounts.link(:github, %{subject: "1", display: "one"})
    {:ok, _} = Accounts.link(:x, %{subject: "2", display: "@two"})
    other = Accounts.create!(%{name: "Other"})

    {:ok, foreign} =
      Repo.with_account(other.id, fn -> Accounts.link(:x, %{subject: "3", display: "@three"}) end)

    assert conn |> delete("/api/account/identities/#{foreign.id}") |> json_response(404)

    left = conn |> delete("/api/account/identities/#{gh.id}") |> json_response(200)
    assert [%{"provider" => "x"} = last] = left["identities"]

    assert %{"error" => "This is the only way into the account." <> _} =
             conn |> delete("/api/account/identities/#{last["id"]}") |> json_response(409)

    stale!(account)

    assert %{"error" => "step_up"} =
             conn |> delete("/api/account/identities/#{last["id"]}") |> json_response(403)
  end

  test "a link is a first factor only: an enrolled account still owes its second", %{conn: conn} do
    {:ok, _} = Accounts.link(:email, %{subject: "me@example.com", display: "me@example.com"})
    %{"secret" => secret32} = conn |> post("/api/account/mfa/totp", %{}) |> json_response(200)
    code = NimbleTOTP.verification_code(Base.decode32!(secret32, padding: false))

    conn
    |> post("/api/account/mfa/totp/confirm", %{code: code, name: "Phone"})
    |> json_response(200)

    post(anonymous(), "/sign-in/email", %{email: "me@example.com"})
    signed = post(anonymous(), "/sign-in/email/confirm", token: mailed("me@example.com"))
    assert redirected_to(get(recycle(signed), "/")) == "/sign-in/factor"
  end

  test "a browser's form reaches the page with its CSRF token, and one without it is refused" do
    page = Plug.Test.conn(:get, "/sign-in") |> @endpoint.call([])
    [_, csrf] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, page.resp_body)

    form = fn body ->
      Plug.Test.conn(:post, "/sign-in/email", body)
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Plug.Test.recycle_cookies(page)
    end

    sent =
      @endpoint.call(
        form.("_csrf_token=#{URI.encode_www_form(csrf)}&email=form%40example.com"),
        []
      )

    assert sent.status == 200 and sent.resp_body =~ "form@example.com"
    assert mailed("form@example.com")

    assert_error_sent 403, fn -> @endpoint.call(form.("email=form%40example.com"), []) end
  end

  # The token in the link the last mail to `address` carried.
  defp mailed(address) do
    assert_receive {:email,
                    %Swoosh.Email{
                      to: [{_, ^address}],
                      subject: "Your Hireme sign-in link",
                      text_body: body
                    }}

    [_, token] = Regex.run(~r{/sign-in/email\?token=([A-Za-z0-9_-]+)}, body)
    token
  end

  # Start a round trip; the browser that started it, and the provider URL's query.
  defp start(conn, path) do
    started = get(conn, path)

    {recycle(started),
     started |> redirected_to(302) |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()}
  end

  # Ask the Account page to link `provider`: the browser now holding the
  # trip in its session, and the state the provider will be handed.
  defp begin_link(conn, provider) do
    asked = post(conn, "/api/account/identities", %{provider: provider})
    %{"url" => url} = json_response(asked, 200)

    {recycle(asked),
     url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")}
  end

  defp pkce?(verifier, challenge),
    do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) == challenge

  defp stale!(account) do
    stale =
      DateTime.utc_now()
      |> DateTime.add(-(Hireme.Security.step_up_window() + 1), :second)
      |> DateTime.truncate(:second)

    for s <- Accounts.list_sessions(account.id),
        do:
          s
          |> Ecto.Changeset.change(authenticated_at: stale, mfa_at: stale)
          |> Repo.update!(skip_account: true)
  end
end
