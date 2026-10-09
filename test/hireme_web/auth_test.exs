defmodule HiremeWeb.AuthTest do
  use HiremeWeb.ConnCase, async: false

  alias Hireme.ApiKeys

  test "without a session the page redirects and the account answers 401" do
    conn = anonymous()
    assert redirected_to(get(conn, "/")) == "/sign-in"
    assert %{"error" => "unauthenticated"} = account(conn, "rename_key", %{id: 1, name: "x"}, 401)
    assert conn |> get("/sign-in") |> html_response(200) =~ "Send a sign-in link"
    refute conn |> get("/sign-in") |> html_response(200) =~ "/dev/sign-in"
  end

  test "a signed-in session reaches the desk, and signing out ends it", %{conn: conn} do
    html = conn |> get("/") |> html_response(200)
    assert html =~ ~s(name="csrf-token")

    assert get_resp_header(get(conn, "/"), "content-security-policy") |> hd() =~
             "frame-ancestors 'none'"

    assert redirected_to(get(conn, "/sign-in")) == "/"

    out = post(conn, "/sign-out")
    assert redirected_to(out) == "/sign-in"
    assert redirected_to(get(conn, "/")) == "/sign-in"
  end

  test "the account page mints, lists, renames, and revokes keys", %{conn: conn} do
    assert ApiKeys.list() == []

    created = account(conn, "create_key", %{name: "agenix-pylon-wsl", expires_in_days: 90}, 200)

    assert created["secret"] =~ ~r/\Ahm_/
    key = created["created"]
    assert key["name"] == "agenix-pylon-wsl"
    assert key["key_id"] == "key_" <> String.slice(created["secret"], 3, 12)
    assert key["display"] == "hm_" <> String.slice(created["secret"], 16, 4) <> "…"
    assert key["expires_at"]
    assert key["live"]
    assert {:ok, _} = ApiKeys.authenticate(created["secret"], "t")

    assert %{"error" => "bad argument name"} = account(conn, "create_key", %{name: ""}, 400)

    assert %{"error" => "bad argument expires_in_days"} =
             account(conn, "create_key", %{name: "x", expires_in_days: 7}, 400)

    account(conn, "rename_key", %{id: key["id"], name: "renamed"}, 200)
    assert [%{name: "renamed"}] = ApiKeys.list()

    account(conn, "revoke_key", %{id: key["id"]}, 200)
    assert [%{revoked_at: at} = revoked] = ApiKeys.list()
    assert at && not ApiKeys.live?(revoked)
    assert :error = ApiKeys.authenticate(created["secret"], "t")

    assert %{"error" => "not found"} = account(conn, "revoke_key", %{id: 999_999}, 404)
  end

  test "a key minted on the account page signs an agent in for that account only", %{
    conn: conn
  } do
    import Hireme.Fixtures
    job = job(profile(), %{company: "Keyed Co"})
    %{"secret" => secret} = account(conn, "create_key", %{name: "agent"}, 200)
    account_id = Hireme.Repo.account_id!()

    assert {:ok, %{account_id: ^account_id}} = Hireme.Letterbox.agent_key(secret, "t")
    assert :error = Hireme.Letterbox.agent_key("hm_nope", "t")

    Hireme.DataCase.open_account("Other desk")
    {:ok, %{secret: foreign}} = ApiKeys.create("foreign")
    assert {:ok, %{account_id: other}} = Hireme.Letterbox.agent_key(foreign, "t")
    refute other == account_id
    assert {:error, :not_found} = Hireme.Letterbox.claim(job.id)
  end

  test "an enrolled account's new session is pending until a factor is presented, and sensitive writes need a fresh one",
       %{conn: conn, account: account, session: session} do
    secret32 = account(conn, "begin_totp", %{}, 200) |> Map.fetch!("secret")
    secret = Base.decode32!(secret32, padding: false)

    enrolled =
      account(
        conn,
        "confirm_totp",
        %{code: NimbleTOTP.verification_code(secret), name: "Phone"},
        200
      )

    assert [%{kind: :totp, name: "Phone"}] = Hireme.Mfa.methods()
    assert length(enrolled["recovery_codes"]) == 10

    # A fresh browser signs in and owes the factor.
    {token, _} = Hireme.Accounts.start_session(account)
    fresh = anonymous() |> Plug.Test.init_test_session(%{HiremeWeb.Auth.session_key() => token})
    assert redirected_to(get(fresh, "/")) == "/sign-in/factor"
    assert %{"error" => "second_factor"} = account(fresh, "rename_key", %{id: 1, name: "x"}, 401)
    assert redirected_to(get(fresh, "/sign-in")) == "/sign-in/factor"
    page = fresh |> get("/sign-in/factor") |> html_response(200)
    assert page =~ "authenticator app" and page =~ "/assets/js/factor.js"

    assert redirected_to(post(fresh, "/sign-in/factor/totp", %{code: "000000"})) =~
             "/sign-in/factor?error="

    later = NimbleTOTP.verification_code(secret, time: System.os_time(:second) + 30)
    assert redirected_to(post(fresh, "/sign-in/factor/totp", %{code: later})) == "/"
    assert redirected_to(get(fresh, "/sign-in/factor")) == "/"

    # Minting a key is a sensitive write: fresh after the proof, refused once it ages.
    assert %{"secret" => _} = account(fresh, "create_key", %{name: "fresh"}, 200)

    stale =
      DateTime.utc_now()
      |> DateTime.add(-(Hireme.Security.step_up_window() + 1), :second)
      |> DateTime.truncate(:second)

    for s <- Hireme.Accounts.list_sessions(account.id),
        do:
          s
          |> Ecto.Changeset.change(mfa_at: stale, authenticated_at: stale)
          |> Hireme.Repo.update!(skip_account: true)

    assert %{"error" => "step_up"} = account(fresh, "create_key", %{name: "stale"}, 403)
    assert %{"error" => _} = account(fresh, "step_up_totp", %{code: "000000"}, 401)

    # Two steps ahead is outside the grace; a recovery code steps up instead.
    ahead = NimbleTOTP.verification_code(secret, time: System.os_time(:second) + 60)
    assert %{"error" => _} = account(fresh, "step_up_totp", %{code: ahead}, 401)

    assert %{"ok" => true, "fresh" => true} =
             account(fresh, "step_up_recovery", %{code: hd(enrolled["recovery_codes"])}, 200)

    assert %{"secret" => _} = account(fresh, "create_key", %{name: "stepped"}, 200)
    assert Hireme.Mfa.recovery_codes_left() == 9

    assert %{"recovery_codes" => codes} = account(fresh, "recovery_codes", %{}, 200)

    assert length(codes) == 10
    _ = session
  end
end
