defmodule Hireme.Mfa do
  @moduledoc """
  Second factors for an account: an authenticator app (TOTP, RFC 6238),
  a WebAuthn credential (a passkey in a platform keychain or a security
  key; FIDO2 / WebAuthn Level 3), and the recovery codes that stand in
  when both are out of reach. Never SMS, never email: NIST SP 800-63B-4
  restricts the one and does not allow the other as an authenticator.

  Where the standards are answered:

  - A phishing-resistant option is offered, with user verification on
    every use (63B-4 Sec. 3.2.5, 3.2.10; WebAuthn L3).
  - A TOTP code is accepted once, in its own 30-second step with one
    step of grace either side (63B-4 Sec. 3.2.9; ASVS 6.5.1, 6.5.5).
  - Recovery codes are 80-bit look-up secrets, salted and hashed, each
    used once; ten are issued with the first factor (63B-4 Sec. 3.2.4;
    ASVS 6.5.2, 6.5.4).
  - Attempts are throttled, and a factor that fails one hundred times
    in a row is disabled (63B-4 Sec. 3.2.2; ASVS 6.6.3).
  - A WebAuthn signature counter that does not advance marks a cloned
    credential, which is disabled (WebAuthn L3 Sec. 6.1.1).
  - Binding or removing a factor needs a fresh second factor and the
    account is told through another channel (63B-4 Sec. 4.1.2; ASVS
    6.3.7, 7.5.1).
  - A session on an account with factors is pending until one is
    presented (`required?/1`); a factor presented within the step-up
    window makes the session fresh for sensitive changes (`fresh?/1`).

  Everything here runs as the account on the process.
  """

  import Ecto.Query
  alias Hireme.Accounts
  alias Hireme.Accounts.Session
  alias Hireme.Audit
  alias Hireme.Mfa.Challenge
  alias Hireme.Mfa.Method
  alias Hireme.Mfa.RecoveryCode
  alias Hireme.Mfa.WebAuthn
  alias Hireme.Repo
  alias Hireme.Security

  @issuer "Hireme"
  @recovery_count 10
  # 32 symbols, none that read as another: 80 bits in 16 characters.
  @recovery_alphabet ~c"abcdefghijkmnpqrstuvwxyz23456789"
  @recovery_length 16
  @totp_seal "hireme mfa totp"
  @challenge_seal "hireme mfa challenge"

  @type factor :: :totp | :webauthn | :recovery

  ## Reading

  @doc "The account's live factors, oldest first."
  @spec methods() :: [Method.t()]
  def methods do
    Repo.all(
      from m in Method,
        where: not is_nil(m.verified_at) and is_nil(m.disabled_at),
        order_by: m.id
    )
  end

  @spec enrolled?() :: boolean()
  def enrolled?, do: methods() != []

  @doc "A session that must still present a second factor before it is signed in."
  @spec required?(Session.t()) :: boolean()
  def required?(%Session{mfa_at: nil}), do: enrolled?()
  def required?(%Session{}), do: false

  @doc """
  A session that proved a second factor within the step-up window, or
  that belongs to an account with nothing to prove with.
  """
  @spec fresh?(Session.t()) :: boolean()
  def fresh?(%Session{} = session) do
    case methods() do
      [] ->
        true

      _ ->
        session.mfa_at != nil and
          DateTime.diff(DateTime.utc_now(), session.mfa_at) < Security.step_up_window()
    end
  end

  @spec recovery_codes_left() :: non_neg_integer()
  def recovery_codes_left do
    Repo.aggregate(from(c in RecoveryCode, where: is_nil(c.used_at)), :count)
  end

  ## Authenticator app

  @doc "Start enrolling an app: the otpauth URI, its secret in base32, and a QR as SVG."
  @spec begin_totp(Session.t(), String.t()) :: %{
          uri: String.t(),
          secret: String.t(),
          svg: String.t()
        }
  def begin_totp(%Session{} = session, label) do
    secret = NimbleTOTP.secret()
    challenge!(session, :totp_enroll, secret)
    uri = NimbleTOTP.otpauth_uri("#{@issuer}:#{label}", secret, issuer: @issuer)

    %{
      uri: uri,
      secret: Base.encode32(secret, padding: false),
      svg: uri |> EQRCode.encode() |> EQRCode.svg(viewbox: true)
    }
  end

  @doc "Finish enrolling an app with the code it shows now. The first factor also issues recovery codes."
  @spec confirm_totp(Session.t(), String.t(), String.t(), map()) ::
          {:ok, Method.t(), [String.t()]} | {:error, :challenge | :code}
  def confirm_totp(%Session{} = session, code, name, meta \\ %{}) do
    with {:ok, secret} <- take_challenge(session, :totp_enroll),
         step when is_integer(step) <-
           totp_step(secret, normalize(code), System.os_time(:second), 0) || {:error, :code} do
      first? = not enrolled?()

      method =
        insert_method!(session, %{
          kind: :totp,
          name: name,
          totp_secret: Security.seal(secret, @totp_seal),
          totp_last_used: step
        })

      bound(session, method, meta)
      {:ok, method, if(first?, do: recovery_codes!(meta), else: [])}
    end
  end

  @doc "Present an app code for the session."
  @spec verify_totp(Session.t(), String.t(), map()) ::
          {:ok, Session.t()} | {:error, :code | :rate_limited}
  def verify_totp(%Session{} = session, code, meta \\ %{}) do
    with :ok <- throttle(session) do
      now = System.os_time(:second)
      code = normalize(code)
      apps = Enum.filter(methods(), &(&1.kind == :totp))

      matches =
        Enum.find_value(apps, fn method ->
          step = totp_step(unseal_totp(method), code, now, method.totp_last_used)
          step && {method, step}
        end)

      case matches do
        nil ->
          failed(apps, meta)
          {:error, :code}

        {method, step} ->
          method
          |> Ecto.Changeset.change(
            totp_last_used: step,
            last_used_at: now(),
            consecutive_failures: 0
          )
          |> Repo.update!()

          proved(session, method, meta)
      end
    end
  end

  ## WebAuthn

  @doc "Start registering a passkey or security key: the creation options the browser needs."
  @spec begin_webauthn(Session.t(), String.t()) :: map()
  def begin_webauthn(%Session{} = session, label) do
    challenge = WebAuthn.registration_challenge()
    challenge!(session, :webauthn_register, challenge)
    exclude = methods() |> Enum.filter(&(&1.kind == :webauthn)) |> Enum.map(& &1.credential_id)
    WebAuthn.registration_options(challenge, session.account_id, label, exclude)
  end

  @doc "Finish registering with the browser's attestation response."
  @spec confirm_webauthn(Session.t(), map(), map()) ::
          {:ok, Method.t(), [String.t()]} | {:error, :challenge | :attestation | :duplicate}
  def confirm_webauthn(%Session{} = session, params, meta \\ %{}) do
    with {:ok, challenge} <- take_challenge(session, :webauthn_register),
         {:ok, attrs} <- WebAuthn.register(challenge, params),
         nil <-
           Repo.get_by(Method, [credential_id: attrs.credential_id], skip_account: true) ||
             {:error, :duplicate} do
      first? = not enrolled?()

      method =
        insert_method!(
          session,
          Map.merge(attrs, %{kind: :webauthn, name: to_string(params["name"] || "")})
        )

      bound(session, method, meta)
      {:ok, method, if(first?, do: recovery_codes!(meta), else: [])}
    end
  end

  @doc "Start an assertion: the request options the browser needs."
  @spec begin_assertion(Session.t()) :: map()
  def begin_assertion(%Session{} = session) do
    keys = methods() |> Enum.filter(&(&1.kind == :webauthn))

    challenge =
      WebAuthn.authentication_challenge(
        Enum.map(keys, &WebAuthn.credential({&1.credential_id, &1.public_key}))
      )

    challenge!(session, :webauthn_assert, challenge)
    WebAuthn.assertion_options(challenge, keys)
  end

  @doc "Present the browser's assertion for the session."
  @spec verify_assertion(Session.t(), map(), map()) ::
          {:ok, Session.t()} | {:error, :challenge | :assertion | :clone | :rate_limited}
  def verify_assertion(%Session{} = session, params, meta \\ %{}) do
    keys = methods() |> Enum.filter(&(&1.kind == :webauthn))

    with :ok <- throttle(session),
         {:ok, challenge} <- take_challenge(session, :webauthn_assert),
         {:ok, credential_id, data} <- WebAuthn.authenticate(challenge, params),
         %Method{} = method <-
           Enum.find(keys, &(&1.credential_id == credential_id)) || {:error, :assertion},
         :ok <- counter_advanced(method, data.sign_count, meta) do
      method
      |> Ecto.Changeset.change(
        sign_count: data.sign_count,
        last_used_at: now(),
        consecutive_failures: 0
      )
      |> Repo.update!()

      proved(session, method, meta)
    else
      {:error, :assertion} = error ->
        failed(keys, meta)
        error

      error ->
        error
    end
  end

  ## Recovery codes

  @doc "Replace the account's recovery codes. The list is the only copy."
  @spec recovery_codes!(map()) :: [String.t()]
  def recovery_codes!(meta \\ %{}) do
    Repo.delete_all(from c in RecoveryCode, where: is_nil(c.used_at))
    codes = for _ <- 1..@recovery_count, do: random_code()

    for code <- codes do
      salt = Security.token(16)

      %RecoveryCode{}
      |> RecoveryCode.changeset(%{
        account_id: Repo.account_id!(),
        salt: salt,
        code_hash: Security.hash(salt <> code)
      })
      |> Repo.insert!()
    end

    Audit.record(:recovery_codes_issued, %{count: @recovery_count}, meta)
    Enum.map(codes, &format_code/1)
  end

  @doc "Present a recovery code for the session. It is spent whether or not anything follows."
  @spec verify_recovery(Session.t(), String.t(), map()) ::
          {:ok, Session.t()} | {:error, :code | :rate_limited}
  def verify_recovery(%Session{} = session, code, meta \\ %{}) do
    with :ok <- throttle(session) do
      code = normalize(code)
      unused = Repo.all(from c in RecoveryCode, where: is_nil(c.used_at))

      case Enum.find(unused, &Security.equal?(Security.hash(&1.salt <> code), &1.code_hash)) do
        nil ->
          Audit.record(:recovery_failed, %{}, meta)
          {:error, :code}

        found ->
          found |> Ecto.Changeset.change(used_at: now()) |> Repo.update!()
          left = length(unused) - 1
          Audit.record(:recovery_code_used, %{left: left}, meta)
          Accounts.notify(session.account_id, :recovery_code_used, %{left: left})
          {:ok, Accounts.mark_mfa(session)}
      end
    end
  end

  ## Changing the set

  @spec rename(Method.t(), String.t()) :: {:ok, Method.t()} | {:error, Ecto.Changeset.t()}
  def rename(%Method{} = method, name),
    do: method |> Method.changeset(%{name: name}) |> Repo.update()

  @doc """
  Remove a factor. The session must be fresh. Removing the last factor
  also discards the recovery codes: there is nothing left to recover to.
  """
  @spec remove(Session.t(), Method.t(), map()) :: :ok | {:error, :step_up}
  def remove(%Session{} = session, %Method{} = method, meta \\ %{}) do
    if fresh?(session) do
      Repo.delete!(method)
      if methods() == [], do: Repo.delete_all(RecoveryCode)

      Audit.record(
        :mfa_method_removed,
        %{kind: method.kind, name: method.name, method_id: method.id},
        meta
      )

      Accounts.notify(session.account_id, :authenticator_removed, %{
        kind: method.kind,
        name: method.name
      })

      :ok
    else
      {:error, :step_up}
    end
  end

  ## Internals

  # One step of grace either side; `since` refuses every step at or before the one spent.
  # Answers the step time the code matched, so that step is the one recorded as spent:
  # a code accepted early through the grace is not good again when its own step arrives.
  defp totp_step(secret, code, now, since) do
    Enum.find([now, now - 30, now + 30], &NimbleTOTP.valid?(secret, code, time: &1, since: since))
  end

  defp unseal_totp(%Method{totp_secret: sealed}) do
    case Security.unseal(sealed, @totp_seal) do
      {:ok, secret} -> secret
      :error -> <<>>
    end
  end

  defp counter_advanced(%Method{sign_count: old}, new, _meta) when old == 0 and new == 0, do: :ok
  defp counter_advanced(%Method{sign_count: old}, new, _meta) when new > old, do: :ok

  defp counter_advanced(%Method{} = method, new, meta) do
    method |> Ecto.Changeset.change(disabled_at: now()) |> Repo.update!()

    Audit.record(
      :mfa_clone_suspected,
      %{method_id: method.id, stored: method.sign_count, presented: new},
      meta
    )

    Accounts.notify(method.account_id, :authenticator_disabled, %{
      kind: :webauthn,
      name: method.name,
      reason: :clone
    })

    {:error, :clone}
  end

  defp throttle(%Session{account_id: id}) do
    Security.limit("mfa:#{id}", :timer.minutes(15), 10)
  end

  # Every factor that could have matched took a failure; at the limit it is disabled.
  defp failed(methods, meta) do
    Enum.each(methods, fn method ->
      failures = method.consecutive_failures + 1
      disabled = if failures >= Security.lockout_failures(), do: now()

      method
      |> Ecto.Changeset.change(consecutive_failures: failures, disabled_at: disabled)
      |> Repo.update!()

      if disabled do
        Audit.record(:mfa_method_locked, %{method_id: method.id, kind: method.kind}, meta)

        Accounts.notify(method.account_id, :authenticator_disabled, %{
          kind: method.kind,
          name: method.name,
          reason: :failures
        })
      end
    end)

    Audit.record(:mfa_failed, %{}, meta)
  end

  defp proved(%Session{} = session, %Method{} = method, meta) do
    Audit.record(:mfa_verified, %{method_id: method.id, kind: method.kind}, meta)
    {:ok, Accounts.mark_mfa(session)}
  end

  defp bound(%Session{} = session, %Method{} = method, meta) do
    Accounts.mark_mfa(session)

    Audit.record(
      :mfa_method_added,
      %{method_id: method.id, kind: method.kind, name: method.name},
      meta
    )

    Accounts.notify(session.account_id, :authenticator_added, %{
      kind: method.kind,
      name: method.name
    })
  end

  defp insert_method!(%Session{account_id: account_id}, attrs) do
    %Method{}
    |> Method.changeset(Map.merge(attrs, %{account_id: account_id, verified_at: now()}))
    |> Repo.insert!()
  end

  defp challenge!(%Session{} = session, kind, term) do
    Repo.delete_all(from c in Challenge, where: c.session_id == ^session.id and c.kind == ^kind)

    %Challenge{}
    |> Challenge.changeset(%{
      account_id: session.account_id,
      session_id: session.id,
      kind: kind,
      payload: Security.seal(term, @challenge_seal),
      expires_at: DateTime.add(now(), Security.challenge_ttl(), :second)
    })
    |> Repo.insert!()
  end

  # A challenge answers once, and only before it expires.
  defp take_challenge(%Session{} = session, kind) do
    query =
      from c in Challenge,
        where: c.session_id == ^session.id and c.kind == ^kind,
        order_by: [desc: c.id],
        limit: 1

    with %Challenge{} = challenge <- Repo.one(query),
         _ <- Repo.delete!(challenge),
         :lt <- DateTime.compare(now(), challenge.expires_at),
         {:ok, term} <- Security.unseal(challenge.payload, @challenge_seal) do
      {:ok, term}
    else
      _ -> {:error, :challenge}
    end
  end

  defp random_code do
    Stream.repeatedly(fn -> :binary.first(:crypto.strong_rand_bytes(1)) end)
    |> Stream.filter(&(&1 < 224))
    |> Stream.map(&Enum.at(@recovery_alphabet, rem(&1, 32)))
    |> Enum.take(@recovery_length)
    |> List.to_string()
  end

  defp format_code(code),
    do: code |> String.graphemes() |> Enum.chunk_every(4) |> Enum.map_join("-", &Enum.join/1)

  defp normalize(code),
    do: code |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
