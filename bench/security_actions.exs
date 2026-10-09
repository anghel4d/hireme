# Run a release eval against a DISPOSABLE copy of the canonical fixture, on CPUs 8-11
# with ELIXIR_ERL_OPTIONS="+S 2:2". BENCH_DIR, BENCH_OUTPUT and BENCH_REV are required;
# BENCH_N defaults to 1000; BENCH_ONLY is an optional interaction substring.
# Each operation commits normally. Preparation, validation and cascading disposal
# are untimed; every sample gets a fresh account (including an email identity).
# Swoosh.Adapters.Test is a synthetic sink: provider transport latency is excluded.
# Identity claims are synthetic already-proven domain inputs, not OAuth exchanges.
# Physical WebAuthn, external OAuth, HTTP/browser overhead and SMTP are NOT measured.
defmodule HiremeBench.SecurityActions do
  import Ecto.Query
  alias Hireme.{Accounts, ApiKeys, Audit, Mfa, Repo, Security}
  alias Hireme.Accounts.{Identity, MagicLink, Session}
  alias Hireme.Mfa.{Challenge, Method, RecoveryCode}

  def run do
    dir = Path.expand(System.fetch_env!("BENCH_DIR"))
    database = Application.fetch_env!(:hireme, Repo) |> Keyword.fetch!(:database) |> Path.expand()
    ensure(String.starts_with?(database, dir <> "/"), "database outside BENCH_DIR")
    ensure(dir != "/tmp/hireme-perf-canonical", "canonical fixture is read only")
    ensure(File.lstat!(database).type == :regular, "database must be a regular copied file")
    ensure(File.lstat!(dir).type == :directory, "BENCH_DIR must not be a symlink")
    metadata = dir |> Path.join("testbed.json") |> File.read!() |> Jason.decode!()
    Logger.configure(level: :warning)
    endpoint = Application.fetch_env!(:hireme, HiremeWeb.Endpoint)
    Application.put_env(:hireme, HiremeWeb.Endpoint, Keyword.put(endpoint, :server, false))
    Application.put_env(:hireme, Hireme.Mailer, adapter: Swoosh.Adapters.Test)
    Application.put_env(:swoosh, :shared_test_process, self())
    {:ok, _} = Application.ensure_all_started(:hireme)
    ensure(:erlang.system_info(:schedulers_online) == 2, "use +S 2:2")
    original = Repo.account_id()
    ensure(Accounts.get(metadata["account_id"]) != nil, "fixture account missing")
    n = System.get_env("BENCH_N", "1000") |> String.to_integer()
    ensure(n > 0, "BENCH_N must be positive")

    try do
      for {page, action} <- [
            {"Domain/ApiKeys", :api_key_create},
            {"Domain/ApiKeys", :api_key_revoke},
            {"Domain/Accounts", :session_create},
            {"Domain/Accounts", :session_revoke},
            {"Domain/Mfa", :totp_begin_enrollment_qr},
            {"Domain/Mfa", :totp_confirm_first_factor},
            {"Domain/Mfa", :totp_step_up},
            {"Domain/Mfa", :recovery_verify},
            {"Domain/Mfa", :recovery_reissue},
            {"Domain/Mfa", :remove_last_factor_and_recovery},
            {"Domain/Accounts", :identity_link_synthetic_claim},
            {"Domain/Accounts", :identity_unlink},
            {"Domain/Accounts", :magic_link_request_test_sink},
            {"Domain/Accounts", :magic_link_redeem}
          ],
          selected?(page, action) do
        Process.put(:bench_action, action)
        measure(page, action, n)
      end
    after
      Repo.put_account(original)
    end
  end

  defp selected?(page, action) do
    only = System.get_env("BENCH_ONLY", "")
    only == "" or String.contains?(page <> "/" <> Atom.to_string(action), only)
  end

  defp prepare(action) do
    previous = Repo.account_id()
    account = Accounts.create!(%{name: "Disposable security action benchmark"})
    Repo.put_account(account.id)
    # SQLite AUTOINCREMENT preserves distinct throttle keys after disposal.
    email = "security-#{account.id}@bench.invalid"
    ok_value(Accounts.link(:email, %{subject: email, display: "Synthetic mailbox"}))
    {token, session} = Accounts.start_session(account)

    fixture = %{
      account: account,
      session: session,
      token: token,
      email: email,
      previous: previous
    }

    try do
      drain_mail()
      fixture = prepare_action(action, fixture)
      Repo.delete_all(Audit.Event)
      drain_mail()
      fixture
    rescue
      error ->
        dispose(fixture)
        reraise error, __STACKTRACE__
    end
  end

  defp prepare_action(:api_key_revoke, f),
    do: Map.put(f, :created, ok_value(ApiKeys.create("Synthetic action key")))

  defp prepare_action(:totp_confirm_first_factor, f) do
    enrollment = Mfa.begin_totp(f.session, f.email)
    secret = Base.decode32!(enrollment.secret, padding: false)
    Map.put(f, :code, NimbleTOTP.verification_code(secret))
  end

  defp prepare_action(action, f)
       when action in [
              :totp_step_up,
              :recovery_verify,
              :recovery_reissue,
              :remove_last_factor_and_recovery
            ] do
    enrollment = Mfa.begin_totp(f.session, f.email)
    secret = Base.decode32!(enrollment.secret, padding: false)

    {method, codes} =
      confirmed(Mfa.confirm_totp(f.session, NimbleTOTP.verification_code(secret), "Phone"))

    ensure(length(codes) == 10, "fixture recovery generation failed")
    {token, pending} = Accounts.start_session(f.account)

    Map.merge(f, %{
      method: method,
      codes: codes,
      session: pending,
      token: token,
      enrolled_session: Repo.reload!(f.session),
      # The current enrollment step is spent. Use the real next-step code through
      # the production grace window, as in mfa_test.exs; no replay/limiter reset.
      code: NimbleTOTP.verification_code(secret, time: method.totp_last_used + 30)
    })
  end

  defp prepare_action(:identity_unlink, f),
    do: Map.put(f, :identity, ok_value(Accounts.link(:github, claim(f))))

  defp prepare_action(:magic_link_redeem, f) do
    ensure(
      Accounts.request_link(f.email, &link_url/1, meta(f)) == :ok,
      "fixture link request failed"
    )

    Map.put(f, :link_token, mailed_token(f.email))
  end

  defp prepare_action(_, f), do: f
  defp claim(f), do: %{subject: "bench-#{f.account.id}", display: "Synthetic proven claim"}

  defp meta(f),
    do: %{ip: "synthetic-peer-#{f.account.id}", user_agent: "security action benchmark"}

  defp link_url(token), do: "https://bench.invalid/sign-in/email?token=" <> token

  defp operation(:api_key_create, _f), do: ApiKeys.create("Synthetic action key")
  defp operation(:api_key_revoke, f), do: ApiKeys.revoke(f.created.key)
  defp operation(:session_create, f), do: Accounts.start_session(f.account)
  defp operation(:session_revoke, f), do: Accounts.revoke_session(f.session)
  defp operation(:totp_begin_enrollment_qr, f), do: Mfa.begin_totp(f.session, f.email)
  defp operation(:totp_confirm_first_factor, f), do: Mfa.confirm_totp(f.session, f.code, "Phone")
  defp operation(:totp_step_up, f), do: Mfa.verify_totp(f.session, f.code)
  defp operation(:recovery_verify, f), do: Mfa.verify_recovery(f.session, hd(f.codes))
  defp operation(:recovery_reissue, _f), do: Mfa.recovery_codes!()

  defp operation(:remove_last_factor_and_recovery, f),
    do: Mfa.remove(f.enrolled_session, f.method)

  defp operation(:identity_link_synthetic_claim, f), do: Accounts.link(:github, claim(f))
  defp operation(:identity_unlink, f), do: Accounts.unlink(f.identity.id)

  defp operation(:magic_link_request_test_sink, f),
    do: Accounts.request_link(f.email, &link_url/1, meta(f))

  defp operation(:magic_link_redeem, f), do: Accounts.redeem_link(f.link_token, meta(f))

  defp validate(:api_key_create, f, result) do
    created = ok_value(result)
    ensure(ApiKeys.get(created.key.id) != nil, "key not committed")
    ensure(Accounts.get(f.account.id).live_key_count == 1, "live key count incorrect")

    ensure(
      ok_value(ApiKeys.authenticate(created.secret, "validation-#{f.account.id}")).id ==
        created.key.id,
      "new key did not authenticate"
    )

    audit(["api_key_created", "notified"])
    notice(f)
    # Revoke outside create timing, before cascading disposal: never accumulate live keys.
    ApiKeys.revoke(created.key)

    ensure(
      Accounts.get(f.account.id).live_key_count == 0,
      "create cleanup did not release key cap"
    )
  end

  defp validate(:api_key_revoke, f, result) do
    ensure(result.id == f.created.key.id and result.revoked_at != nil, "revoke result invalid")
    ensure(ApiKeys.get(result.id).revoked_at != nil, "revoke not committed")
    ensure(Accounts.get(f.account.id).live_key_count == 0, "key count not released")

    ensure(
      ApiKeys.authenticate(f.created.secret, "validation-#{f.account.id}") == :error,
      "revoked key accepted"
    )

    audit(["api_key_revoked", "notified"])
    notice(f)
  end

  defp validate(:session_create, f, result) do
    case result do
      {token, %Session{} = session} ->
        ensure(session.account_id == f.account.id, "wrong session owner")
        ensure(Repo.get!(Session, session.id).revoked_at == nil, "session not committed")
        ensure(valid_session?(token, session.id), "new session unusable")

      _ ->
        raise "session creation failed"
    end

    audit(["session_started"])
  end

  defp validate(:session_revoke, f, result) do
    ensure(result.id == f.session.id and result.revoked_at != nil, "session revoke failed")
    ensure(Repo.reload!(f.session).revoked_at != nil, "session revocation not committed")
    ensure(Accounts.session(f.token) == nil, "revoked session accepted")
    audit(["session_revoked"])
  end

  defp validate(:totp_begin_enrollment_qr, f, result) do
    ensure(String.starts_with?(result.uri, "otpauth://totp/"), "missing enrollment URI")
    ensure(String.contains?(result.svg, "<svg"), "missing enrollment QR")
    challenge = Repo.get_by!(Challenge, session_id: f.session.id, kind: :totp_enroll)
    secret = ok_value(Security.unseal(challenge.payload, "hireme mfa challenge"))

    ensure(
      secret == Base.decode32!(result.secret, padding: false),
      "challenge secret not committed"
    )

    audit([])
  end

  defp validate(:totp_confirm_first_factor, f, result) do
    {method, codes} = confirmed(result)
    ensure(Repo.get!(Method, method.id).verified_at != nil, "factor not committed")
    ensure(Repo.get_by(Challenge, session_id: f.session.id) == nil, "challenge not consumed")
    validate_codes(codes)
    ensure(Mfa.recovery_codes_left() == 10, "first factor recovery codes missing")
    ensure(Repo.reload!(f.session).mfa_at != nil, "enrollment proof not committed")

    ensure(
      Mfa.verify_totp(f.session, f.code) == {:error, :code},
      "enrollment code replay accepted"
    )

    audit(["mfa_method_added", "notified", "recovery_codes_issued", "mfa_failed"])
    notice(f)
  end

  defp validate(:totp_step_up, f, result) do
    proven = ok_value(result)
    ensure(proven.id == f.session.id and proven.mfa_at != nil, "step-up did not prove session")
    ensure(Repo.reload!(f.session).mfa_at != nil and Mfa.fresh?(proven), "step-up not committed")
    method = Repo.reload!(f.method)

    ensure(
      method.totp_last_used > f.method.totp_last_used and method.last_used_at != nil,
      "TOTP not consumed"
    )

    audit(["mfa_verified"])
    ensure(Mfa.verify_totp(proven, f.code) == {:error, :code}, "TOTP replay accepted")
  end

  defp validate(:recovery_verify, f, result) do
    proven = ok_value(result)
    ensure(proven.id == f.session.id and proven.mfa_at != nil, "recovery did not prove session")

    ensure(
      Repo.reload!(f.session).mfa_at != nil and Mfa.recovery_codes_left() == 9,
      "recovery proof not committed"
    )

    ensure(
      Repo.aggregate(from(c in RecoveryCode, where: not is_nil(c.used_at)), :count) == 1,
      "recovery not spent"
    )

    audit(["recovery_code_used", "notified"])
    notice(f)

    ensure(
      Mfa.verify_recovery(proven, hd(f.codes)) == {:error, :code},
      "recovery replay accepted"
    )
  end

  defp validate(:recovery_reissue, f, codes) do
    validate_codes(codes)

    ensure(
      Mfa.recovery_codes_left() == 10 and Repo.aggregate(RecoveryCode, :count) == 10,
      "reissue cardinality incorrect"
    )

    ensure(MapSet.disjoint?(MapSet.new(codes), MapSet.new(f.codes)), "reissue reused old codes")
    audit(["recovery_codes_issued"])

    ensure(
      Mfa.verify_recovery(f.session, hd(f.codes)) == {:error, :code},
      "replaced recovery code accepted"
    )

    ensure(
      match?({:ok, %Session{}}, Mfa.verify_recovery(f.session, hd(codes))),
      "replacement code unusable"
    )
  end

  defp validate(:remove_last_factor_and_recovery, f, result) do
    ensure(result == :ok, "factor removal rejected")

    ensure(
      Repo.get(Method, f.method.id) == nil and Mfa.methods() == [],
      "factor removal not committed"
    )

    ensure(Repo.aggregate(RecoveryCode, :count) == 0, "recovery codes not removed")
    audit(["mfa_method_removed", "notified"])
    notice(f)
  end

  defp validate(:identity_link_synthetic_claim, f, result) do
    identity = ok_value(result)
    ensure(identity.provider == :github and identity.verified_at != nil, "identity proof missing")
    ensure(Repo.get!(Identity, identity.id).account_id == f.account.id, "identity not committed")
    ensure(length(Accounts.identities()) == 2, "identity link did not add one identity")
    audit(["identity_linked", "notified"])
    notice(f)
  end

  defp validate(:identity_unlink, f, result) do
    ensure(result == :ok, "identity unlink rejected")

    ensure(
      Repo.get(Identity, f.identity.id) == nil and length(Accounts.identities()) == 1,
      "identity unlink not committed"
    )

    audit(["identity_unlinked", "notified"])
    notice(f)
  end

  defp validate(:magic_link_request_test_sink, f, result) do
    ensure(result == :ok, "magic link request rejected")
    token = mailed_token(f.email)
    ensure(Accounts.peek_link(token) == {:ok, f.email}, "mailed magic link unusable")

    ensure(
      Repo.get_by!(MagicLink, [email: f.email], skip_account: true).used_at == nil,
      "magic link not committed"
    )

    audit(["link_requested"])
  end

  defp validate(:magic_link_redeem, f, result) do
    ensure(result == {:ok, f.email}, "magic link redemption rejected")

    ensure(
      Repo.get_by!(MagicLink, [email: f.email], skip_account: true).used_at != nil,
      "link consumption not committed"
    )

    audit(["link_redeemed"])
    ensure(Accounts.peek_link(f.link_token) == {:error, :invalid}, "redeemed link remains live")

    ensure(
      Accounts.redeem_link(f.link_token, meta(f)) == {:error, :invalid},
      "magic link replay accepted"
    )
  end

  defp validate_codes(codes) do
    ensure(
      is_list(codes) and length(codes) == 10 and length(Enum.uniq(codes)) == 10,
      "invalid recovery code count"
    )

    ensure(
      Enum.all?(codes, &Regex.match?(~r/\A[a-z2-9]{4}(-[a-z2-9]{4}){3}\z/, &1)),
      "invalid recovery code shape"
    )
  end

  defp audit(expected) do
    actual = Audit.recent() |> Enum.map(& &1.kind) |> Enum.sort()
    ensure(actual == Enum.sort(expected), "unexpected durable audit events")
  end

  defp notice(f) do
    receive do
      {:email, %Swoosh.Email{to: recipients}} ->
        ensure(
          Enum.any?(recipients, fn {_, address} -> address == f.email end),
          "wrong notice recipient"
        )
    after
      1000 -> raise "missing synthetic mail notice"
    end
  end

  defp mailed_token(email) do
    receive do
      {:email, %Swoosh.Email{to: recipients, text_body: body}} ->
        ensure(
          Enum.any?(recipients, fn {_, address} -> address == email end),
          "wrong magic link recipient"
        )

        case Regex.run(~r{https://bench.invalid/sign-in/email\?token=([A-Za-z0-9_-]+)}, body) do
          [_, token] -> token
          _ -> raise "test sink missing magic link"
        end
    after
      1000 -> raise "test sink did not receive magic link"
    end
  end

  defp valid_session?(token, id) do
    case Accounts.session(token) do
      {%Session{id: ^id}, _} -> true
      _ -> false
    end
  end

  defp ok_value({:ok, value}), do: value
  defp ok_value(_), do: raise("operation did not return success")
  defp confirmed({:ok, %Method{} = method, codes}) when is_list(codes), do: {method, codes}
  defp confirmed(_), do: raise("TOTP confirmation failed")
  defp ensure(true, _), do: :ok
  defp ensure(_, message), do: raise(message)

  defp drain_mail do
    receive do
      {:email, _} -> drain_mail()
      {:emails, _} -> drain_mail()
    after
      0 -> :ok
    end
  end

  defp dispose(f) do
    try do
      Repo.delete_all(from(l in MagicLink, where: l.email == ^f.email), skip_account: true)
      Repo.delete!(f.account, skip_account: true)
      drain_mail()
    after
      Repo.put_account(f.previous)
    end
  end

  defp sample(action, count_queries?) do
    f = prepare(action)

    try do
      {result, measurement} =
        if count_queries? do
          counter = :atomics.new(1, [])
          handler = {__MODULE__, make_ref()}
          :ok = :telemetry.attach(handler, [:hireme, :repo, :query], &__MODULE__.query/4, counter)

          try do
            result = operation(action, f)
            {result, :atomics.get(counter, 1)}
          after
            :telemetry.detach(handler)
          end
        else
          started = System.monotonic_time()
          result = operation(action, f)
          elapsed = System.monotonic_time() - started
          {result, System.convert_time_unit(elapsed, :native, :nanosecond) / 1_000_000}
        end

      validate(action, f, result)
      measurement
    after
      dispose(f)
    end
  end

  # The atomic is shared by ALL processes emitting this Repo event, including
  # Ecto async preload workers. Validation/preparation/disposal are detached.
  def query(_event, _measurements, _metadata, counter), do: :atomics.add(counter, 1, 1)

  defp measure(page, action, n) do
    for _ <- 1..20, do: sample(action, false)
    :erlang.garbage_collect()
    samples = for _ <- 1..n, do: sample(action, false)
    queries = sample(action, true)
    sorted = Enum.sort(samples)
    percentile = fn p -> Enum.at(sorted, max(0, ceil(length(samples) * p) - 1)) end

    row = %{
      page: page,
      interaction: Atom.to_string(action),
      rev: System.fetch_env!("BENCH_REV"),
      n: length(samples),
      mean: Enum.sum(samples) / length(samples),
      p0_1: percentile.(0.001),
      p1: percentile.(0.01),
      p50: percentile.(0.5),
      p99: percentile.(0.99),
      p99_9: percentile.(0.999),
      samples: samples,
      layer: "domain",
      queries: queries,
      query_scope: "all_repo_processes_operation_only_separate_untimed_run",
      schedulers: :erlang.system_info(:schedulers_online),
      warmup: 20,
      fixture: "fresh_account_one_email_identity_per_sample_committed_then_deleted",
      mailer: "Swoosh.Adapters.Test synthetic sink; provider transport latency excluded",
      limits: "No physical WebAuthn, external OAuth/SMTP or HTTP/browser transport"
    }

    File.write!(System.fetch_env!("BENCH_OUTPUT"), Jason.encode!(row) <> "\n", [:append])
    IO.puts(Jason.encode!(Map.delete(row, :samples)))
  end
end

# Suppress exception payloads: a failed match in a dependency might contain a
# token, TOTP secret or recovery code. Only the action and exception type escape.
try do
  HiremeBench.SecurityActions.run()
rescue
  error ->
    IO.puts(
      :stderr,
      "security action benchmark failed: #{Process.get(:bench_action, :startup)} (#{inspect(error.__struct__)})"
    )

    System.halt(1)
end
