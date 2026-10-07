defmodule Hireme.ChecklistOracleTest do
  @moduledoc false
  # Runtime oracles from docs/checklist.md that the rest of the suite does not already pin.
  use HiremeWeb.ConnCase, async: false

  import Ecto.Query
  import Hireme.Fixtures

  alias Hireme.Accounts
  alias Hireme.Accounts.MagicLink
  alias Hireme.ApiKeys
  alias Hireme.Audit
  alias Hireme.Desk
  alias Hireme.Mfa
  alias Hireme.Mfa.Method
  alias Hireme.Repo
  alias Hireme.Security

  @endpoint HiremeWeb.Endpoint

  setup do
    previous = Application.get_env(:hireme, :oauth)
    adapter = {HiremeWeb.SignInTest.Provider, %{"code" => %{"id" => 7, "login" => "octo"}}}

    Application.put_env(:hireme, :oauth,
      github: [client_id: "gh-id", client_secret: "gh-secret", http_adapter: adapter],
      x: [client_id: "x-id", client_secret: "x-secret", http_adapter: adapter]
    )

    on_exit(fn -> Application.put_env(:hireme, :oauth, previous) end)
    :ok
  end

  test "a new passkey is stored, and the same credential cannot enrol twice", %{
    session: session
  } do
    credential_id = :crypto.strong_rand_bytes(16)
    Mfa.begin_webauthn(session, "me")

    assert {:ok, method, codes} =
             Mfa.confirm_webauthn(session, attestation(session, credential_id))

    assert method.kind == :webauthn
    assert length(codes) == 10

    Mfa.begin_webauthn(session, "me")

    assert {:error, :duplicate} =
             Mfa.confirm_webauthn(session, attestation(session, credential_id, "again"))
  end

  test "desk changesets drop a foreign account id; the row stays on this process" do
    other = Accounts.create!(%{name: "Other desk"})

    profile =
      profile(%{account_id: other.id, slug: "foreign-#{System.unique_integer([:positive])}"})

    assert profile.account_id == Repo.account_id!()
    refute profile.account_id == other.id
  end

  test "an id owned by another account is 404 on the account API and on the desk", %{
    account: account
  } do
    other = Hireme.DataCase.open_account("Other desk")
    {_, their_session} = Accounts.start_session(other)
    {:ok, %{key: their_key}} = ApiKeys.create("theirs")
    job = job(profile(), %{company: "Theirs"})

    Hireme.DataCase.open_account("Back")
    # The conn's process account was replaced; sign in again as the original.
    {token, _} = Accounts.start_session(account)
    conn = anonymous() |> init_test_session(%{HiremeWeb.Auth.session_key() => token})

    assert %{"error" => "not found"} =
             conn |> delete("/api/account/keys/#{their_key.id}") |> json_response(404)

    assert %{"error" => "not found"} =
             conn |> delete("/api/account/sessions/#{their_session.id}") |> json_response(404)

    assert conn |> get("/api/focus/#{job.id}") |> json_response(404)
  end

  test "a task that does not pin the account cannot read, and a write publishes only on this desk",
       %{account: account} do
    other = Accounts.create!(%{name: "Listener"})

    # A new process does not inherit the account. It must raise rather than
    # read whichever rows the connection would otherwise return.
    parent = self()

    spawn(fn ->
      try do
        Repo.all(Hireme.Desk.Job)
        send(parent, :read)
      rescue
        error in ArgumentError -> send(parent, {:raised, Exception.message(error)})
      end
    end)

    assert_receive {:raised, message}
    assert message =~ "no account on the process"
    refute_receive :read

    parent = self()

    listener =
      spawn(fn ->
        Phoenix.PubSub.subscribe(Hireme.PubSub, Desk.topic(other.id))
        send(parent, :listening)

        receive do
          :stop ->
            receive do
              {:desk_event, _} -> send(parent, :leaked)
            after
              0 -> send(parent, :quiet)
            end
        end
      end)

    assert_receive :listening
    Phoenix.PubSub.subscribe(Hireme.PubSub, Desk.topic(account.id))
    job = job(profile(), %{company: "Mine"})

    task =
      Task.async(fn ->
        Repo.put_account(account.id)
        Desk.set_stage(job.id, :gated)
        send(parent, :wrote)
      end)

    Task.await(task)
    assert_receive :wrote
    assert_receive {:desk_event, %{job_id: id}}, 500
    assert id == job.id
    send(listener, :stop)
    assert_receive :quiet
    refute_receive :leaked
  end

  test "audit under one account does not list the other's events", %{account: account} do
    Audit.record(:session_started, %{marker: "mine"}, %{account_id: account.id})
    other = Hireme.DataCase.open_account("Other desk")
    Audit.record(:session_started, %{marker: "theirs"}, %{account_id: other.id})
    assert Enum.all?(Audit.recent(), &(&1.meta["marker"] != "mine"))
    Hireme.DataCase.open_account("Back to mine")
    Repo.put_account(account.id)
    assert Enum.any?(Audit.recent(), &(&1.meta["marker"] == "mine"))
    refute Enum.any?(Audit.recent(), &(&1.meta["marker"] == "theirs"))
  end

  test "a session dies when idle, expired, or revoked, and is touched at most once a minute", %{
    account: account
  } do
    {token, session} = Accounts.start_session(account)
    assert {%{}, _} = Accounts.session(token)
    again = Accounts.session(token)
    assert {%{last_seen_at: seen}, _} = again
    assert seen == session.last_seen_at

    idle =
      session
      |> Ecto.Changeset.change(last_seen_at: DateTime.add(session.last_seen_at, -3601, :second))
      |> Repo.update!(skip_account: true)

    assert Accounts.session(token) == nil

    revived =
      idle
      |> Ecto.Changeset.change(last_seen_at: ago(61))
      |> Repo.update!(skip_account: true)

    assert {%{last_seen_at: touched}, _} = Accounts.session(token)
    assert DateTime.compare(touched, revived.last_seen_at) == :gt

    expired =
      Repo.reload!(revived)
      |> Ecto.Changeset.change(expires_at: ago(1))
      |> Repo.update!(skip_account: true)

    assert Accounts.session(token) == nil

    Repo.update!(
      Ecto.Changeset.change(expired,
        expires_at: session.expires_at,
        revoked_at: ago(0)
      ),
      skip_account: true
    )

    assert Accounts.session(token) == nil
  end

  test "suspending the account kills the session and the page says so" do
    post(anonymous(), "/sign-in/email", %{email: "held@example.com"})
    token = mailed("held@example.com")
    signed = post(anonymous(), "/sign-in/email/confirm", token: token)
    account_id = (recycle(signed) |> get("/api/account") |> json_response(200))["account"]["id"]

    account = Repo.get!(Accounts.Account, account_id, skip_account: true)
    Repo.update!(Ecto.Changeset.change(account, status: :suspended), skip_account: true)

    assert {:error, :suspended} =
             Accounts.sign_in_with(:email, %{
               subject: "held@example.com",
               display: "held@example.com"
             })

    assert redirected_to(recycle(signed) |> get("/")) == "/sign-in"

    # A fresh link for the suspended address is refused at sign-in with 403.
    :ets.delete_all_objects(Hireme.RateLimit)
    post(anonymous(), "/sign-in/email", %{email: "held@example.com"})
    refused = post(anonymous(), "/sign-in/email/confirm", token: mailed("held@example.com"))
    assert html_response(refused, 403) =~ "suspended"
  end

  test "a forged, truncated, or swapped cookie is refused and does not 500" do
    page = call(Plug.Test.conn(:get, "/sign-in"))
    [cookie] = set_cookie(page)
    csrf = csrf!(page)

    authed =
      form(
        page,
        "/sign-in/email",
        "_csrf_token=#{URI.encode_www_form(csrf)}&email=cookie%40example.com"
      )

    assert authed.status == 200
    link = mailed("cookie@example.com")
    shown = call(recycle_cookies(Plug.Test.conn(:get, "/sign-in/email?token=#{link}"), authed))

    entered =
      form(
        shown,
        "/sign-in/email/confirm",
        "_csrf_token=#{URI.encode_www_form(csrf!(shown))}&token=#{link}"
      )

    assert entered.status in [200, 302]
    [live] = set_cookie(entered)

    for broken <- [flip(live), String.slice(cookie_pair(live), 0, 24), cookie_pair(cookie), ""] do
      conn =
        Plug.Test.conn(:get, "/api/account")
        |> put_req_header("accept", "application/json")
        |> put_req_header("cookie", broken)

      response = call(conn)

      assert response.status in [302, 401],
             "status #{response.status} for #{inspect(String.slice(broken, 0, 24))}"

      refute response.status == 500
    end
  end

  test "csrf from another session, a flipped token, and a token in the wrong place are refused" do
    a = call(Plug.Test.conn(:get, "/sign-in"))
    b = call(Plug.Test.conn(:get, "/sign-in"))
    token_a = csrf!(a)
    flipped = token_a <> "x"

    assert_error_sent 403, fn ->
      form(b, "/sign-in/email", "_csrf_token=#{URI.encode_www_form(token_a)}&email=a%40b.co")
    end

    assert_error_sent 403, fn ->
      form(a, "/sign-in/email", "_csrf_token=#{URI.encode_www_form(flipped)}&email=a%40b.co")
    end

    # Plug accepts the token as a body param or the x-csrf-token header.
    # A query param is neither, so it does not count.
    raw =
      Plug.Test.conn(
        :post,
        "/api/account/keys?_csrf_token=#{URI.encode_www_form(token_a)}",
        "{}"
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> recycle_cookies(a)

    assert_error_sent 403, fn -> call(raw) end
  end

  test "a multipart body and an unknown content type do not raise" do
    page = call(Plug.Test.conn(:get, "/sign-in"))
    csrf = csrf!(page)

    multipart =
      "--bound\r\nContent-Disposition: form-data; name=\"email\"\r\n\r\nx@y.co\r\n" <>
        "--bound\r\nContent-Disposition: form-data; name=\"_csrf_token\"\r\n\r\n#{csrf}\r\n--bound--\r\n"

    # Parsers pass multipart and unknown types through. The body is not
    # read, so the token never arrives and the request is refused.
    assert_error_sent 403, fn ->
      Plug.Test.conn(:post, "/sign-in/email", multipart)
      |> put_req_header("content-type", "multipart/form-data; boundary=bound")
      |> put_req_header("cookie", cookie_header(page))
      |> call()
    end

    assert_error_sent 403, fn ->
      Plug.Test.conn(:post, "/sign-in/email", "email=x@y.co")
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("cookie", cookie_header(page))
      |> call()
    end
  end

  test "html pages carry the desk CSP, and the link page is not stored" do
    sign_in = call(Plug.Test.conn(:get, "/sign-in"))
    assert csp?(sign_in)
    assert get_resp_header(sign_in, "permissions-policy") != []
    assert get_resp_header(sign_in, "cross-origin-opener-policy") == ["same-origin"]
    assert get_resp_header(sign_in, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(sign_in, "x-frame-options") != []
    assert get_resp_header(sign_in, "referrer-policy") != []

    post(anonymous(), "/sign-in/email", %{email: "headers@example.com"})
    token = mailed("headers@example.com")
    link = get(anonymous(), "/sign-in/email", token: token)
    assert get_resp_header(link, "cache-control") == ["no-store"]
    assert get_resp_header(link, "referrer-policy") == ["no-referrer"]
    assert csp?(link)
  end

  test "a magic link stores only a hash, expires on the boundary, and one token redeems once" do
    :ok =
      Accounts.request_link(
        "hash@example.com",
        &"https://example.test/sign-in/email?token=#{&1}",
        %{ip: "203.0.113.5"}
      )

    assert_received {:email, %Swoosh.Email{text_body: body}}
    [_, token] = Regex.run(~r{token=([A-Za-z0-9_-]+)}, body)
    raw = Base.url_decode64!(token, padding: false)
    hashes = Repo.all(from(l in MagicLink, select: l.token_hash), skip_account: true)
    refute Enum.any?(hashes, &(Base.encode64(&1) == token or &1 == raw))
    assert Security.hash(raw) in hashes

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    dead = plant_link("dead@example.com", now)
    live = plant_link("live@example.com", DateTime.add(now, 1, :second))
    assert Accounts.peek_link(dead) == {:error, :invalid}
    assert {:ok, "live@example.com"} = Accounts.peek_link(live)

    parent = self()

    tasks =
      for _ <- 1..20 do
        Task.async(fn ->
          send(parent, Accounts.redeem_link(token, %{ip: "203.0.113.9"}))
        end)
      end

    Enum.each(tasks, &Task.await/1)

    results =
      for _ <- 1..20 do
        assert_receive message
        message
      end

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
  end

  test "addresses that are not addresses do not raise, and two asks look the same" do
    samples = [
      "a@b.co",
      "  A@B.CO ",
      "a+b@b.co",
      "a@b.co.",
      "line\r\nBcc: x@y.co",
      "a@b.co\n",
      "مستخدم@example.com",
      "\u202ereverse@example.com",
      String.duplicate("a", 250) <> "@b.co",
      "",
      nil,
      ["a@b.co"],
      %{"email" => "a@b.co"}
    ]

    for sample <- samples do
      assert match?({:ok, binary} when is_binary(binary), Accounts.normalize_email(sample)) or
               Accounts.normalize_email(sample) == {:error, :invalid}
    end

    one = anonymous() |> post("/sign-in/email", %{email: "has@example.com"}) |> html_response(200)

    two =
      anonymous() |> post("/sign-in/email", %{email: "has-not@example.com"}) |> html_response(200)

    scrub = fn html, address ->
      html
      |> String.replace(address, "ADDR")
      |> String.replace(~r/name="_csrf_token" value="[^"]+"/, ~s(name="_csrf_token" value="CSRF"))
    end

    assert scrub.(one, "has@example.com") == scrub.(two, "has-not@example.com")

    events =
      Repo.all(from(e in Audit.Event, where: e.kind == "link_requested"), skip_account: true)

    assert events != []

    assert Enum.all?(events, fn event ->
             meta = event.meta

             is_binary(meta["email_hash"]) and byte_size(meta["email_hash"]) == 16 and
               meta["domain"] in ["example.com"] and not Map.has_key?(meta, "email")
           end)
  end

  test "link limits stop at the boundary and do not share a bucket" do
    for n <- 1..20,
        do:
          assert(:ok = Accounts.request_link("peer#{n}@example.com", & &1, %{ip: "198.51.100.1"}))

    assert {:error, :rate_limited} =
             Accounts.request_link("peer21@example.com", & &1, %{ip: "198.51.100.1"})

    :ets.delete_all_objects(Hireme.RateLimit)

    for _ <- 1..5,
        do: assert(:ok = Accounts.request_link("pinned@example.com", & &1, %{ip: unique_ip()}))

    assert {:error, :rate_limited} =
             Accounts.request_link("pinned@example.com", & &1, %{ip: unique_ip()})

    # A different policy still has room.
    assert :ok = Security.limit(:link_peer, "pinned@example.com")

    dump = inspect(:ets.tab2list(Hireme.RateLimit))
    assert dump =~ "link_address:"
    assert dump =~ "link_peer:"
  end

  test "an oauth authorize URL ignores a forged host, and a callback without state writes nothing" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "evil.example")
      |> Plug.Test.init_test_session(%{})

    assert {:ok, _, url} = HiremeWeb.SignIn.begin(conn, :github, :sign_in)
    refute url =~ "evil.example"
    assert url =~ "localhost"

    refused = get(anonymous(), "/auth/github/callback", code: "code")
    assert redirected_to(refused) =~ "error=failed"
    assert Repo.aggregate(Accounts.Identity, :count, skip_account: true) == 0
  end

  test "totp accepts one step of grace, refuses two, and keeps the secret sealed", %{
    session: session
  } do
    %{secret: secret32, svg: svg, uri: uri} = Mfa.begin_totp(session, "me")
    secret = Base.decode32!(secret32, padding: false)
    {:ok, method, _} = Mfa.confirm_totp(session, NimbleTOTP.verification_code(secret), "Phone")
    assert method.totp_secret != secret
    assert :error = Base.decode32(method.totp_secret, padding: false)
    assert :error = Security.unseal(method.totp_secret, "other key")
    refute method.totp_secret =~ uri
    refute method.totp_secret =~ svg

    stored = Repo.reload!(method)
    refute stored.totp_secret == secret

    now = System.os_time(:second)

    {_, fresh} =
      Accounts.start_session(Repo.get!(Accounts.Account, session.account_id, skip_account: true))

    assert {:error, :code} =
             Mfa.verify_totp(fresh, NimbleTOTP.verification_code(secret, time: now - 60))

    assert {:error, :code} =
             Mfa.verify_totp(fresh, NimbleTOTP.verification_code(secret, time: now + 60))

    for code <- ["12 34 56", "12345", "1234567", "١٢٣٤٥٦", "", nil] do
      assert {:error, _} = Mfa.verify_totp(fresh, code)
    end
  end

  test "one hundred failures disable the factor", %{session: session, account: account} do
    assert {:ok, _} =
             Accounts.link(:email, %{
               subject: "lockout@example.com",
               display: "lockout@example.com"
             })

    %{secret: secret32} = Mfa.begin_totp(session, "me")
    secret = Base.decode32!(secret32, padding: false)
    {:ok, _, _} = Mfa.confirm_totp(session, NimbleTOTP.verification_code(secret), "Phone")
    {_, fresh} = Accounts.start_session(account)

    for _batch <- 1..10 do
      :ets.delete_all_objects(Hireme.RateLimit)

      for _ <- 1..10 do
        assert {:error, :code} = Mfa.verify_totp(fresh, "000000")
      end
    end

    assert [%{disabled_at: at, consecutive_failures: 100}] =
             Repo.all(from(m in Method, where: m.account_id == ^account.id))

    assert at

    subjects =
      Stream.repeatedly(fn ->
        receive do
          {:email, %Swoosh.Email{subject: subject}} -> subject
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(&is_binary/1)

    assert Enum.any?(subjects, &(&1 =~ "disabled"))
  end

  test "passkey options list algorithms and credentials this account already has", %{
    session: session,
    account: account
  } do
    credential_id = :crypto.strong_rand_bytes(16)

    %Method{}
    |> Method.changeset(%{
      account_id: account.id,
      kind: :webauthn,
      name: "key",
      credential_id: credential_id,
      public_key: :erlang.term_to_binary(%{}),
      verified_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()

    options = Mfa.begin_webauthn(session, "me")
    algs = Enum.map(options.publicKey.pubKeyCredParams, & &1.alg)
    assert algs == [-8, -7, -257]
    assert options.publicKey.authenticatorSelection.residentKey == "preferred"

    assert options.publicKey.excludeCredentials == [
             %{type: "public-key", id: Base.url_encode64(credential_id, padding: false)}
           ]

    for params <- [
          %{"attestationObject" => "AAAA", "clientDataJSON" => "e30"},
          %{
            "attestationObject" => Base.url_encode64(<<0xA0>>, padding: false),
            "clientDataJSON" => Base.url_encode64("{}", padding: false)
          }
        ] do
      Mfa.begin_webauthn(session, "me")
      assert {:error, reason} = Mfa.confirm_webauthn(session, params)
      assert reason in [:attestation, :challenge]
    end
  end

  test "recovery codes are not stored in the clear, and a fresh set kills the old one", %{
    session: session
  } do
    %{secret: secret32} = Mfa.begin_totp(session, "me")
    secret = Base.decode32!(secret32, padding: false)

    {:ok, _, [code | _]} =
      Mfa.confirm_totp(session, NimbleTOTP.verification_code(secret), "Phone")

    rows = Repo.all(Hireme.Mfa.RecoveryCode)
    bare = code |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

    refute Enum.any?(rows, fn row ->
             is_binary(row.code_hash) and (row.code_hash == bare or row.salt == bare)
           end)

    assert {:ok, _} = Mfa.verify_recovery(session, String.replace(code, "-", " "))
    fresh = Mfa.recovery_codes!(%{})
    assert {:error, :code} = Mfa.verify_recovery(session, code)
    assert {:ok, _} = Mfa.verify_recovery(session, hd(fresh))
  end

  test "every step-up route refuses a stale session before it writes", %{
    conn: conn,
    account: account,
    session: session
  } do
    %{secret: secret32} = Mfa.begin_totp(session, "me")
    secret = Base.decode32!(secret32, padding: false)

    conn
    |> post("/api/account/mfa/totp/confirm", %{
      code: NimbleTOTP.verification_code(secret),
      name: "Phone"
    })
    |> json_response(200)

    {:ok, %{key: key}} = ApiKeys.create("keep")
    {:ok, identity} = Accounts.link(:github, %{subject: "sub-1", display: "octo"})
    keys_before = Repo.aggregate(ApiKeys.Key, :count)
    methods_before = Repo.aggregate(Method, :count)

    stale =
      DateTime.utc_now()
      |> DateTime.add(-Security.step_up_window(), :second)
      |> DateTime.truncate(:second)

    for s <- Accounts.list_sessions(account.id) do
      s
      |> Ecto.Changeset.change(mfa_at: stale, authenticated_at: stale)
      |> Repo.update!(skip_account: true)
    end

    assert %{"error" => "step_up"} =
             conn |> post("/api/account/keys", %{name: "nope"}) |> json_response(403)

    assert %{"error" => "step_up"} =
             conn |> delete("/api/account/keys/#{key.id}") |> json_response(403)

    assert %{"error" => "step_up"} =
             conn |> post("/api/account/sessions/revoke_others") |> json_response(403)

    assert %{"error" => "step_up"} = conn |> post("/api/account/mfa/totp") |> json_response(403)

    assert %{"error" => "step_up"} =
             conn
             |> post("/api/account/mfa/totp/confirm", %{code: "000000"})
             |> json_response(403)

    assert %{"error" => "step_up"} =
             conn |> post("/api/account/mfa/webauthn") |> json_response(403)

    assert %{"error" => "step_up"} =
             conn |> post("/api/account/mfa/webauthn/confirm", %{}) |> json_response(403)

    assert %{"error" => "step_up"} = conn |> delete("/api/account/mfa/1") |> json_response(403)

    assert %{"error" => "step_up"} =
             conn |> post("/api/account/mfa/recovery") |> json_response(403)

    assert %{"error" => "step_up"} =
             conn |> post("/api/account/identities", %{provider: "github"}) |> json_response(403)

    assert %{"error" => "step_up"} =
             conn |> delete("/api/account/identities/#{identity.id}") |> json_response(403)

    assert Repo.aggregate(ApiKeys.Key, :count) == keys_before
    assert Repo.aggregate(Method, :count) == methods_before
    assert ApiKeys.get(key.id).revoked_at == nil
    assert Accounts.identities() |> Enum.map(& &1.id) |> Enum.member?(identity.id)
  end

  test "a pending session cannot mark itself fresh through the step-up routes", %{
    account: account,
    session: session
  } do
    %{secret: secret32} = Mfa.begin_totp(session, "me")
    secret = Base.decode32!(secret32, padding: false)
    Mfa.confirm_totp(session, NimbleTOTP.verification_code(secret), "Phone")
    {token, pending} = Accounts.start_session(account)
    assert pending.mfa_at == nil
    conn = anonymous() |> init_test_session(%{HiremeWeb.Auth.session_key() => token})
    code = NimbleTOTP.verification_code(secret, time: System.os_time(:second) + 30)

    assert %{"error" => "second_factor"} =
             conn |> post("/api/account/step-up/totp", %{code: code}) |> json_response(401)

    assert Repo.reload!(pending).mfa_at == nil
  end

  test "a bad checksum never reads the database, and the 101st key is refused", %{
    account: account
  } do
    parent = self()
    ref = make_ref()

    handler = fn [:hireme, :repo, :query], _measurements, metadata, _ ->
      send(parent, {ref, metadata.source})
    end

    :telemetry.attach(ref, [:hireme, :repo, :query], handler, nil)

    assert :error =
             ApiKeys.authenticate(
               "hm_" <> String.duplicate("a", 12) <> "_" <> String.duplicate("b", 49),
               "peer-x"
             )

    :telemetry.detach(ref)
    refute_receive {^ref, _}, 50

    for n <- 1..100, do: assert({:ok, _} = ApiKeys.create("k#{n}"))
    assert {:error, :limit} = ApiKeys.create("overflow")

    assert Repo.aggregate(
             from(k in ApiKeys.Key, where: k.account_id == ^account.id and is_nil(k.revoked_at)),
             :count
           ) == 100
  end

  test "last_used_at moves at most once a minute" do
    {:ok, %{secret: secret, key: key}} = ApiKeys.create("clock")
    assert {:ok, used} = ApiKeys.authenticate(secret, "peer-y")
    assert used.last_used_at
    assert {:ok, again} = ApiKeys.authenticate(secret, "peer-y")
    assert again.last_used_at == used.last_used_at

    aged = DateTime.add(used.last_used_at, -61, :second)

    key
    |> Ecto.Changeset.change(last_used_at: aged)
    |> Repo.update!(skip_account: true)

    assert {:ok, moved} = ApiKeys.authenticate(secret, "peer-y")
    assert DateTime.compare(moved.last_used_at, aged) == :gt
  end

  test "an open socket stops when its key is revoked", %{conn: conn} do
    job = job(profile(), %{company: "Socket Co"})
    box = Hireme.Letterbox.for_job(job.id).id

    %{"secret" => secret} =
      conn |> post("/api/account/keys", %{name: "socket"}) |> json_response(200)

    info = %{
      params: %{"letterbox_id" => to_string(box)},
      connect_info: %{
        x_headers: [{"x-api-key", secret}],
        peer_data: %{address: {198, 51, 100, 8}}
      }
    }

    assert {:ok, state} = HiremeWeb.McpSocket.connect(info)
    assert {:ok, state} = HiremeWeb.McpSocket.init(state)
    key = ApiKeys.list() |> Enum.find(&(&1.name == "socket"))
    ApiKeys.revoke(key)
    assert_receive :api_key_dead
    assert :error = HiremeWeb.McpSocket.connect(info)
    assert {:stop, :revoked, _} = HiremeWeb.McpSocket.handle_info(:api_key_dead, state)

    assert {:stop, :revoked, _} =
             HiremeWeb.McpSocket.handle_in({~s({"id":1,"method":"tools/list"}), []}, state)
  end

  test "settings JSON after create does not repeat the secret", %{conn: conn} do
    created = conn |> post("/api/account/keys", %{name: "once"}) |> json_response(200)
    secret = created["secret"]
    listed = conn |> get("/api/account") |> json_response(200)
    encoded = Jason.encode!(listed)
    refute encoded =~ secret
    refute encoded =~ ~r/hm_[0-9A-Za-z]{12}_[0-9A-Za-z]{43}/
  end

  test "a notice subject stays one header when the name contains a newline" do
    :ok =
      Hireme.Mailer.notice("who@example.com", :api_key_created, %{
        name: "ok\r\nBcc: evil@example.com"
      })

    assert_received {:email, %Swoosh.Email{subject: subject, headers: headers}}
    refute subject =~ "\r"
    refute subject =~ "\n"
    subjects = Enum.filter(headers, fn {name, _} -> String.downcase(name) == "subject" end)
    assert length(subjects) <= 1
  end

  test "two first sign-ins of one subject leave one identity" do
    claim = %{subject: "race-subject", display: "Racer"}

    tasks =
      for _ <- 1..2 do
        Task.async(fn -> Accounts.sign_in_with(:github, claim, %{ip: "198.51.100.20"}) end)
      end

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.all?(results, &match?({:ok, _, _}, &1))

    count =
      Repo.aggregate(from(i in Accounts.Identity, where: i.subject == "race-subject"), :count,
        skip_account: true
      )

    assert count == 1
  end

  test "freshness flips at the step-up boundary", %{session: session} do
    assert Mfa.fresh?(session)

    edge =
      DateTime.utc_now()
      |> DateTime.add(-Security.step_up_window(), :second)
      |> DateTime.truncate(:second)

    inside = DateTime.add(edge, 2, :second)

    aged =
      session |> Ecto.Changeset.change(authenticated_at: edge) |> Repo.update!(skip_account: true)

    refute Mfa.fresh?(aged)

    young =
      aged |> Ecto.Changeset.change(authenticated_at: inside) |> Repo.update!(skip_account: true)

    assert Mfa.fresh?(young)
  end

  defp mailed(address) do
    assert_received {:email, %Swoosh.Email{to: [{_, ^address}], text_body: body}}
    [_, token] = Regex.run(~r{/sign-in/email\?token=([A-Za-z0-9_-]+)}, body)
    token
  end

  defp plant_link(email, expires_at) do
    raw = :crypto.strong_rand_bytes(32)

    %MagicLink{}
    |> MagicLink.changeset(%{
      email: email,
      token_hash: Security.hash(raw),
      expires_at: expires_at
    })
    |> Repo.insert!(skip_account: true)

    Base.url_encode64(raw, padding: false)
  end

  defp call(conn), do: @endpoint.call(conn, [])

  defp csrf!(conn) do
    cond do
      match = Regex.run(~r/name="csrf-token" content="([^"]+)"/, conn.resp_body) ->
        Enum.at(match, 1)

      match = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, conn.resp_body) ->
        Enum.at(match, 1)
    end
  end

  defp set_cookie(conn) do
    for {"set-cookie", value} <- conn.resp_headers,
        String.starts_with?(value, "__Host-hireme="),
        do: value
  end

  defp cookie_pair(header), do: header |> String.split(";", parts: 2) |> hd()

  defp cookie_header(conn) do
    case set_cookie(conn) do
      [header | _] -> cookie_pair(header)
      [] -> ""
    end
  end

  defp ago(seconds) do
    DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)
  end

  defp recycle_cookies(conn, from), do: Plug.Test.recycle_cookies(conn, from)

  defp form(from, path, body) do
    Plug.Test.conn(:post, path, body)
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> recycle_cookies(from)
    |> call()
  end

  defp flip(cookie) do
    [name, value] = cookie_pair(cookie) |> String.split("=", parts: 2)
    name <> "=" <> String.reverse(value)
  end

  defp csp?(conn) do
    [policy] = get_resp_header(conn, "content-security-policy")

    policy =~ "script-src 'self'" and policy =~ "frame-ancestors 'none'" and
      policy =~ "base-uri 'none'" and
      policy =~ "object-src 'none'" and policy =~ "form-action 'self'"
  end

  defp unique_ip, do: "203.0.113.#{:rand.uniform(200)}"

  # A `none` attestation wax accepts: UV and UP set, rpIdHash of the test
  # origin's host, and a P-256 COSE key. The challenge bytes are the ones
  # `begin_webauthn/2` just sealed for this session.
  defp attestation(session, credential_id, name \\ "key") do
    options = Mfa.begin_webauthn(session, "me")
    challenge = options.publicKey.challenge
    {public, _private} = :crypto.generate_key(:ecdh, :secp256r1)
    <<4, x::binary-size(32), y::binary-size(32)>> = public
    cose = CBOR.encode(%{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y})

    auth_data =
      :crypto.hash(:sha256, options.publicKey.rp.id) <>
        <<0x45, 0::unsigned-big-integer-size(32)>> <>
        <<0::128>> <>
        <<byte_size(credential_id)::unsigned-big-integer-size(16)>> <>
        credential_id <>
        cose

    object = CBOR.encode(%{"fmt" => "none", "attStmt" => %{}, "authData" => auth_data})

    client =
      Jason.encode!(%{
        "type" => "webauthn.create",
        "challenge" => challenge,
        "origin" => "http://www.example.com"
      })

    %{
      "name" => name,
      "attestationObject" => Base.url_encode64(object, padding: false),
      "clientDataJSON" => Base.url_encode64(client, padding: false)
    }
  end
end
