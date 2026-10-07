defmodule HiremeWeb.AuthTest do
  use HiremeWeb.ConnCase, async: false

  alias Hireme.ApiKeys

  test "without a session the page redirects and the API answers 401" do
    conn = anonymous()
    assert redirected_to(get(conn, "/")) == "/sign-in"
    assert %{"error" => "unauthenticated"} = conn |> get("/api/pack") |> json_response(401)
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
    settings = conn |> get("/api/account") |> json_response(200)
    assert settings["keys"] == []
    assert [%{"current" => true}] = settings["sessions"]

    created =
      conn
      |> post("/api/account/keys", %{name: "agenix-pylon-wsl", expires_in_days: 90})
      |> json_response(200)

    assert created["secret"] =~ ~r/\Ahm_/
    [key] = created["keys"]
    assert key["name"] == "agenix-pylon-wsl"
    assert key["key_id"] == "key_" <> String.slice(created["secret"], 3, 12)
    assert key["display"] == "hm_" <> String.slice(created["secret"], 16, 4) <> "…"
    assert key["expires_at"]
    assert key["live"]
    assert {:ok, _} = ApiKeys.authenticate(created["secret"], "t")

    assert %{"error" => "bad argument name"} =
             conn |> post("/api/account/keys", %{name: ""}) |> json_response(400)

    assert %{"error" => "bad argument expires_in_days"} =
             conn
             |> post("/api/account/keys", %{name: "x", expires_in_days: 7})
             |> json_response(400)

    renamed =
      conn |> patch("/api/account/keys/#{key["id"]}", %{name: "renamed"}) |> json_response(200)

    assert [%{"name" => "renamed"}] = renamed["keys"]

    revoked = conn |> delete("/api/account/keys/#{key["id"]}") |> json_response(200)
    assert [%{"live" => false, "revoked_at" => at}] = revoked["keys"]
    assert at
    assert :error = ApiKeys.authenticate(created["secret"], "t")

    assert %{"error" => "not found"} =
             conn |> delete("/api/account/keys/999999") |> json_response(404)
  end

  test "an agent socket needs a live key for the account that owns the letterbox", %{conn: conn} do
    import Hireme.Fixtures
    job = job(profile(), %{company: "Keyed Co"})
    box = Hireme.Letterbox.for_job(job.id).id

    %{"secret" => secret} =
      conn |> post("/api/account/keys", %{name: "socket"}) |> json_response(200)

    info = fn key ->
      %{
        params: %{"letterbox_id" => to_string(box)},
        connect_info: %{x_headers: [{"x-api-key", key}], peer_data: %{address: {127, 0, 0, 1}}}
      }
    end

    assert {:ok, %{id: ^box, account_id: account_id}} = HiremeWeb.McpSocket.connect(info.(secret))
    assert account_id == Hireme.Repo.account_id!()
    assert :error = HiremeWeb.McpSocket.connect(info.("hm_nope"))

    assert :error =
             HiremeWeb.McpDirectorySocket.connect(%{
               connect_info: %{x_headers: [], peer_data: %{address: {127, 0, 0, 1}}}
             })

    assert {:ok, %{account_id: ^account_id}} =
             HiremeWeb.McpDirectorySocket.connect(%{
               connect_info: %{auth_token: secret, peer_data: %{address: {127, 0, 0, 1}}}
             })

    other = Hireme.DataCase.open_account("Other desk")
    {:ok, %{secret: foreign}} = ApiKeys.create("foreign")
    assert :error = HiremeWeb.McpSocket.connect(info.(foreign))
    refute other.id == account_id
  end
end
