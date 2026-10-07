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
  alias Hireme.Accounts.Session
  alias Hireme.Audit
  alias Hireme.Repo
  alias Hireme.Security

  @type meta :: %{optional(:ip) => String.t(), optional(:user_agent) => String.t()}

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
  not active. A live session is touched at most once a minute.
  """
  @spec session(String.t()) :: {Session.t(), Account.t()} | nil
  def session(token) when is_binary(token) do
    now = now()

    with {:ok, raw} <- Base.url_decode64(token, padding: false),
         %Session{} = session <-
           Repo.get_by(Session, [token_hash: Security.hash(raw)], skip_account: true),
         true <- live?(session, now),
         %Account{} = account <- get(session.account_id),
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
    Audit.record(:session_revoked, %{session_id: s.id}, %{account_id: s.account_id})
    s |> Ecto.Changeset.change(revoked_at: now()) |> Repo.update!()
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

  @doc """
  Tell the account something happened to it, through a channel other
  than the one that did it (NIST SP 800-63B-4 Sec. 4.1.2; ASVS 6.3.7).
  The sign-in methods beside this module deliver it; until one does, the
  event is on the audit trail and in the log.
  """
  @spec notify(pos_integer(), atom(), map()) :: :ok
  def notify(account_id, kind, meta \\ %{}) when is_integer(account_id) and is_atom(kind) do
    Audit.record(:notified, Map.put(meta, :about, kind), %{account_id: account_id})
    require Logger
    Logger.info("account #{account_id}: #{kind} #{inspect(meta)}")
    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
