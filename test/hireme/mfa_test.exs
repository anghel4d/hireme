defmodule Hireme.MfaTest do
  use Hireme.DataCase, async: false

  alias Hireme.Accounts
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

  test "an enrolled app makes new sessions pending until a code is presented, and a code works once",
       %{session: s, email: email} do
    {secret, _factor, codes} = enroll(s)
    assert length(codes) == 10
    assert Enum.all?(codes, &(&1 =~ ~r/\A[a-z2-9]{4}(-[a-z2-9]{4}){3}\z/))

    {:ok, _, later} = Accounts.sign_in_with(:email, %{subject: email, display: email})
    assert Mfa.required?(later)

    # The enrolment spent the current step; the next step's code is inside
    # the one-step grace, and is good exactly once.
    c = code(secret, System.os_time(:second) + 30)
    assert {:ok, proved} = Mfa.verify_totp(later, c)
    refute Mfa.required?(proved)
    assert {:error, :code} = Mfa.verify_totp(proved, c)
  end

  test "a recovery code proves the session once", %{session: s, email: email} do
    {_secret, _factor, [first | _]} = enroll(s)
    {:ok, _, later} = Accounts.sign_in_with(:email, %{subject: email, display: email})

    assert {:ok, proved} = Mfa.verify_recovery(later, String.upcase(first))
    refute Mfa.required?(proved)
    assert {:error, :code} = Mfa.verify_recovery(later, first)
    assert Mfa.recovery_codes_left() == 9
  end

  test "enrolling and removing need a fresh session; removing the last factor drops the codes", %{
    session: s
  } do
    stale = age(s, :authenticated_at, Hireme.Security.step_up_window() + 1)
    assert {:error, :step_up} = Mfa.begin_totp(stale, "me")

    {_secret, factor, _codes} = enroll(s)
    s = Repo.get(Hireme.Rows.Session, s.id, skip_account: true)
    assert Mfa.fresh?(s)

    stale = age(s, :mfa_at, Hireme.Security.step_up_window() + 1)
    refute Mfa.fresh?(stale)
    assert {:error, :step_up} = Mfa.remove(stale, factor.id)

    assert :ok = Mfa.remove(s, factor.id)
    refute Mfa.enrolled?()
    assert Mfa.recovery_codes_left() == 0
  end

  test "a wrong code counts against the account's throttle", %{session: s} do
    enroll(s)
    results = for _ <- 1..11, do: Mfa.verify_totp(s, "000000")
    assert {:error, :rate_limited} = List.last(results)
  end

  test "an enrollment challenge answers once", %{session: s} do
    {:ok, %{secret: secret}} = Mfa.begin_totp(s, "me")
    assert {:ok, _, _} = Mfa.confirm_totp(s, code(secret), "phone")
    s = Repo.get(Hireme.Rows.Session, s.id, skip_account: true)
    assert {:error, :challenge} = Mfa.confirm_totp(s, code(secret), "phone")
  end

  test "a passkey ceremony with no prior challenge, or a forged response, is refused", %{
    session: s
  } do
    assert {:error, :challenge} =
             Mfa.confirm_webauthn(s, %{"attestationObject" => "x", "clientDataJSON" => "y"})

    {:ok, %{publicKey: options}} = Mfa.begin_webauthn(s, "laptop")
    assert options.authenticatorSelection.userVerification == "required"

    assert {:error, :attestation} =
             Mfa.confirm_webauthn(s, %{"attestationObject" => "AAAA", "clientDataJSON" => "AAAA"})
  end
end
