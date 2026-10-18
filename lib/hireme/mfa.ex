defmodule Hireme.Mfa do
  @moduledoc """
  Second factors: an authenticator app (TOTP, RFC 6238), a WebAuthn
  credential (a passkey or a security key; WebAuthn Level 3), both rows
  of the one `factors` table, and the recovery codes that stand in when
  both are out of reach. Never SMS, never email: NIST SP 800-63B-4
  restricts the one and does not allow the other.

  Where the standards are answered:

  - A phishing-resistant option is offered, with user verification on
    every use (63B-4 Sec. 3.2.5, 3.2.10; WebAuthn L3).
  - A TOTP code is accepted once, in its 30-second step with one step of
    grace either side (63B-4 Sec. 3.2.9; ASVS 6.5.1, 6.5.5).
  - Recovery codes are 80-bit look-up secrets, salted and hashed, each
    used once; ten come with the first factor (63B-4 Sec. 3.2.4; ASVS
    6.5.2, 6.5.4).
  - Attempts are throttled, and a factor that fails one hundred times in
    a row is disabled (63B-4 Sec. 3.2.2; ASVS 6.6.3).
  - A WebAuthn signature counter that does not advance marks a cloned
    credential, which is disabled (WebAuthn L3 Sec. 6.1.1).
  - Binding or removing a factor needs a fresh second factor, and the
    account hears of it on another channel (63B-4 Sec. 4.1.2; ASVS
    6.3.7, 7.5.1).
  - A session on an account with factors is pending until one is
    presented (`required?/1`); one presented within the step-up window
    makes the session fresh for sensitive changes (`fresh?/1`).

  Everything here runs as the account on the process.
  """

  import Ecto.Query
  alias Hireme.Accounts
  alias Hireme.Audit
  alias Hireme.Mfa.WebAuthn
  alias Hireme.Repo
  alias Hireme.Rows.Challenge
  alias Hireme.Rows.Factor
  alias Hireme.Rows.RecoveryCode
  alias Hireme.Rows.Session
  alias Hireme.Security
  alias Hireme.Store

  @issuer "Hireme"
  @recovery_count 10
  # 32 symbols, none that reads as another: 80 bits in 16 characters.
  @recovery_alphabet ~c"abcdefghijkmnpqrstuvwxyz23456789"
  @recovery_length 16
  @totp_seal "hireme factor totp"
  @challenge_seal "hireme factor challenge"

  ## Reading

  @doc "The account's live factors, oldest first."
  @spec factors() :: [Factor.t()]
  def factors do
    Repo.all(
      from(f in Factor,
        where: not is_nil(f.verified_at) and is_nil(f.disabled_at),
        order_by: f.id
      )
    )
  end

  @doc "Whether the account has a live factor, without loading a secret."
  @spec enrolled?() :: boolean()
  def enrolled?,
    do:
      Repo.exists?(from(f in Factor, where: not is_nil(f.verified_at) and is_nil(f.disabled_at)))

  @doc "A session that must still present a second factor before it is signed in."
  @spec required?(Session.t()) :: boolean()
  def required?(%Session{mfa_at: nil, account_id: id}), do: Repo.with_account(id, &enrolled?/0)
  def required?(%Session{}), do: false

  @doc """
  A session fit for a sensitive change (ASVS 7.5.1): it proved a factor
  within the step-up window, or, on an account with nothing to prove
  with, it signed in within that window; such an account steps up by
  signing in again.
  """
  @spec fresh?(Session.t()) :: boolean()
  def fresh?(%Session{} = session) do
    proof =
      if Repo.with_account(session.account_id, &enrolled?/0),
        do: session.mfa_at,
        else: session.authenticated_at

    proof != nil and DateTime.diff(Store.now(), proof) < Security.step_up_window()
  end

  @spec recovery_codes_left() :: non_neg_integer()
  def recovery_codes_left,
    do: Repo.aggregate(from(c in RecoveryCode, where: is_nil(c.used_at)), :count)

  ## Authenticator app

  @doc "Start enrolling an app: its otpauth URI, the secret in base32, and a QR as SVG."
  @spec begin_totp(Session.t(), String.t()) ::
          {:ok, %{uri: String.t(), secret: String.t(), svg: String.t()}} | {:error, :step_up}
  def begin_totp(%Session{} = session, label) do
    with :ok <- fresh(session) do
      secret = NimbleTOTP.secret()
      challenge!(session, :totp_enroll, secret)
      uri = NimbleTOTP.otpauth_uri("#{@issuer}:#{label}", secret, issuer: @issuer)

      {:ok,
       %{
         uri: uri,
         secret: Base.encode32(secret, padding: false),
         svg: uri |> EQRCode.encode() |> EQRCode.svg(viewbox: true)
       }}
    end
  end

  @doc "Finish enrolling an app with the code it shows now. The first factor also issues recovery codes."
  @spec confirm_totp(Session.t(), String.t(), String.t(), map()) ::
          {:ok, Factor.t(), [String.t()]} | {:error, :step_up | :challenge | :code}
  def confirm_totp(%Session{} = session, code, name, meta \\ %{}) do
    with :ok <- fresh(session),
         {:ok, secret} <- take_challenge(session, :totp_enroll),
         step when is_integer(step) <-
           totp_step(secret, normalize(code), System.os_time(:second), 0) || {:error, :code} do
      bind(
        session,
        %{
          kind: :totp,
          name: name,
          totp_secret: Security.seal(secret, @totp_seal),
          totp_last_step: step
        },
        meta
      )
    end
  end

  @doc "Present an app code for the session."
  @spec verify_totp(Session.t(), String.t(), map()) ::
          {:ok, Session.t()} | {:error, :code | :rate_limited}
  def verify_totp(%Session{} = session, code, meta \\ %{}) do
    with :ok <- throttle(session) do
      now = System.os_time(:second)
      code = normalize(code)
      apps = Enum.filter(factors(), &(&1.kind == :totp))

      found =
        Enum.find_value(apps, fn f ->
          step = totp_step(unseal_totp(f), code, now, f.totp_last_step || 0)
          step && {f, step}
        end)

      case found do
        nil ->
          failed(apps, meta, session)
          {:error, :code}

        {factor, step} ->
          update!(factor,
            totp_last_step: step,
            last_used_at: Store.now(),
            consecutive_failures: 0
          )

          proved(session, factor, meta)
      end
    end
  end

  ## WebAuthn

  @doc "Start registering a passkey or security key: the creation options for the browser."
  @spec begin_webauthn(Session.t(), String.t()) :: {:ok, map()} | {:error, :step_up}
  def begin_webauthn(%Session{} = session, label) do
    with :ok <- fresh(session) do
      challenge = WebAuthn.registration_challenge()
      challenge!(session, :webauthn_register, challenge)
      exclude = for f <- factors(), f.kind == :webauthn, do: f.credential_id
      {:ok, WebAuthn.registration_options(challenge, session.account_id, label, exclude)}
    end
  end

  @doc "Finish registering with the browser's attestation response."
  @spec confirm_webauthn(Session.t(), map(), map()) ::
          {:ok, Factor.t(), [String.t()]}
          | {:error, :step_up | :challenge | :attestation | :duplicate}
  def confirm_webauthn(%Session{} = session, params, meta \\ %{}) do
    with :ok <- fresh(session),
         {:ok, challenge} <- take_challenge(session, :webauthn_register),
         {:ok, attrs} <- WebAuthn.register(challenge, params),
         :ok <- unused_credential(attrs.credential_id) do
      bind(
        session,
        Map.merge(attrs, %{kind: :webauthn, name: to_string(params["name"] || "")}),
        meta
      )
    end
  end

  @doc "Start an assertion: the request options for the browser."
  @spec begin_assertion(Session.t()) :: map()
  def begin_assertion(%Session{} = session) do
    keys = passkeys()

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
    keys = passkeys()

    with :ok <- throttle(session),
         {:ok, challenge} <- take_challenge(session, :webauthn_assert),
         {:ok, credential_id, data} <- WebAuthn.authenticate(challenge, params),
         %Factor{} = factor <-
           Enum.find(keys, &(&1.credential_id == credential_id)) || {:error, :assertion},
         :ok <- counter_advanced(factor, data.sign_count, meta, session) do
      update!(factor,
        sign_count: data.sign_count,
        last_used_at: Store.now(),
        consecutive_failures: 0
      )

      proved(session, factor, meta)
    else
      {:error, :assertion} = error ->
        failed(keys, meta, session)
        error

      error ->
        error
    end
  end

  defp passkeys, do: Enum.filter(factors(), &(&1.kind == :webauthn))

  ## Recovery codes

  @doc """
  Replace the recovery codes; the session must be fresh. The answer is
  the only plaintext copy.
  """
  @spec regenerate_recovery_codes(Session.t(), map()) ::
          {:ok, [String.t()]} | {:error, :step_up | :no_factor}
  def regenerate_recovery_codes(%Session{} = session, meta \\ %{}) do
    cond do
      not fresh?(session) ->
        {:error, :step_up}

      not enrolled?() ->
        {:error, :no_factor}

      true ->
        codes = recovery_codes!(session, meta)
        Accounts.notify(session.account_id, :recovery_codes_issued, %{})
        {:ok, codes}
    end
  end

  defp recovery_codes!(%Session{} = session, meta) do
    codes = for _ <- 1..@recovery_count, do: random_code()
    now = Store.now()

    rows =
      for code <- codes do
        salt = Security.token(16)

        %{
          account_id: session.account_id,
          salt: salt,
          code_hash: Security.hash(salt <> code),
          rev: 1,
          inserted_at: now,
          updated_at: now
        }
      end

    Store.transaction(fn ->
      Repo.delete_all(from(c in RecoveryCode))
      {@recovery_count, _} = Repo.insert_all(RecoveryCode, rows, skip_account: true)
    end)

    Audit.record(:recovery_codes_issued, %{count: @recovery_count}, ctx(meta, session))
    Enum.map(codes, &format_code/1)
  end

  @doc "Present a recovery code for the session. It is spent whatever follows."
  @spec verify_recovery(Session.t(), String.t(), map()) ::
          {:ok, Session.t()} | {:error, :code | :rate_limited}
  def verify_recovery(%Session{} = session, code, meta \\ %{}) do
    with :ok <- throttle(session) do
      code = normalize(code)
      unused = Repo.all(from(c in RecoveryCode, where: is_nil(c.used_at)))

      with %RecoveryCode{} = found <-
             Enum.find(unused, &Security.equal?(Security.hash(&1.salt <> code), &1.code_hash)),
           # Spent only if still unspent: two racing presentations cannot both pass.
           {1, _} <- spend(found) do
        left = length(unused) - 1
        Audit.record(:recovery_code_used, %{left: left}, ctx(meta, session))
        Accounts.notify(session.account_id, :recovery_code_used, %{left: left})
        {:ok, Accounts.mark_mfa(session)}
      else
        _ ->
          Audit.record(:recovery_failed, %{}, ctx(meta, session))
          {:error, :code}
      end
    end
  end

  defp spend(%RecoveryCode{id: id}) do
    Store.write(fn ->
      Repo.update_all(from(c in RecoveryCode, where: c.id == ^id and is_nil(c.used_at)),
        set: [used_at: Store.now()],
        inc: [rev: 1]
      )
    end)
  end

  ## Changing the set

  @doc """
  Remove a factor; the session must be fresh. Removing the last live
  factor also discards the recovery codes: nothing is left to recover to.
  """
  @spec remove(Session.t(), pos_integer(), map()) :: :ok | {:error, :step_up | :not_found}
  def remove(%Session{} = session, factor_id, meta \\ %{}) do
    with :ok <- fresh(session),
         %Factor{} = factor <- Repo.get(Factor, factor_id) || {:error, :not_found} do
      Store.transaction(fn ->
        Repo.delete!(factor)
        if not enrolled?(), do: Repo.delete_all(from(c in RecoveryCode))
      end)

      about = %{kind: factor.kind, name: factor.name}
      Audit.record(:factor_removed, Map.put(about, :factor_id, factor.id), ctx(meta, session))
      Accounts.notify(session.account_id, :authenticator_removed, about)
      :ok
    end
  end

  ## Internals

  # One step of grace either side; `since` refuses every step at or before
  # the one spent. Answers the step the code matched, so that step is
  # recorded as spent: a code accepted early through the grace is not good
  # again when its own step arrives.
  defp totp_step(secret, code, now, since),
    do:
      Enum.find(
        [now, now - 30, now + 30],
        &NimbleTOTP.valid?(secret, code, time: &1, since: since)
      )

  defp unseal_totp(%Factor{totp_secret: sealed}) when is_binary(sealed) do
    case Security.unseal(sealed, @totp_seal) do
      {:ok, secret} -> secret
      :error -> <<>>
    end
  end

  defp unseal_totp(_), do: <<>>

  defp counter_advanced(%Factor{sign_count: nil} = f, new, meta, session),
    do: counter_advanced(%{f | sign_count: 0}, new, meta, session)

  defp counter_advanced(%Factor{sign_count: 0}, 0, _meta, _session), do: :ok
  defp counter_advanced(%Factor{sign_count: old}, new, _meta, _session) when new > old, do: :ok

  defp counter_advanced(%Factor{} = factor, new, meta, session) do
    update!(factor, disabled_at: Store.now())

    Audit.record(
      :factor_clone_suspected,
      %{factor_id: factor.id, stored: factor.sign_count, presented: new},
      ctx(meta, session)
    )

    Accounts.notify(factor.account_id, :authenticator_disabled, %{
      kind: :webauthn,
      name: factor.name,
      reason: :clone
    })

    {:error, :clone}
  end

  defp fresh(session), do: if(fresh?(session), do: :ok, else: {:error, :step_up})

  defp throttle(%Session{account_id: id}), do: Security.limit(:mfa_account, id)

  # Every factor that could have matched took a failure; at the limit it is disabled.
  defp failed(factors, meta, session) do
    for factor <- factors do
      failures = factor.consecutive_failures + 1
      disabled = if failures >= Security.lockout_failures(), do: Store.now()
      update!(factor, consecutive_failures: failures, disabled_at: disabled)

      if disabled do
        Audit.record(
          :factor_locked,
          %{factor_id: factor.id, kind: factor.kind},
          ctx(meta, session)
        )

        Accounts.notify(factor.account_id, :authenticator_disabled, %{
          kind: factor.kind,
          name: factor.name,
          reason: :failures
        })
      end
    end

    Audit.record(:factor_failed, %{}, ctx(meta, session))
  end

  defp proved(%Session{} = session, %Factor{} = factor, meta) do
    Audit.record(:factor_verified, %{factor_id: factor.id, kind: factor.kind}, ctx(meta, session))
    {:ok, Accounts.mark_mfa(session)}
  end

  defp bind(%Session{} = session, attrs, meta) do
    first? = not enrolled?()
    name = attrs |> Map.get(:name, "") |> Security.clip(100)

    factor =
      Store.write(fn ->
        Repo.insert!(
          struct(
            Factor,
            Map.merge(attrs, %{
              name: name,
              account_id: session.account_id,
              verified_at: Store.now()
            })
          )
        )
      end)

    Accounts.mark_mfa(session)

    Audit.record(
      :factor_added,
      %{factor_id: factor.id, kind: factor.kind, name: name},
      ctx(meta, session)
    )

    Accounts.notify(session.account_id, :authenticator_added, %{kind: factor.kind, name: name})
    {:ok, factor, if(first?, do: recovery_codes!(session, meta), else: [])}
  end

  # A credential id is global: one authenticator cannot enrol on two accounts.
  defp unused_credential(credential_id) do
    case Repo.get_by(Factor, [credential_id: credential_id], skip_account: true) do
      nil -> :ok
      %Factor{} -> {:error, :duplicate}
    end
  end

  defp challenge!(%Session{} = session, kind, term) do
    Store.transaction(fn ->
      Repo.delete_all(
        from(c in Challenge, where: c.session_id == ^session.id and c.kind == ^kind)
      )

      Repo.insert!(%Challenge{
        account_id: session.account_id,
        session_id: session.id,
        kind: kind,
        payload: Security.seal(term, @challenge_seal),
        expires_at: DateTime.add(Store.now(), Security.challenge_ttl())
      })
    end)
  end

  # A challenge answers once, and only before it expires: it is deleted by
  # the statement that finds it, so two racing answers cannot both take it.
  defp take_challenge(%Session{} = session, kind) do
    query =
      from(c in Challenge,
        where: c.session_id == ^session.id and c.kind == ^kind,
        order_by: [desc: c.id],
        limit: 1
      )

    with %Challenge{} = challenge <- Repo.one(query),
         {1, _} <-
           Store.write(fn ->
             Repo.delete_all(from(c in Challenge, where: c.id == ^challenge.id))
           end),
         :lt <- DateTime.compare(Store.now(), challenge.expires_at),
         {:ok, term} <- Security.unseal(challenge.payload, @challenge_seal) do
      {:ok, term}
    else
      _ -> {:error, :challenge}
    end
  end

  defp update!(row, changes) do
    row
    |> Ecto.Changeset.change([{:rev, row.rev + 1} | changes])
    |> then(&Store.write(fn -> Repo.update!(&1) end))
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

  defp ctx(meta, %Session{} = s),
    do: meta |> Map.put(:account_id, s.account_id) |> Map.put(:session_id, s.id)
end
