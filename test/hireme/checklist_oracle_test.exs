defmodule Hireme.ChecklistOracleTest do
  @moduledoc false
  # Runtime oracles from docs/checklist.md that the rest of the suite does not already pin.
  use HiremeWeb.ConnCase, async: false

  import Ecto.Query

  alias Hireme.Accounts
  alias Hireme.Audit
  alias Hireme.Mfa
  alias Hireme.Mfa.Method
  alias Hireme.Repo

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

    options = Mfa.begin_webauthn(session, "me")

    assert options.publicKey.excludeCredentials == [
             %{type: "public-key", id: Base.url_encode64(credential_id, padding: false)}
           ]

    assert {:error, :duplicate} =
             Mfa.confirm_webauthn(session, attestation(session, credential_id, "again"))
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
        Plug.Test.conn(:get, "/")
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
        "/api/wire/ticket?_csrf_token=#{URI.encode_www_form(token_a)}",
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
    Hireme.Mailer.Outbox.drain()

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

  defp mailed(address) do
    assert_receive {:email, %Swoosh.Email{to: [{_, ^address}], text_body: body}}
    [_, token] = Regex.run(~r{/sign-in/email\?token=([A-Za-z0-9_-]+)}, body)
    token
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

    policy =~ "script-src 'self' 'wasm-unsafe-eval'" and policy =~ "frame-ancestors 'none'" and
      policy =~ "base-uri 'none'" and
      policy =~ "object-src 'none'" and policy =~ "form-action 'self'"
  end

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
