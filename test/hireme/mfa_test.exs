defmodule Hireme.MfaTest do
  use Hireme.DataCase, async: false

  alias Hireme.Accounts
  alias Hireme.Mfa
  alias Hireme.Mfa.Method
  alias Hireme.Repo

  @code_shape ~r/\A[a-z2-9]{4}-[a-z2-9]{4}-[a-z2-9]{4}-[a-z2-9]{4}\z/

  setup %{account: account} do
    {_token, session} = Accounts.start_session(account)
    {:ok, session: session}
  end

  defp enroll_app(session, name \\ "Phone") do
    %{uri: uri, secret: secret32} = Mfa.begin_totp(session, "me")
    assert uri =~ "otpauth://totp/Hireme:me?"
    secret = Base.decode32!(secret32, padding: false)
    {:ok, method, codes} = Mfa.confirm_totp(session, NimbleTOTP.verification_code(secret), name)
    {method, secret, codes}
  end

  test "an app enrols with the code it shows, and the first factor brings recovery codes", %{
    session: session
  } do
    refute Mfa.enrolled?()
    refute Mfa.required?(session)
    assert Mfa.fresh?(session)

    {method, secret, codes} = enroll_app(session)
    assert method.kind == :totp and method.name == "Phone"
    assert length(codes) == 10 and Enum.all?(codes, &(&1 =~ @code_shape))
    assert Mfa.recovery_codes_left() == 10
    assert Mfa.enrolled?()
    assert [%{kind: :totp}] = Mfa.methods()

    # The session that enrolled is fresh; a new session must present the factor.
    assert Mfa.fresh?(Repo.reload!(session))

    {_, fresh} =
      Accounts.start_session(
        Repo.get!(Hireme.Accounts.Account, session.account_id, skip_account: true)
      )

    assert Mfa.required?(fresh)
    refute Mfa.fresh?(fresh)

    # The enrolment code is spent; the next step's code is not.
    assert {:error, :code} = Mfa.verify_totp(fresh, NimbleTOTP.verification_code(secret))
    later = NimbleTOTP.verification_code(secret, time: System.os_time(:second) + 30)
    assert {:ok, proven} = Mfa.verify_totp(fresh, later)
    assert proven.mfa_at
    refute Mfa.required?(proven)
    assert Mfa.fresh?(proven)

    # A second app needs the old one's code only through the controller; here it enrols directly.
    {second, _, no_codes} = enroll_app(proven, "Tablet")
    assert no_codes == []
    assert Enum.map(Mfa.methods(), & &1.id) == [method.id, second.id]
  end

  test "a wrong code counts, attempts are throttled, and freshness wears off", %{session: session} do
    {_method, _secret, _codes} = enroll_app(session)

    {_, s} =
      Accounts.start_session(
        Repo.get!(Hireme.Accounts.Account, session.account_id, skip_account: true)
      )

    for _ <- 1..10, do: assert({:error, :code} = Mfa.verify_totp(s, "000000"))
    assert {:error, :rate_limited} = Mfa.verify_totp(s, "000000")
    assert [%{consecutive_failures: 10}] = Mfa.methods()

    stale =
      DateTime.utc_now()
      |> DateTime.add(-(Hireme.Security.step_up_window() + 1), :second)
      |> DateTime.truncate(:second)

    aged =
      session
      |> Ecto.Changeset.change(mfa_at: stale, authenticated_at: stale)
      |> Repo.update!(skip_account: true)

    refute Mfa.fresh?(aged)
  end

  test "a recovery code works once, and removing the last factor discards the rest", %{
    session: session
  } do
    {method, _secret, [code | _]} = enroll_app(session)

    {_, s} =
      Accounts.start_session(
        Repo.get!(Hireme.Accounts.Account, session.account_id, skip_account: true)
      )

    assert {:ok, proven} = Mfa.verify_recovery(s, String.upcase(code))
    assert proven.mfa_at
    assert Mfa.recovery_codes_left() == 9
    assert {:error, :code} = Mfa.verify_recovery(proven, code)

    assert {:error, :step_up} = Mfa.remove(aged(s), method)
    assert :ok = Mfa.remove(Repo.reload!(session), method)
    assert Mfa.methods() == []
    assert Mfa.recovery_codes_left() == 0
    refute Mfa.required?(s)
  end

  test "reissuing recovery codes replaces unused codes without reviving spent ones", %{
    session: session
  } do
    [spent, unused | _] = Mfa.recovery_codes!()
    assert {:ok, _} = Mfa.verify_recovery(session, spent)
    [replacement | _] = Mfa.recovery_codes!()
    assert Mfa.recovery_codes_left() == 10
    assert {:error, :code} = Mfa.verify_recovery(session, spent)
    assert {:error, :code} = Mfa.verify_recovery(session, unused)
    assert {:ok, _} = Mfa.verify_recovery(session, replacement)
    assert Mfa.recovery_codes_left() == 9
  end

  test "a passkey registration starts with the browser's options and refuses a forged response",
       %{session: session} do
    options = Mfa.begin_webauthn(session, "me")

    assert %{
             publicKey: %{
               challenge: challenge,
               rp: %{id: "www.example.com", name: "Hireme"},
               user: %{name: "me"}
             }
           } = options

    assert byte_size(challenge) > 20
    assert options.publicKey.authenticatorSelection.userVerification == "required"
    assert options.publicKey.excludeCredentials == []

    assert {:error, :attestation} =
             Mfa.confirm_webauthn(session, %{
               "attestationObject" => "AAAA",
               "clientDataJSON" => "e30",
               "name" => "key"
             })

    # The challenge was spent by the attempt.
    assert {:error, :challenge} =
             Mfa.confirm_webauthn(session, %{
               "attestationObject" => "AAAA",
               "clientDataJSON" => "e30",
               "name" => "key"
             })

    assert %{publicKey: %{allowCredentials: []}} = Mfa.begin_assertion(session)
  end

  test "factors belong to their account", %{session: session} do
    enroll_app(session)
    Hireme.DataCase.open_account("Other desk")
    refute Mfa.enrolled?()
    assert Mfa.methods() == []
    assert Mfa.recovery_codes_left() == 0
  end

  test "enrollment ignores unverified and disabled factors", %{account: account} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    method =
      %Method{}
      |> Method.changeset(%{account_id: account.id, kind: :totp})
      |> Repo.insert!()

    refute Mfa.enrolled?()
    verified = method |> Ecto.Changeset.change(verified_at: now) |> Repo.update!()
    assert Mfa.enrolled?()
    disabled = verified |> Ecto.Changeset.change(disabled_at: now) |> Repo.update!()
    refute Mfa.enrolled?()
    disabled |> Ecto.Changeset.change(disabled_at: nil) |> Repo.update!()
    assert Mfa.enrolled?()
  end

  defp aged(session) do
    stale =
      DateTime.utc_now()
      |> DateTime.add(-(Hireme.Security.step_up_window() + 1), :second)
      |> DateTime.truncate(:second)

    session
    |> Ecto.Changeset.change(mfa_at: stale, authenticated_at: stale)
    |> Repo.update!(skip_account: true)
  end

  test "an account with no factor is fresh only just after signing in", %{session: session} do
    assert Mfa.fresh?(session)
    refute Mfa.fresh?(aged(session))
  end
end
