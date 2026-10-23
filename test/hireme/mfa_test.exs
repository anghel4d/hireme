defmodule Hireme.MfaTest do
  use Hireme.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Hireme.Mfa

  setup do
    signed = sign_in()
    Repo.put_account(signed.account.id)
    signed
  end

  defp code(secret32, at \\ System.os_time(:second)),
    do: secret32 |> Base.decode32!(padding: false) |> NimbleTOTP.verification_code(time: at)

  defp enroll(session) do
    {:ok, %{secret: secret}} = Mfa.begin_totp(session, "me")
    {:ok, factor, codes} = Mfa.confirm_totp(session, code(secret), "phone")
    {secret, factor, codes}
  end

  defp pending(email) do
    {:ok, _, session} = Hireme.Accounts.sign_in_with(:email, %{subject: email, display: email})
    session
  end

  defp stale(session, field), do: age(session, field, Hireme.Security.step_up_window() + 1)

  test "an enrolled app makes new sessions pending until an app code or a recovery code is presented, and each works once, even to racing sessions",
       %{session: s, email: email} do
    {secret, _factor, codes} = enroll(s)
    assert length(codes) == 10
    assert Enum.all?(codes, &(&1 =~ ~r/\A[a-z2-9]{4}(-[a-z2-9]{4}){3}\z/))
    later = pending(email)
    assert Mfa.required?(later)

    # The enrolment spent the current step; the next step's code is inside
    # the one-step grace, and is good exactly once, however many sessions race it.
    c = code(secret, System.os_time(:second) + 30)
    parent = self()

    racing =
      for x <- [later | for(_ <- 1..5, do: pending(email))] do
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          Mfa.verify_totp(x, c)
        end)
      end

    assert [{:ok, proved}] = Enum.filter(Task.await_many(racing), &match?({:ok, _}, &1))
    refute Mfa.required?(proved)
    assert {:error, :code} = Mfa.verify_totp(proved, c)

    again = pending(email)
    [first | _] = codes
    assert {:ok, proved} = Mfa.verify_recovery(again, String.upcase(first))
    refute Mfa.required?(proved)
    assert {:error, :code} = Mfa.verify_recovery(again, first)
    assert Mfa.recovery_codes_left() == 9
  end

  test "the first factor binds on any signed-in session; another, or a removal, needs a fresh factor; the wire sessions hear at once; removing the last drops the codes",
       %{session: s} do
    Hireme.PubSub.subscribe(Hireme.Audit.topic(s.account_id))
    assert {:ok, _} = Mfa.begin_totp(stale(s, :authenticated_at), "me")
    {_secret, factor, _codes} = enroll(s)
    assert_receive {Hireme.Audit, :factors}
    s = Repo.get(Hireme.Rows.Session, s.id, skip_account: true)
    assert Mfa.fresh?(s)
    stale = stale(s, :mfa_at)
    refute Mfa.fresh?(stale)
    assert {:error, :step_up} = Mfa.begin_totp(stale, "me")
    assert {:error, :step_up} = Mfa.remove(stale, factor.id)
    assert :ok = Mfa.remove(s, factor.id)
    assert_receive {Hireme.Audit, :factors}
    refute Mfa.enrolled?()
    assert Mfa.recovery_codes_left() == 0
  end

  test "with no factor, a mailed code renews the sign-in once; with one, the factor is asked instead",
       %{session: s} do
    stale = stale(s, :authenticated_at)
    refute Mfa.fresh?(stale)
    assert :ok = Mfa.mail_code(stale)
    assert_receive {:email, mail}, 1_000
    [_, code] = Regex.run(~r/Enter (\d{6})/, mail.text_body)
    wrong = code |> String.to_integer() |> Kernel.+(1) |> rem(1_000_000)
    assert {:error, :code} = Mfa.verify_mail_code(stale, String.pad_leading("#{wrong}", 6, "0"))
    assert {:ok, renewed} = Mfa.verify_mail_code(stale, code)
    assert Mfa.fresh?(renewed)
    assert {:error, :code} = Mfa.verify_mail_code(renewed, code)
    enroll(s)
    assert {:error, :factor} = Mfa.mail_code(s)
    assert {:error, :factor} = Mfa.verify_mail_code(s, code)
  end

  test "an enrolment challenge survives a mistyped code and answers once; then a wrong code counts against the account's throttle",
       %{session: s} do
    {:ok, %{secret: secret}} = Mfa.begin_totp(s, "me")
    assert {:error, :code} = Mfa.confirm_totp(s, "000000", "phone")
    assert {:ok, _, _} = Mfa.confirm_totp(s, code(secret), "phone")
    s = Repo.get(Hireme.Rows.Session, s.id, skip_account: true)
    assert {:error, :challenge} = Mfa.confirm_totp(s, code(secret), "phone")
    results = for _ <- 1..11, do: Mfa.verify_totp(s, "000000")
    assert {:error, :rate_limited} = List.last(results)
  end

  test "a passkey ceremony with no prior challenge, or a forged response, is refused", %{
    session: s
  } do
    forged = &%{"attestationObject" => &1, "clientDataJSON" => &2}
    assert {:error, :challenge} = Mfa.confirm_webauthn(s, forged.("x", "y"))
    {:ok, %{publicKey: options}} = Mfa.begin_webauthn(s, "laptop")
    assert options.authenticatorSelection.userVerification == "required"
    assert {:error, :attestation} = Mfa.confirm_webauthn(s, forged.("AAAA", "AAAA"))
  end

  test "a factor worn out by wrong codes keeps the account behind a second factor", %{
    session: s,
    email: email
  } do
    {_secret, factor, [code | _]} = enroll(s)
    worn = Hireme.Security.lockout_failures() - 1
    Repo.update!(Ecto.Changeset.change(factor, consecutive_failures: worn))
    pending = pending(email)
    assert {:error, :code} = Mfa.verify_totp(pending, "000000")
    assert Mfa.factors() == []
    assert %{"kind" => "totp"} = Enum.find(recent(5), &(&1.kind == "factor_failed")).meta
    # Disabling it is a write of its own: its rev moves past the failure's.
    assert Repo.get(Hireme.Rows.Factor, factor.id).rev > factor.rev + 1
    assert Mfa.required?(pending)
    refute Mfa.fresh?(pending)
    assert {:ok, proved} = Mfa.verify_recovery(pending, code)
    refute Mfa.required?(proved)
  end

  test "the QR draws without inline styles; an authenticator shows the account's own label, an address included, and a label cannot change the secret",
       %{session: s} do
    {:ok, %{svg: svg, uri: uri, secret: secret}} = Mfa.begin_totp(s, "a?secret=AAAA#x")
    refute svg =~ "style="
    assert svg =~ ~s(fill="#000)
    assert URI.decode_query(URI.parse(uri).query)["secret"] == secret
    {:ok, %{uri: uri}} = Mfa.begin_totp(s, "me@example.com")
    assert URI.decode(URI.parse(uri).path) == "/Hireme:me@example.com"
  end

  test "a seed that no longer unseals matches no code, the empty key's least of all", %{
    session: s,
    email: email
  } do
    {secret, _, _} = enroll(s)
    pending = pending(email)
    old = Application.fetch_env!(:hireme, :secret_key_base)
    Application.put_env(:hireme, :secret_key_base, "rotated+" <> String.duplicate("x", 64))
    on_exit(fn -> Application.put_env(:hireme, :secret_key_base, old) end)
    later = System.os_time(:second) + 30

    assert {:error, :code} =
             Mfa.verify_totp(pending, NimbleTOTP.verification_code(<<>>, time: later))

    assert {:error, :code} = Mfa.verify_totp(pending, code(secret, later))
    assert Mfa.required?(pending)
  end
end
