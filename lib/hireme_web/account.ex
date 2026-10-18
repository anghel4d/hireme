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
  (unlinking a way in, trusted hosts).

  `account.watch` parks: the session answers it when the account's topic
  announces a change, so a revoke elsewhere appears without a reload.

  Methods (params -> result):

  Any method takes `passive: true` when the client sends it by itself (the
  reload after a watch answers); such a call does not count as activity.

  - `account.overview` {} -> everything the lens draws, and `cursor`, how
    far the account's security state has moved (`Hireme.Audit.rev/1`; 0
    when never)
  - `account.watch` {since: cursor} -> {changed: true} at once if the
    account moved past the cursor of the overview the lens drew, else
    parked; {changed}
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
  - `account.trusted_host.add` {host, note?}; `account.trusted_host.remove` {id}
  - `account.audit` {view?: "security" | "activity", limit?, before?} ->
    {events, next}: a page of the trail, newest first; `next` is the
    `before` of the page after it (nil at the end)

  An error answers `%{error: code}` with the code a string: `scope`,
  `step_up`, `not_found`, `invalid`, `limit`, `rate_limited`, `last`,
  `taken`, `challenge`, `code`, `attestation`, `assertion`, `duplicate`,
  `clone`, `revoked`, `no_factor`, `unknown_method`.
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
  @spec call(String.t(), map(), ctx()) :: {:ok, map()} | {:park, :account} | {:error, map()}
  def call(method, params, ctx) when is_binary(method) and is_map(params) do
    guarded(method, fn -> checked(method, params, ctx) end)
  end

  defp checked(method, params, ctx) do
    with nil <- ctx[:key],
         true <- ids?(params) || :invalid,
         id when is_integer(id) <- ctx[:session_id],
         {:ok, %Session{account_id: account_id} = session} <- live(id, activity?(method, params)),
         true <- account_id == ctx.account_id do
      Repo.with_account(account_id, fn -> safely(method, params, session, ctx) end)
    else
      :session -> {:error, %{error: "session"}}
      :invalid -> {:error, %{error: "invalid"}}
      _ -> {:error, %{error: "scope"}}
    end
  end

  # The browser session's own lifetime, idle limit, revocation and the
  # account's suspension hold here exactly as for a page.
  defp live(id, activity?) do
    case Accounts.live_session(id, activity?) do
      {:ok, session} -> {:ok, session}
      :error -> :session
    end
  end

  # What the lens does by itself (a parked watch, the reload it triggers,
  # sent with `passive: true`) is not the operator's activity: an Account tab
  # left open must still idle out.
  defp activity?("account.watch", _), do: false
  defp activity?(_, %{"passive" => true}), do: false
  defp activity?(_, _), do: true

  # Every id a call names is a row id: a positive 64-bit integer.
  defp ids?(params) do
    Enum.all?(~w(id since before), fn k ->
      case Map.get(params, k) do
        nil -> true
        n when is_integer(n) -> n >= 0 and n < 0x8000000000000000
        _ -> k == "id"
      end
    end)
  end

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
    account.recovery.regenerate account.trusted_host.add account.trusted_host.remove)

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
  # A frame may carry its call's arguments; the log keeps only the arity.
  defp arities(stack),
    do:
      Enum.map(stack, fn
        {m, f, a, l} when is_list(a) -> {m, f, length(a), l}
        frame -> frame
      end)

  defp guarded(method, fun) do
    fun.()
  rescue
    e ->
      Logger.error(
        "account.* #{method} raised #{inspect(e.__struct__)}: " <>
          Exception.format_stacktrace(arities(__STACKTRACE__))
      )

      {:error, %{error: "invalid"}}
  end

  defp answer({:park, _} = park), do: park
  defp answer({:ok, %{} = result}), do: {:ok, result}
  defp answer(:ok), do: {:ok, %{ok: true}}

  defp answer({:error, reason}) when is_atom(reason),
    do: {:error, %{error: Atom.to_string(reason)}}

  defp answer({:error, %{error: code} = error}) when is_binary(code) and not is_struct(error),
    do: {:error, error}

  defp answer(_), do: {:error, %{error: "invalid"}}

  ## Reading

  defp run("account.overview", _, s, _), do: {:ok, overview(s)}
  # Level-triggered: a change between the last REPLY and this re-park
  # moved the cursor past the caller's, and answers at once. The check and the
  # park run in the session process, so a change after the check arrives
  # as a message after the park and wakes it.
  defp run("account.watch", %{"since" => since}, s, _) when is_integer(since) do
    if Audit.rev(s.account_id) > since, do: {:ok, %{changed: true}}, else: {:park, :account}
  end

  defp run("account.watch", _, _, _), do: {:park, :account}

  # The trail a page at a time, security events (the default) or activity,
  # newest first, `before` the last page's `next`.
  defp run("account.audit", p, _, _) do
    limit =
      p |> Map.get("limit", 50) |> then(&if(is_integer(&1), do: min(max(&1, 1), 200), else: 50))

    view = if p["view"] == "activity", do: :activity, else: :security
    events = Audit.page(view, limit, p["before"])
    next = if length(events) == limit, do: List.last(events).id

    {:ok, %{events: Enum.map(events, &event/1), next: next}}
  end

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
        account
        |> Ecto.Changeset.change(name: name, rev: account.rev + 1)
        |> then(&Hireme.Store.write(fn -> Repo.update!(&1, skip_account: true) end))

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
    case Keys.get(id) do
      nil -> {:error, :not_found}
      key -> {:ok, %{key: key(Keys.revoke(key, ctx(meta, s)))}}
    end
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

  defp overview(%Session{} = s) do
    # Read first: anything that lands while the rest is read moves the
    # account past this cursor, and the next watch answers at once.
    cursor = Audit.rev(s.account_id)
    account = Accounts.get(s.account_id)

    %{
      cursor: cursor,
      account: %{id: account.id, name: account.name, status: account.status},
      fresh_for: fresh_for(s),
      domains: Map.new(Keys.domains()),
      presets: Map.new([:read_only, :write_only, :read_write], &{&1, Keys.preset(&1)}),
      identities:
        for(i <- Accounts.identities(), do: Map.take(i, [:id, :provider, :display, :verified_at])),
      factors: Enum.map(Mfa.factors(), &factor/1),
      recovery_codes_left: Mfa.recovery_codes_left(),
      sessions:
        for(
          x <- Accounts.sessions(s.account_id),
          do:
            x
            |> Map.take([:id, :ip, :user_agent, :authenticated_at, :last_seen_at, :expires_at])
            |> Map.put(:current, x.id == s.id)
        ),
      keys: Enum.map(Keys.list(), &key/1),
      leases: Hireme.Lease.leases(s.account_id),
      trusted_hosts:
        for(h <- Hireme.Provenance.trusted_hosts(), do: Map.take(h, [:id, :host, :note])),
      limits:
        for(
          {name, {ms, max}} <- Hireme.Security.limits(),
          into: %{},
          do: {name, %{window_ms: ms, max: max}}
        )
    }
  end

  defp key(k) do
    k
    |> Map.take([
      :id,
      :name,
      :paused_at,
      :read_mask,
      :write_mask,
      :may_delete,
      :last_used_at,
      :expires_at,
      :revoked_at,
      :inserted_at
    ])
    |> Map.merge(%{
      display: Keys.display(k),
      preset: Keys.preset_of(k),
      live: Keys.live?(k),
      paused: k.paused_at != nil
    })
  end

  defp factor(f) do
    Map.take(f, [
      :id,
      :kind,
      :name,
      :verified_at,
      :last_used_at,
      :backup_eligible,
      :backed_up,
      :transports
    ])
  end

  defp event(e),
    do: Map.take(e, [:id, :kind, :ip, :user_agent, :meta, :key_id, :session_id, :inserted_at])

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
