defmodule Hireme.Accounts do
  @moduledoc """
  The account: who signs in, the sessions that prove it, and the tickets
  that carry a signed-in page onto the wire.

  An account is the thing a desk belongs to. Identities (an email
  address, a GitHub user, an X user) are ways into it and may be linked
  and unlinked; the account outlives any one of them. Sign-in methods end
  in `sign_in_with/3`; nothing else mints a session.

  A session is a row, not a cookie: the cookie carries a random token
  and the row holds its hash, so a session can be listed and revoked from
  the server (ASVS 7.2.1, 7.4.1, 7.5.2). Lifetimes are
  `Hireme.Security`'s, an overall and an idle limit (NIST SP 800-63B-4
  AAL2). `mfa_at` is the last second-factor proof on the session.

  A wire ticket is how a page that holds the cookie opens a wire session
  without the cookie reaching the carrier: minted for a live, post-factor
  session, spent by one HELLO within `Security.ticket_ttl/0`, and
  re-checked against the session row when spent.

  This module never touches desk rows; revoking a session or suspending
  the account ends its wire sessions through `Hireme.Audit.bye/2`.
  """

  import Ecto.Query
  alias Hireme.Audit
  alias Hireme.Mail
  alias Hireme.Repo
  alias Hireme.Rows.Account
  alias Hireme.Rows.Identity
  alias Hireme.Rows.MagicLink
  alias Hireme.Rows.Session
  alias Hireme.Security
  alias Hireme.Store

  @type meta :: %{optional(:ip) => String.t(), optional(:user_agent) => String.t()}

  @typedoc "What a provider vouched for: its id for the person (the address, for mail) and a name to show."
  @type claim :: %{subject: String.t(), display: String.t()}

  @providers [:email, :github, :x]
  @address ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/
  @ticket_salt "hireme wire ticket"

  ## Accounts

  @spec get(pos_integer()) :: Account.t() | nil
  def get(id) when is_integer(id), do: Repo.get(Account, id, skip_account: true)

  @spec active?(Account.t() | nil) :: boolean()
  def active?(%Account{status: :active}), do: true
  def active?(_), do: false

  @doc """
  The opaque name a browser keys its snapshot by: stable per account,
  unlinkable to the id without the server's secret.
  """
  @spec scope(pos_integer()) :: String.t()
  def scope(account_id) when is_integer(account_id) do
    key = Application.fetch_env!(:hireme, :secret_key_base)

    :crypto.mac(:hmac, :sha256, key, "scope:#{account_id}")
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  @doc "Suspend or reinstate. Suspension ends every session, key use and lease at once."
  @spec set_status(pos_integer(), :active | :suspended, meta()) :: :ok
  def set_status(account_id, status, meta \\ %{}) when status in [:active, :suspended] do
    Store.write(fn ->
      Repo.update_all(
        from(a in Account, where: a.id == ^account_id),
        [set: [status: status, updated_at: Store.now()], inc: [rev: 1]],
        skip_account: true
      )
    end)

    Audit.record(:"account_#{status}", %{}, Map.put(meta, :account_id, account_id))
    if status == :suspended, do: Audit.bye(account_id, {:account, :suspended})
    :ok
  end

  ## Sessions

  @doc """
  Open a session for `account`. Answers the token the cookie carries and
  the row; the token is not stored and cannot be recovered.
  """
  @spec start_session(Account.t(), meta()) :: {String.t(), Session.t()} | {:error, :cap}
  def start_session(%Account{} = account, meta \\ %{}) do
    token = Security.token(32)
    now = Store.now()

    case Store.transaction(fn -> room_for_session(account.id, now) || Repo.rollback(:cap) end) do
      {:ok, _} -> open_session(account, token, now, meta)
      {:error, :cap} -> {:error, :cap}
    end
  end

  # At the declared cap, the oldest ended sessions (revoked, expired, idle)
  # go to make room; only an account whose every session is live is refused.
  defp room_for_session(account_id, now) do
    cap = Hireme.Schema.table(:sessions).cap

    count =
      Repo.aggregate(from(s in Session, where: s.account_id == ^account_id), :count,
        skip_account: true
      )

    if count < cap do
      true
    else
      idle = DateTime.add(now, -Security.session_idle())

      ended =
        Repo.all(
          from(s in Session,
            where:
              s.account_id == ^account_id and
                (not is_nil(s.revoked_at) or s.expires_at <= ^now or s.last_seen_at <= ^idle),
            order_by: [asc: s.last_seen_at],
            limit: ^(count - cap + 1),
            select: s.id
          ),
          skip_account: true
        )

      if length(ended) == count - cap + 1 do
        # In batches: one IN list past SQLite's variable limit would raise.
        for ids <- Enum.chunk_every(ended, 500),
            do: Repo.delete_all(from(s in Session, where: s.id in ^ids), skip_account: true)

        true
      end
    end
  end

  defp open_session(account, token, now, meta) do
    session =
      Store.write(fn ->
        Repo.insert!(%Session{
          account_id: account.id,
          token_hash: Security.hash(token),
          authenticated_at: now,
          last_seen_at: now,
          expires_at: DateTime.add(now, Security.session_lifetime()),
          ip: text(meta[:ip], 64),
          user_agent: text(meta[:user_agent], 200),
          rev: 1
        })
      end)

    Audit.record(:session_started, %{}, context(meta, account.id, session.id))
    {Security.encode(token), session}
  end

  @doc """
  The live session a cookie token names, with its account, or nil:
  unknown, revoked, past its lifetime, idle too long, or the account is
  not active. Both rows are read together on every request, so a revoke
  or a suspension is seen at once. A live session is touched at most
  once a minute.
  """
  @spec session(term()) :: {Session.t(), Account.t()} | nil
  def session(token) do
    now = Store.now()

    with {:ok, raw} <- Security.decode(token),
         {%Session{} = session, %Account{} = account} <- by_token(Security.hash(raw)),
         true <- live?(session, now) and active?(account) do
      {touch(session, now), account}
    else
      _ -> nil
    end
  end

  defp by_token(hash) do
    Repo.one(
      from(s in Session,
        join: a in Account,
        on: a.id == s.account_id,
        where: s.token_hash == ^hash,
        select: {s, a}
      ),
      skip_account: true
    )
  end

  defp live?(%Session{} = s, now) do
    is_nil(s.revoked_at) and DateTime.compare(now, s.expires_at) == :lt and
      DateTime.diff(now, s.last_seen_at) < Security.session_idle()
  end

  defp touch(%Session{} = s, now) do
    if DateTime.diff(now, s.last_seen_at) >= 60,
      do: update!(s, last_seen_at: now),
      else: s
  end

  @doc "A second factor was just presented on this session."
  @spec mark_mfa(Session.t()) :: Session.t()
  def mark_mfa(%Session{} = s), do: update!(s, mfa_at: Store.now())

  @doc "The account's open sessions, most recently seen first."
  @spec sessions(pos_integer()) :: [Session.t()]
  def sessions(account_id) do
    now = Store.now()

    Repo.all(
      from(s in Session,
        where: s.account_id == ^account_id and is_nil(s.revoked_at) and s.expires_at > ^now,
        order_by: [desc: s.last_seen_at]
      ),
      skip_account: true
    )
    |> Enum.filter(&live?(&1, now))
  end

  @doc "Revoke one of the account's sessions (this one, or another from the account lens)."
  @spec revoke_session(pos_integer(), pos_integer(), meta()) :: :ok | {:error, :not_found}
  def revoke_session(account_id, session_id, meta \\ %{}) do
    {n, _} =
      Store.write(fn ->
        Repo.update_all(
          from(s in Session,
            where: s.id == ^session_id and s.account_id == ^account_id and is_nil(s.revoked_at)
          ),
          [set: [revoked_at: Store.now(), updated_at: Store.now()], inc: [rev: 1]],
          skip_account: true
        )
      end)

    if n == 1 do
      Audit.record(
        :session_revoked,
        %{session_id: session_id},
        Map.put(meta, :account_id, account_id)
      )

      Audit.bye(account_id, {{:session, session_id}, :revoked})
      :ok
    else
      {:error, :not_found}
    end
  end

  @doc "Sign every other browser out (ASVS 7.4.3), keeping `keep`."
  @spec revoke_other_sessions(Session.t(), meta()) :: non_neg_integer()
  def revoke_other_sessions(%Session{} = keep, meta \\ %{}) do
    ids =
      Repo.all(
        from(s in Session,
          where: s.account_id == ^keep.account_id and s.id != ^keep.id and is_nil(s.revoked_at),
          select: s.id
        ),
        skip_account: true
      )

    Enum.count(ids, &(revoke_session(keep.account_id, &1, meta) == :ok))
  end

  ## Wire tickets

  @doc "A single-use ticket that opens one wire session as this browser session."
  @spec ticket(Session.t()) :: String.t()
  def ticket(%Session{id: id, account_id: account_id, token_hash: hash}) do
    # Eight bytes of the session's own token hash: a ticket is good only for
    # the session row that minted it, not for anything the application
    # secret alone could sign.
    Phoenix.Token.encrypt(
      HiremeWeb.Endpoint,
      @ticket_salt,
      {account_id, id, binary_part(hash, 0, 8), Security.token(12)}
    )
  end

  @doc """
  Spend a ticket. It must be fresh and unspent, and the session it names
  must still be live, past its second factor, on an active account.
  """
  @spec redeem_ticket(term()) ::
          {:ok, %{account_id: pos_integer(), session_id: pos_integer()}} | :error
  def redeem_ticket(ticket) when is_binary(ticket) do
    now = Store.now()

    with {:ok, {account_id, session_id, bound, nonce}} <-
           Phoenix.Token.decrypt(HiremeWeb.Endpoint, @ticket_salt, ticket,
             max_age: Security.ticket_ttl()
           ),
         :ok <- __MODULE__.Tickets.spend(nonce),
         %Session{account_id: ^account_id} = session <-
           Repo.get(Session, session_id, skip_account: true),
         true <- Security.equal?(bound, binary_part(session.token_hash, 0, 8)),
         %Account{} = account <- get(account_id),
         true <- live?(session, now) and active?(account),
         false <- Hireme.Mfa.required?(session) do
      {:ok, %{account_id: account_id, session_id: session_id}}
    else
      _ -> :error
    end
  end

  def redeem_ticket(_), do: :error

  @doc """
  Whether browser session `session_id` may still act, counting this as its
  activity: what a page's request does, for a wire session's own requests
  (an `account.*` call, an OPS frame). A wire session thus obeys the same
  lifetime, idle limit, revocation and suspension as a page. With
  `activity?` false it only checks, for what a client does by itself.
  """
  @spec live_session(pos_integer(), boolean()) :: {:ok, Session.t()} | :error
  def live_session(session_id, activity? \\ true) when is_integer(session_id) do
    case read_live(session_id) do
      {:ok, s, now} -> {:ok, if(activity?, do: touch(s, now), else: s)}
      :error -> :error
    end
  end

  @doc """
  Whether browser session `session_id` may still act (live, active, and
  past any second factor the account now has), without counting as
  activity: for a timer (the wire's tick), which must let an abandoned tab
  idle out.
  """
  @spec session_live?(pos_integer()) :: boolean()
  def session_live?(session_id) when is_integer(session_id), do: read_live(session_id) != :error

  defp read_live(session_id) do
    now = Store.now()

    with {%Session{} = s, %Account{} = a} <-
           Repo.one(
             from(s in Session,
               join: a in Account,
               on: a.id == s.account_id,
               where: s.id == ^session_id,
               select: {s, a}
             ),
             skip_account: true
           ),
         true <- live?(s, now) and active?(a),
         # A session that owes its second factor (one was enrolled since it
         # signed in) may hold no wire, as it may mint no ticket.
         false <- Hireme.Mfa.required?(s) do
      {:ok, s, now}
    else
      _ -> :error
    end
  end

  ## Sign-in methods

  @doc """
  Mail a one-time sign-in link to `email`. `url_for` turns the token into
  the URL the mail carries, so the path stays with the router. A
  well-formed address gets `:ok` whether or not it has an account; the
  answer never says which. Five per address and twenty per peer in ten
  minutes.

  The answer does not wait on the mail provider, and the link is never
  written down: it lives only in the sending task (`Hireme.Mail.sign_in_link/2`),
  so a restart mid-send loses it and the person asks again.
  """
  @spec request_link(String.t(), (String.t() -> String.t()), meta()) ::
          :ok | {:error, :invalid | :rate_limited}
  def request_link(email, url_for, meta \\ %{}) when is_function(url_for, 1) do
    with {:ok, email} <- normalize_email(email),
         :ok <- Security.limit(:link_peer, Map.get(meta, :ip, "")),
         :ok <- Security.limit(:link_address, email),
         :ok <- Security.limit(:link_global, :all) do
      token = Security.token(32)
      now = Store.now()

      Store.write(fn ->
        Repo.insert!(%MagicLink{
          email: email,
          token_hash: Security.hash(token),
          expires_at: DateTime.add(now, Security.magic_link_ttl()),
          ip: text(meta[:ip], 64),
          user_agent: text(meta[:user_agent], 200),
          rev: 1
        })
      end)

      Audit.record(:link_requested, trace(email), meta)
      Mail.sign_in_link(email, url_for.(Security.encode(token)))
    end
  end

  @doc """
  The address a live link would prove, without spending it. Mail scanners
  open every link they see; only `redeem_link/2`, behind a deliberate
  POST, spends one.
  """
  @spec peek_link(term()) :: {:ok, String.t()} | {:error, :invalid}
  def peek_link(token) do
    case live_link(token, Store.now()) do
      %MagicLink{email: email} -> {:ok, email}
      nil -> {:error, :invalid}
    end
  end

  @doc """
  Burn a link and prove its address; nothing else. What a proven address
  means is `sign_in_with/3` for a visitor or `link/3` for an account.
  """
  @spec redeem_link(term(), meta()) :: {:ok, String.t()} | {:error, :invalid | :rate_limited}
  def redeem_link(token, meta \\ %{}) do
    now = Store.now()

    with :ok <- Security.limit(:redeem_peer, Map.get(meta, :ip, "")),
         %MagicLink{} = link <- live_link(token, now),
         {1, _} <- burn(link, now) do
      Audit.record(:link_redeemed, trace(link.email), meta)
      {:ok, link.email}
    else
      {:error, :rate_limited} -> {:error, :rate_limited}
      _ -> {:error, :invalid}
    end
  end

  # An address on the trail before anyone owns it is a stranger's: keep a
  # handle to correlate by and the domain to read, not the address.
  defp trace(email) do
    [_, domain] = String.split(email, "@", parts: 2)

    %{
      email_hash: email |> Security.hash() |> Base.encode16(case: :lower) |> binary_part(0, 16),
      domain: domain
    }
  end

  defp live_link(token, now) do
    with {:ok, raw} <- Security.decode(token),
         %MagicLink{used_at: nil} = link <-
           Repo.get_by(MagicLink, [token_hash: Security.hash(raw)], skip_account: true),
         :lt <- DateTime.compare(now, link.expires_at) do
      link
    else
      _ -> nil
    end
  end

  # Single use under concurrency: the row is taken only while still unused.
  defp burn(%MagicLink{id: id}, now) do
    Store.write(fn ->
      Repo.update_all(
        from(l in MagicLink, where: l.id == ^id and is_nil(l.used_at)),
        [set: [used_at: now, updated_at: now], inc: [rev: 1]],
        skip_account: true
      )
    end)
  end

  @doc """
  Sign in as the account a proven identity belongs to, creating both when
  they are new. Answers the cookie's token and the session.
  """
  @spec sign_in_with(:email | :github | :x, claim(), meta()) ::
          {:ok, String.t(), Session.t()} | {:error, :suspended | :cap}
  def sign_in_with(provider, %{subject: subject} = claim, meta \\ %{})
      when provider in @providers do
    identity = find_identity(provider, subject) || first_identity(provider, claim, meta)
    account = get(identity.account_id)

    if active?(account) do
      Repo.put_account(account.id)

      # The session first: an account at its session cap is refused before
      # anything says it signed in.
      case start_session(account, meta) do
        {:error, :cap} ->
          refused(provider, identity, :cap, meta)
          {:error, :cap}

        {token, session} ->
          touch_identity(identity, claim)

          Audit.record(
            :signed_in,
            %{provider: provider, identity_id: identity.id},
            Map.put(meta, :account_id, account.id)
          )

          {:ok, token, session}
      end
    else
      refused(provider, identity, :suspended, meta)
      {:error, :suspended}
    end
  end

  # A refusal anyone can cause is recorded under the refusal budget.
  defp refused(provider, identity, reason, meta) do
    if Security.limit(:refusal_peer, Map.get(meta, :ip, "")) == :ok do
      Audit.record(
        :sign_in_refused,
        %{provider: provider, identity_id: identity.id, reason: reason},
        Map.put(meta, :account_id, identity.account_id)
      )
    end
  end

  @doc """
  Whether signing in with this identity would get a session: true for an
  identity nobody has yet, false when its account is at the session cap
  with every session live. A mailed link is checked with this before it
  is spent, so a refusal keeps it good.
  """
  @spec room?(:email | :github | :x, String.t()) :: boolean()
  def room?(provider, subject) do
    case find_identity(provider, subject) do
      nil ->
        true

      %Identity{account_id: id} ->
        now = Store.now()
        idle = DateTime.add(now, -Security.session_idle())
        all = from(s in Session, where: s.account_id == ^id)

        Repo.aggregate(all, :count, skip_account: true) < Hireme.Schema.table(:sessions).cap or
          Repo.exists?(
            from(s in all,
              where: not is_nil(s.revoked_at) or s.expires_at <= ^now or s.last_seen_at <= ^idle
            ),
            skip_account: true
          )
    end
  end

  @doc "The ways into the account on this process, oldest first."
  @spec identities() :: [Identity.t()]
  def identities, do: Repo.all(from(i in Identity, order_by: i.id))

  @doc """
  Bind a proven identity to the account on this process. Binding one it
  already has is a no-op; one bound elsewhere is `:taken`. The account
  hears of it on its other channel (NIST SP 800-63B-4 Sec. 4.1.2).
  """
  @spec link(:email | :github | :x, claim(), meta()) ::
          {:ok, Identity.t()} | {:error, :taken | :cap}
  def link(provider, %{subject: subject} = claim, meta \\ %{}) when provider in @providers do
    account_id = Repo.account_id!()

    case find_identity(provider, subject) do
      %Identity{account_id: ^account_id} = identity ->
        {:ok, touch_identity(identity, claim)}

      %Identity{} ->
        {:error, :taken}

      nil ->
        if Repo.aggregate(from(i in Identity), :count) >= Hireme.Schema.table(:identities).cap,
          do: {:error, :cap},
          else: bind_identity(account_id, provider, claim, meta)
    end
  end

  defp bind_identity(account_id, provider, claim, meta) do
    case insert_identity(account_id, provider, claim) do
      {:ok, identity} ->
        about = %{provider: provider, display: identity.display, identity_id: identity.id}
        Audit.record(:identity_linked, about, meta)
        notify(account_id, :identity_linked, about)
        {:ok, identity}

      {:error, _} ->
        {:error, :taken}
    end
  end

  @doc """
  Remove a way into the account on this process. The last one stays: an
  account with no way in is lost. The caller has already required a
  fresh second factor (`Hireme.Mfa.fresh?/1`).
  """
  @spec unlink(pos_integer(), meta()) :: :ok | {:error, :last | :not_found}
  def unlink(id, meta \\ %{}) when is_integer(id) do
    account_id = Repo.account_id!()

    with %Identity{} = identity <- Repo.get(Identity, id) || {:error, :not_found},
         {1, _} <- delete_unless_last(identity, account_id) do
      about = %{provider: identity.provider, display: identity.display}
      Audit.record(:identity_unlinked, about, meta)
      notify(account_id, :identity_unlinked, about)
      # The removed address hears it too; the remaining ones already did.
      if identity.provider == :email,
        do: Mail.enqueue(account_id, [identity.subject], :identity_unlinked, about)

      :ok
    else
      {0, _} -> {:error, :last}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # One statement, so two unlinks racing for the last two ways in cannot both win.
  defp delete_unless_last(%Identity{id: id}, account_id) do
    another = from(o in Identity, where: o.account_id == ^account_id and o.id != ^id)

    Store.write(fn ->
      Repo.delete_all(from(i in Identity, where: i.id == ^id and exists(another)))
    end)
  end

  @doc """
  Tell the account something happened to it through a channel other than
  the one that did it (NIST SP 800-63B-4 Sec. 4.1.2; ASVS 6.3.7): every
  linked address gets a notice through the outbox.
  """
  @spec notify(pos_integer(), atom(), map()) :: :ok
  def notify(account_id, kind, meta \\ %{}) when is_integer(account_id) and is_atom(kind) do
    addresses =
      Repo.all(
        from(i in Identity,
          where: i.account_id == ^account_id and i.provider == :email,
          select: i.subject
        ),
        skip_account: true
      )

    Mail.enqueue(account_id, addresses, kind, meta)
  end

  @doc "The one spelling of an address: trimmed, lowercased, shaped like one."
  @spec normalize_email(term()) :: {:ok, String.t()} | {:error, :invalid}
  def normalize_email(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    if byte_size(email) <= 254 and Regex.match?(@address, email),
      do: {:ok, email},
      else: {:error, :invalid}
  end

  def normalize_email(_), do: {:error, :invalid}

  defp find_identity(provider, subject),
    do: Repo.get_by(Identity, [provider: provider, subject: subject], skip_account: true)

  # A visitor nobody knows: an account named after them with this one way
  # in. Two first sign-ins racing on one subject leave one identity; the
  # loser finds the winner's.
  defp first_identity(provider, claim, meta) do
    Store.transaction(fn ->
      account = Repo.insert!(%Account{name: text(claim.display, 200), rev: 1})

      case insert_identity(account.id, provider, claim) do
        {:ok, identity} ->
          Audit.record(
            :account_created,
            %{provider: provider},
            Map.put(meta, :account_id, account.id)
          )

          identity

        {:error, _} ->
          Repo.rollback(:taken)
      end
    end)
    |> case do
      {:ok, identity} -> identity
      {:error, :taken} -> find_identity(provider, claim.subject)
    end
  end

  defp insert_identity(account_id, provider, claim) do
    %Identity{
      account_id: account_id,
      provider: provider,
      subject: String.slice(claim.subject, 0, 320),
      display: text(Map.get(claim, :display), 200),
      verified_at: Store.now(),
      rev: 1
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint([:provider, :subject])
    |> then(&Store.write(fn -> Repo.insert(&1) end))
  end

  defp touch_identity(%Identity{} = identity, claim),
    do:
      update!(identity,
        display: Security.clip(Map.get(claim, :display, identity.display)),
        verified_at: Store.now()
      )

  defp update!(row, changes) do
    row
    |> Ecto.Changeset.change([{:rev, row.rev + 1} | changes])
    |> then(&Store.write(fn -> Repo.update!(&1, skip_account: true) end))
  end

  # Blank is NULL, never '': no column holds an empty string.
  defp text(value, max) do
    case value && Security.clip(value, max) do
      nil -> nil
      "" -> nil
      text -> text
    end
  end

  defp context(meta, account_id, session_id),
    do: meta |> Map.put(:account_id, account_id) |> Map.put(:session_id, session_id)
end

defmodule Hireme.Accounts.Tickets do
  @moduledoc false
  # The spent half of a wire ticket: a nonce is spent once, atomically,
  # and forgotten after the ticket could no longer be fresh. One node, one
  # table; a ticket is never redeemed on another node.
  use GenServer

  @table __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec spend(binary()) :: :ok | :spent
  def spend(nonce) do
    expires = System.monotonic_time(:second) + 2 * Hireme.Security.ticket_ttl()
    if :ets.insert_new(@table, {nonce, expires}), do: :ok, else: :spent
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :timer.send_interval(:timer.seconds(Hireme.Security.ticket_ttl()), :sweep)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, s) do
    now = System.monotonic_time(:second)
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
    {:noreply, s}
  end
end
