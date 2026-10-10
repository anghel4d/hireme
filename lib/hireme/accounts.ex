defmodule Hireme.Accounts do
  @moduledoc """
  The account: who signs in, and the sessions that prove it.

  An account is the standalone thing a desk belongs to. Identities (an
  email address, a GitHub user, an X user) are ways into it and may be
  linked and unlinked; the account outlives any one of them. Sign-in
  methods live beside this module and end by calling `start_session/2`;
  nothing else mints a session.

  A session is a row, not a cookie: the cookie carries a random token
  and the row holds its hash, so a session can be listed and revoked
  from the server (ASVS 7.2.1, 7.4.1, 7.5.2). Lifetimes are
  `Hireme.Security`'s: an overall limit and an idle limit (NIST SP
  800-63B-4 AAL2). `mfa_at` records the last second-factor proof on
  the session; `Hireme.Mfa.fresh?/1` reads it for step-up.
  """

  import Ecto.Query
  alias Hireme.Accounts.Account
  alias Hireme.Accounts.Identity
  alias Hireme.Accounts.MagicLink
  alias Hireme.Accounts.Session
  alias Hireme.Audit
  alias Hireme.Mailer
  alias Hireme.Repo
  alias Hireme.Security

  @type meta :: %{optional(:ip) => String.t(), optional(:user_agent) => String.t()}

  @typedoc "What a provider vouched for: its id for the person (the address, for mail) and a name to show."
  @type claim :: %{subject: String.t(), display: String.t()}

  @providers Identity.providers()
  @mail Hireme.Accounts.Mail
  # A sign-in link's send: tries, and the wait before each retry.
  @link_backoff [2_000, 8_000]
  @address ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/

  @spec create!(map()) :: Account.t()
  def create!(attrs \\ %{}), do: %Account{} |> Account.changeset(attrs) |> Repo.insert!()

  @spec get(pos_integer()) :: Account.t() | nil
  def get(id) when is_integer(id), do: Repo.get(Account, id, skip_account: true)

  @spec active?(Account.t() | nil) :: boolean()
  def active?(%Account{status: :active}), do: true
  def active?(_), do: false

  @doc """
  The local desk's account: the first one, created on demand. Mix tasks
  and the seed run as it; a server never calls this.
  """
  @spec use_default!() :: Account.t()
  def use_default! do
    account =
      Repo.one(from(a in Account, order_by: a.id, limit: 1), skip_account: true) ||
        create!(%{name: "Local desk"})

    Repo.put_account(account.id)
    account
  end

  @doc """
  Open a session for `account`. Returns the token the cookie carries
  and the row; the token is not stored and cannot be recovered.
  """
  @spec start_session(Account.t(), meta()) :: {String.t(), Session.t()}
  def start_session(%Account{} = account, meta \\ %{}) do
    token = Security.token(32)
    now = now()

    session =
      %Session{}
      |> Session.changeset(%{
        account_id: account.id,
        token_hash: Security.hash(token),
        authenticated_at: now,
        last_seen_at: now,
        expires_at: DateTime.add(now, Security.session_lifetime(), :second),
        ip: Map.get(meta, :ip, ""),
        user_agent: String.slice(Map.get(meta, :user_agent, ""), 0, 200)
      })
      |> Repo.insert!()

    Audit.record(
      :session_started,
      %{session_id: session.id},
      Map.put(meta, :account_id, account.id)
    )

    {Base.url_encode64(token, padding: false), session}
  end

  @doc """
  The live session a token names, with its account, or nil: unknown,
  revoked, past its overall lifetime, idle too long, or the account is
  not active. Session and account are read together, without caching
  either one's validity. A live session is touched at most once a minute.
  """
  @spec session(String.t()) :: {Session.t(), Account.t()} | nil
  def session(token) when is_binary(token) do
    now = now()

    with {:ok, raw} <- Base.url_decode64(token, padding: false),
         {%Session{} = session, %Account{} = account} <-
           Repo.one(
             from(s in Session,
               join: a in Account,
               on: a.id == s.account_id,
               where: s.token_hash == ^Security.hash(raw),
               select: {s, a}
             ),
             skip_account: true
           ),
         true <- live?(session, now),
         true <- active?(account) do
      {touch(session, now), account}
    else
      _ -> nil
    end
  end

  def session(_), do: nil

  defp live?(%Session{} = s, now) do
    is_nil(s.revoked_at) and DateTime.compare(now, s.expires_at) == :lt and
      DateTime.diff(now, s.last_seen_at) < Security.session_idle()
  end

  defp touch(%Session{} = s, now) do
    if DateTime.diff(now, s.last_seen_at) >= 60 do
      s |> Ecto.Changeset.change(last_seen_at: now) |> Repo.update!()
    else
      s
    end
  end

  @doc "A second factor was just presented on this session."
  @spec mark_mfa(Session.t()) :: Session.t()
  def mark_mfa(%Session{} = s), do: s |> Ecto.Changeset.change(mfa_at: now()) |> Repo.update!()

  @spec list_sessions(pos_integer()) :: [Session.t()]
  def list_sessions(account_id) do
    Repo.all(
      from(s in Session,
        where: s.account_id == ^account_id and is_nil(s.revoked_at),
        order_by: [desc: s.last_seen_at]
      ),
      skip_account: true
    )
  end

  @spec revoke_session(Session.t()) :: Session.t()
  def revoke_session(%Session{} = s) do
    s = s |> Ecto.Changeset.change(revoked_at: now()) |> Repo.update!()
    Audit.record(:session_revoked, %{session_id: s.id}, %{account_id: s.account_id})
    s
  end

  @doc "Sign every other browser out (ASVS 7.4.3), keeping `keep`."
  @spec revoke_other_sessions(Session.t()) :: non_neg_integer()
  def revoke_other_sessions(%Session{} = keep) do
    {n, _} =
      Repo.update_all(
        from(s in Session,
          where: s.account_id == ^keep.account_id and s.id != ^keep.id and is_nil(s.revoked_at)
        ),
        [set: [revoked_at: now()]],
        skip_account: true
      )

    if n > 0, do: Audit.record(:sessions_revoked, %{count: n}, %{account_id: keep.account_id})
    n
  end

  ## Sign-in methods

  @doc """
  Mail a one-time sign-in link to `email`. `url_for` turns the token into
  the URL the mail carries, so the path stays with the router. A
  well-formed address gets `:ok` whether or not it has an account; the
  answer never says which. Five per address and twenty per peer in ten
  minutes.

  The answer does not wait on the mail provider: the send runs in a
  supervised task (`Hireme.Accounts.Mail`) with two retries, and the link
  lives only in that task's memory. It is never written down, so a
  restart mid-send loses it and the person asks again.
  """
  @spec request_link(String.t(), (String.t() -> String.t()), meta()) ::
          :ok | {:error, :invalid | :rate_limited}
  def request_link(email, url_for, meta \\ %{}) when is_function(url_for, 1) do
    with {:ok, email} <- normalize_email(email),
         :ok <- Security.limit(:link_address, email),
         :ok <- Security.limit(:link_peer, Map.get(meta, :ip, "")) do
      token = Security.token(32)
      now = now()

      %MagicLink{}
      |> MagicLink.changeset(%{
        email: email,
        token_hash: Security.hash(token),
        expires_at: DateTime.add(now, Security.magic_link_ttl(), :second),
        ip: Map.get(meta, :ip, ""),
        user_agent: String.slice(Map.get(meta, :user_agent, ""), 0, 200)
      })
      |> Repo.insert!()

      Audit.record(:link_requested, trace(email), meta)

      url = url_for.(Base.url_encode64(token, padding: false))

      {:ok, _} =
        Task.Supervisor.start_child(@mail, fn -> send_link(email, url, @link_backoff) end)

      :ok
    end
  end

  # The mailer logs each failure; a link still unsent after the last try
  # is dropped with the task.
  defp send_link(email, url, backoff) do
    case {Mailer.sign_in_link(email, url), backoff} do
      {:ok, _} ->
        :ok

      {{:error, _}, [wait | rest]} ->
        Process.sleep(wait)
        send_link(email, url, rest)

      {{:error, _}, []} ->
        :error
    end
  end

  @doc """
  The address a live link would prove, without spending it. Mail scanners
  open every link they see; only `redeem_link/2`, behind a deliberate
  request, spends one.
  """
  @spec peek_link(String.t()) :: {:ok, String.t()} | {:error, :invalid}
  def peek_link(token) do
    case live_link(token, now()) do
      %MagicLink{email: email} -> {:ok, email}
      nil -> {:error, :invalid}
    end
  end

  @doc """
  Burn a link and prove its address; nothing else. What a proven address
  means is `sign_in_with/3` for a visitor or `link/3` for an account.
  """
  @spec redeem_link(String.t(), meta()) :: {:ok, String.t()} | {:error, :invalid | :rate_limited}
  def redeem_link(token, meta \\ %{}) do
    now = now()

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

  defp live_link(token, now) when is_binary(token) do
    with {:ok, raw} <- Base.url_decode64(token, padding: false),
         %MagicLink{used_at: nil} = link <-
           Repo.get_by(MagicLink, [token_hash: Security.hash(raw)], skip_account: true),
         true <- DateTime.compare(now, link.expires_at) == :lt do
      link
    else
      _ -> nil
    end
  end

  defp live_link(_, _), do: nil

  # Single use under concurrency: the row is taken only if still unused.
  defp burn(%MagicLink{id: id}, now) do
    Repo.update_all(
      from(l in MagicLink, where: l.id == ^id and is_nil(l.used_at)),
      [set: [used_at: now]],
      skip_account: true
    )
  end

  @doc """
  Sign in as the account a proven identity belongs to, creating the
  account and the identity when they are new. On success the account is
  the one on this process, and the token is the cookie's.
  """
  @spec sign_in_with(Identity.provider(), claim(), meta()) ::
          {:ok, String.t(), Session.t()} | {:error, :suspended}
  def sign_in_with(provider, %{subject: subject} = claim, meta \\ %{})
      when provider in @providers do
    identity = find_identity(provider, subject) || first_identity(provider, claim, meta)
    account = get(identity.account_id)

    if active?(account) do
      Repo.put_account(account.id)
      touch_identity(identity, claim)

      Audit.record(
        :signed_in,
        %{provider: provider, identity_id: identity.id},
        Map.put(meta, :account_id, account.id)
      )

      {token, session} = start_session(account, meta)
      {:ok, token, session}
    else
      {:error, :suspended}
    end
  end

  @doc "The ways into the account on this process, oldest first."
  @spec identities() :: [Identity.t()]
  def identities, do: Repo.all(from(i in Identity, order_by: i.id))

  @doc """
  Bind a proven identity to the account on this process. Binding one it
  already has is a no-op; one bound to another account is `:taken`. The
  account is told through its mail (NIST SP 800-63B-4 Sec. 4.1.2).
  """
  @spec link(Identity.provider(), claim(), meta()) :: {:ok, Identity.t()} | {:error, :taken}
  def link(provider, %{subject: subject} = claim, meta \\ %{}) when provider in @providers do
    account_id = Repo.account_id!()

    case find_identity(provider, subject) do
      %Identity{account_id: ^account_id} = identity ->
        {:ok, touch_identity(identity, claim)}

      %Identity{} ->
        {:error, :taken}

      nil ->
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
  end

  @doc """
  Remove a way into the account on this process. The last one stays:
  an account with no way in is lost. The caller has already asked for a
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
        do: Mailer.Outbox.enqueue(account_id, [identity.subject], :identity_unlinked, about)

      :ok
    else
      {0, _} -> {:error, :last}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # One statement, so two unlinks racing for the last two ways in cannot both win.
  defp delete_unless_last(%Identity{id: id}, account_id) do
    another = from(o in Identity, where: o.account_id == ^account_id and o.id != ^id)
    Repo.delete_all(from(i in Identity, where: i.id == ^id and exists(another)))
  end

  @doc """
  Tell the account something happened to it, through a channel other
  than the one that did it (NIST SP 800-63B-4 Sec. 4.1.2; ASVS 6.3.7):
  every address linked to it gets a notice, and the trail records it.
  """
  @spec notify(pos_integer(), atom(), map()) :: :ok
  def notify(account_id, kind, meta \\ %{}) when is_integer(account_id) and is_atom(kind) do
    Audit.record(:notified, Map.put(meta, :about, kind), %{account_id: account_id})

    addresses =
      Repo.all(
        from(i in Identity,
          where: i.account_id == ^account_id and i.provider == :email,
          select: i.subject
        ),
        skip_account: true
      )

    # Queued, not sent: the request does not wait on the mail provider.
    Mailer.Outbox.enqueue(account_id, addresses, kind, meta)
    :ok
  end

  @doc "The one spelling of an address the desk stores and compares: trimmed, lowercased, shaped like one."
  @spec normalize_email(term()) :: {:ok, String.t()} | {:error, :invalid}
  def normalize_email(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    if byte_size(email) <= 254 and Regex.match?(@address, email),
      do: {:ok, email},
      else: {:error, :invalid}
  end

  def normalize_email(_), do: {:error, :invalid}

  defp find_identity(provider, subject) do
    Repo.get_by(Identity, [provider: provider, subject: subject], skip_account: true)
  end

  # A visitor nobody knows: an account named after them, with this one way in.
  # Two first sign-ins racing on one subject leave one identity; the loser finds it.
  defp first_identity(provider, claim, meta) do
    Repo.transaction(fn ->
      account = create!(%{name: claim.display})

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
    %Identity{}
    |> Identity.changeset(%{
      account_id: account_id,
      provider: provider,
      subject: claim.subject,
      display: Map.get(claim, :display, ""),
      verified_at: now()
    })
    |> Repo.insert()
  end

  defp touch_identity(%Identity{} = identity, claim) do
    identity
    |> Identity.changeset(%{
      display: Map.get(claim, :display, identity.display),
      verified_at: now()
    })
    |> Repo.update!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
