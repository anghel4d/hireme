defmodule HiremeWeb.Account do
  @moduledoc """
  The account lens's methods: `account.*` RPC over the wire session.

  Every answer is a projection built here, never a raw system row: no
  hash, no sealed secret, no credential bytes leaves this module. Only a
  browser session may call these; a key is refused `scope` (a key never
  mints keys, and `system` is in no mask).

  Sensitive changes need a session that stepped up within the window
  (`Hireme.Mfa.fresh?/1`); such a call is refused `step_up` and the lens
  steps up with `account.step_up.*` and retries. The rules for what
  needs it live with the owner of each change (`Hireme.Keys`,
  `Hireme.Mfa`); this module adds it only where no owner holds it
  (unlinking a way in, trusted hosts, resuming a paused key).

  Methods (params -> result):

  - `account.rename` {name}
  - `account.session.revoke` {id}; `account.session.revoke_others` {}
  - `account.key.mint` {name, preset | read_mask + write_mask, may_delete?, expires_in_days?} -> {key, secret}
  - `account.key.change` {id, preset | read_mask + write_mask, may_delete?}
  - `account.key.rename` {id, name}; `account.key.revoke` {id}
  - `account.key.resume` {id} -> {key}: lifts the pause an operator lease
    revoke put on the key (needs a step-up); not_found for an unknown or
    revoked key
  - `account.lease.revoke` {id}
  - `account.identity.unlink` {id}
  - `account.totp.begin` {label} -> {uri, secret, svg}; `account.totp.confirm` {code, name} -> {factor, recovery_codes}
  - `account.passkey.begin` {name} -> {publicKey}; `account.passkey.finish` {name, attestationObject, clientDataJSON, transports} -> {factor, recovery_codes}
  - `account.factor.remove` {id}; `account.recovery.regenerate` {} -> {recovery_codes}
  - `account.step_up.passkey_options` {} -> {publicKey}; `account.step_up.passkey` {assertion fields}; `account.step_up.totp` {code}; `account.step_up.recovery` {code}
  - `account.step_up.mail` {} mails a code; `account.step_up.mail_code` {code}: an account with no factor
  - `account.trusted_host.add` {host, note?}; `account.trusted_host.remove` {id}
  - `account.mail.link` {address, app_password} -> {status} (needs a
    step-up; the password goes no further than `Hireme.Gmail`);
    `account.mail.unlink` {}; `account.mail.pipe` {} -> {pipe_id, secret},
    the domain pipe's id and a new secret, shown this once (needs a step-up)

  An error answers `%{error: code}` with the code a string: `scope`,
  `step_up`, `not_found`, `invalid`, `limit`, `rate_limited`, `last`,
  `taken`, `challenge`, `code`, `attestation`, `assertion`, `duplicate`,
  `clone`, `revoked`, `no_factor`, `factor`, `no_email`, `unknown_method`,
  and the Gmail link's `address`, `auth`, `imap_disabled`,
  `all_mail_hidden`, `unreachable`, `no_mailbox`.
  """

  require Logger
  alias Hireme.Accounts
  alias Hireme.Audit
  alias Hireme.Keys
  alias Hireme.Mfa
  alias Hireme.Repo
  alias Hireme.Rows.Session

  @type ctx :: %{
          required(:account_id) => pos_integer(),
          required(:session_id) => pos_integer() | nil,
          optional(:key) => map() | nil,
          optional(:ip) => String.t(),
          optional(:user_agent) => String.t()
        }

  @doc "Run one method for the browser session in `ctx`."
  @spec call(String.t(), map(), ctx()) :: {:ok, map()} | {:error, map()}
  def call(method, params, ctx) when is_binary(method) and is_map(params) do
    guarded(method, fn -> checked(method, params, ctx) end)
  end

  # The browser session's own lifetime, idle limit, revocation and the
  # account's suspension hold here exactly as for a page.
  defp checked(method, params, ctx) do
    with nil <- ctx[:key],
         true <- ids?(params) || :invalid,
         id when is_integer(id) <- ctx[:session_id],
         {:ok, %Session{account_id: account_id} = session} <- Accounts.live_session(id),
         true <- account_id == ctx.account_id do
      Repo.with_account(account_id, fn -> safely(method, params, session, ctx) end)
    else
      :error -> {:error, %{error: "session"}}
      :invalid -> {:error, %{error: "invalid"}}
      _ -> {:error, %{error: "scope"}}
    end
  end

  # Every id a call names is a row id: a positive 64-bit integer.
  defp ids?(%{"id" => n}) when is_integer(n), do: n >= 0 and n < 0x8000000000000000
  defp ids?(_params), do: true

  # The methods that write the trail or mail a notice, under one budget per
  # account (renames have their own); reads, ceremonies begun and step-up
  # (throttled as factor attempts) are not.
  #
  # Revocations are outside it: they are bounded by what exists and record
  # only a real change, and the owner must always be able to revoke a
  # leaked key or a thief's session. A call that wrote nothing (refused, or
  # a no-op) is given its charge back, so a stale cookie cannot spend the
  # owner's budget.
  @writes ~w(account.key.mint account.key.change account.key.resume account.identity.unlink
    account.totp.confirm account.passkey.finish account.factor.remove
    account.recovery.regenerate account.trusted_host.add account.trusted_host.remove
    account.mail.link account.mail.unlink account.mail.pipe)

  defp safely(method, params, %Session{account_id: id} = session, ctx)
       when method in @writes do
    # Charged up front, atomically, so parallel calls cannot all pass; given
    # back unless this very call recorded an event (what the account does
    # elsewhere meanwhile never counts against it).
    case Hireme.Security.limit(:account_writes, id) do
      {:error, :rate_limited} ->
        {:error, %{error: "rate_limited"}}

      :ok ->
        Audit.recorded?(:reset)

        try do
          method |> run(params, session, Map.take(ctx, [:ip, :user_agent])) |> answer()
        after
          # A call that raised wrote nothing either.
          unless Audit.recorded?(:check), do: Hireme.Security.refund(:account_writes, id)
        end
    end
  end

  defp safely(method, params, session, ctx),
    do: method |> run(params, session, Map.take(ctx, [:ip, :user_agent])) |> answer()

  # Whatever raises in a call (a malformed param, the database) answers
  # `invalid` and the wire session lives on. Logged with the stack only:
  # the params may carry codes, names or a key's secret, and the context
  # the session.
  defp guarded(method, fun) do
    fun.()
  rescue
    e ->
      Logger.error("account.* #{method} raised " <> Hireme.Security.trace(e, __STACKTRACE__))

      {:error, %{error: "invalid"}}
  end

  defp answer({:ok, %{} = result}), do: {:ok, result}
  defp answer(:ok), do: {:ok, %{ok: true}}

  defp answer({:error, reason}) when is_atom(reason),
    do: {:error, %{error: Atom.to_string(reason)}}

  defp answer({:error, %{error: code} = error}) when is_binary(code) and not is_struct(error),
    do: {:error, error}

  defp answer(_), do: {:error, %{error: "invalid"}}

  ## The account and its sessions

  defp run("account.rename", %{"name" => name}, s, meta) when is_binary(name) do
    name = String.trim(name)
    account = Accounts.get(s.account_id)

    cond do
      not Hireme.Security.name?(name, 200, 400) ->
        {:error, :invalid}

      name == account.name ->
        :ok

      Hireme.Security.limit(:renames, s.account_id) != :ok ->
        {:error, :rate_limited}

      true ->
        Hireme.Store.update!(account, [name: name], skip_account: true)
        Audit.record(:account_renamed, %{}, ctx(meta, s))
        :ok
    end
  end

  defp run("account.session.revoke", %{"id" => id}, s, meta) when is_integer(id),
    do: Accounts.revoke_session(s.account_id, id, ctx(meta, s))

  defp run("account.session.revoke_others", _, s, meta),
    do: {:ok, %{revoked: Accounts.revoke_other_sessions(s, ctx(meta, s))}}

  ## Keys

  defp run("account.key.mint", p, s, meta) do
    with {:ok, masks} <- masks(p),
         {:ok, days} <- days(p["expires_in_days"]),
         {:ok, %{key: key, secret: secret}} <-
           Keys.mint(s, text(p["name"]), masks, days, ctx(meta, s)) do
      {:ok, %{key: key(key), secret: secret}}
    end
  end

  defp run("account.key.change", %{"id" => id} = p, s, meta) when is_integer(id) do
    with %{} = key <- Keys.get(id) || {:error, :not_found},
         {:ok, masks} <- masks(p),
         {:ok, key} <- Keys.change(s, key, masks, ctx(meta, s)) do
      {:ok, %{key: key(key)}}
    end
  end

  defp run("account.key.rename", %{"id" => id, "name" => name}, s, meta)
       when is_integer(id) and is_binary(name) do
    with %{} = key <- Keys.get(id) || {:error, :not_found},
         {:ok, key} <- Keys.rename(key, name, ctx(meta, s)) do
      {:ok, %{key: key(key)}}
    end
  end

  # An operator lease revoke paused the key; this lifts it.
  defp run("account.key.resume", %{"id" => id}, s, meta) when is_integer(id) do
    with true <- Mfa.fresh?(s) || {:error, :step_up},
         %{} = key <- Keys.get(id) || {:error, :not_found},
         {:ok, key} <- Keys.resume(key, ctx(meta, s)) do
      {:ok, %{key: key(key)}}
    end
  end

  defp run("account.key.revoke", %{"id" => id}, s, meta) when is_integer(id) do
    with %{} = key <- Keys.get(id) || {:error, :not_found},
         do: {:ok, %{key: key(Keys.revoke(key, ctx(meta, s)))}}
  end

  ## Leases

  defp run("account.lease.revoke", %{"id" => id}, s, meta),
    do: Hireme.Lease.revoke(s.account_id, id, ctx(meta, s))

  ## Ways in

  defp run("account.identity.unlink", %{"id" => id}, s, meta) when is_integer(id) do
    if Mfa.fresh?(s), do: Accounts.unlink(id, ctx(meta, s)), else: {:error, :step_up}
  end

  ## Factors

  defp run("account.totp.begin", p, s, _meta), do: Mfa.begin_totp(s, label(p["label"], s))

  defp run("account.totp.confirm", %{"code" => code} = p, s, meta) when is_binary(code) do
    with {:ok, factor, codes} <-
           Mfa.confirm_totp(s, code, text(p["name"]), ctx(meta, s)),
         do: {:ok, %{factor: factor(factor), recovery_codes: codes}}
  end

  defp run("account.passkey.begin", p, s, _meta), do: Mfa.begin_webauthn(s, label(p["name"], s))

  defp run("account.passkey.finish", p, s, meta) do
    with {:ok, factor, codes} <- Mfa.confirm_webauthn(s, p, ctx(meta, s)),
         do: {:ok, %{factor: factor(factor), recovery_codes: codes}}
  end

  defp run("account.factor.remove", %{"id" => id}, s, meta) when is_integer(id),
    do: Mfa.remove(s, id, ctx(meta, s))

  defp run("account.recovery.regenerate", _, s, meta) do
    with {:ok, codes} <- Mfa.regenerate_recovery_codes(s, ctx(meta, s)),
         do: {:ok, %{recovery_codes: codes}}
  end

  ## Step-up: a factor presented now makes the session fresh for the window.

  defp run("account.step_up.passkey_options", _, s, _), do: Mfa.begin_assertion(s)

  defp run("account.step_up.passkey", p, s, meta),
    do: stepped(Mfa.verify_assertion(s, p, ctx(meta, s)))

  defp run("account.step_up.totp", %{"code" => c}, s, meta) when is_binary(c),
    do: stepped(Mfa.verify_totp(s, c, ctx(meta, s)))

  defp run("account.step_up.recovery", %{"code" => c}, s, meta) when is_binary(c),
    do: stepped(Mfa.verify_recovery(s, c, ctx(meta, s)))

  defp run("account.step_up.mail", _, s, meta), do: Mfa.mail_code(s, ctx(meta, s))

  defp run("account.step_up.mail_code", %{"code" => c}, s, meta) when is_binary(c),
    do: stepped(Mfa.verify_mail_code(s, c, ctx(meta, s)))

  ## Trusted hosts: operator-owned, browser plus step-up, in no key's mask.

  defp run("account.trusted_host.add", %{"host" => host} = p, s, meta) when is_binary(host) do
    note = text(p["note"])

    cond do
      not Mfa.fresh?(s) ->
        {:error, :step_up}

      # A note, when there is one, is bounded like a name (500 bytes).
      note != "" and not Hireme.Security.name?(note, 500, 500) ->
        {:error, :invalid}

      # Trusting a host already trusted with the same note changes nothing
      # and records nothing.
      same = trusted(host, note) ->
        host_answer({:ok, same})

      true ->
        Hireme.Provenance.trust(host, note, ctx(meta, s)) |> host_answer()
    end
  end

  defp run("account.trusted_host.remove", %{"id" => id}, s, meta) when is_integer(id) do
    if Mfa.fresh?(s), do: Hireme.Provenance.distrust(id, ctx(meta, s)), else: {:error, :step_up}
  end

  ## The Gmail link: browser plus step-up to hand over the app password or
  ## mint the pipe's secret; unlinking only takes access away.

  defp run("account.mail.link", %{"address" => a, "app_password" => p}, s, _meta)
       when is_binary(a) and is_binary(p) do
    if Mfa.fresh?(s), do: Hireme.Gmail.link(s.account_id, a, p), else: {:error, :step_up}
  end

  defp run("account.mail.unlink", _params, s, _meta), do: Hireme.Gmail.unlink(s.account_id)

  defp run("account.mail.pipe", _params, s, _meta) do
    if Mfa.fresh?(s), do: Hireme.Gmail.enable_pipe(s.account_id), else: {:error, :step_up}
  end

  defp run(method, _params, _s, _meta) do
    if String.starts_with?(method, "account."),
      do: {:error, :unknown_method},
      else: {:error, :invalid}
  end

  # The host as Provenance stores it, whether given bare or as a URL.
  defp trusted(host, note) do
    norm = Hireme.Provenance.host(host) || Hireme.Provenance.host("https://" <> String.trim(host))

    norm &&
      Enum.find(Hireme.Provenance.trusted_hosts(), &(&1.host == norm and (&1.note || "") == note))
  end

  defp stepped({:ok, s}), do: {:ok, %{fresh_for: fresh_for(s)}}
  defp stepped(error), do: error

  defp host_answer({:ok, row}), do: {:ok, %{trusted_host: Map.take(row, [:id, :host, :note])}}
  defp host_answer(other), do: other

  ## Projections

  @key_fields ~w(id name paused_at read_mask write_mask may_delete last_used_at expires_at
    revoked_at inserted_at)a
  @factor_fields ~w(id kind name verified_at last_used_at backup_eligible backed_up transports)a

  defp key(k) do
    Map.merge(Map.take(k, @key_fields), %{
      display: Keys.display(k),
      preset: Keys.preset_of(k),
      live: Keys.live?(k),
      paused: k.paused_at != nil
    })
  end

  defp factor(f), do: Map.take(f, @factor_fields)

  # Seconds the session's step-up still holds; 0 when it must step up again.
  defp fresh_for(%Session{} = s) do
    if Mfa.fresh?(s) do
      proof = if Mfa.enrolled?(), do: s.mfa_at, else: s.authenticated_at
      max(Hireme.Security.step_up_window() - DateTime.diff(Hireme.Store.now(), proof), 0)
    else
      0
    end
  end

  defp masks(%{"preset" => preset} = p)
       when preset in ["read_only", "write_only", "read_write"] do
    {:ok, %{Keys.preset(String.to_existing_atom(preset)) | may_delete: p["may_delete"] == true}}
  end

  defp masks(%{"read_mask" => r, "write_mask" => w} = p) when is_integer(r) and is_integer(w),
    do: {:ok, %{read_mask: r, write_mask: w, may_delete: p["may_delete"] == true}}

  defp masks(_), do: {:error, :masks}

  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""

  # Absent is never; present must be a whole number of days, 1 to 3650.
  # Anything else is refused, never read as "never expires".
  defp days(nil), do: {:ok, nil}
  defp days(n) when is_integer(n) and n in 1..3650, do: {:ok, n}
  defp days(_), do: {:error, :invalid}

  # An authenticator shows the label; at most 100 characters and 200 bytes.
  defp label(name, s) do
    name =
      if is_binary(name) and name != "",
        do: name,
        else: to_string(Accounts.get(s.account_id).name)

    if Hireme.Security.name?(name, 100, 200), do: name, else: "Hireme account"
  end

  defp ctx(meta, %Session{} = s),
    do: meta |> Map.put(:account_id, s.account_id) |> Map.put(:session_id, s.id)
end
