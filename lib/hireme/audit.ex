defmodule Hireme.Audit do
  @moduledoc """
  The security trail, and the account's topic.

  The trail is append-only (`audit` is declared `append_only`): who did
  what to an account, when, from where, with which key or session. CIS
  Controls v8.1 safeguards 8.2 and 8.5: every row carries its source
  address, user agent, time and kind. An agent's op batch is one row
  (`:agent_ops`), so the trail names every key that wrote.

  The topic `"account:<id>"` on `Hireme.PubSub` carries what a live
  session must react to: `{Hireme.Audit, :changed}` after every recorded
  event (the account lens re-reads), and the `{:bye, ...}` messages that
  end wire sessions (`bye/2`).
  """

  import Ecto.Query
  alias Hireme.Repo
  alias Hireme.Rows.Audit, as: Event
  alias Hireme.Store

  @type context :: %{
          optional(:account_id) => pos_integer() | nil,
          optional(:ip) => String.t(),
          optional(:user_agent) => String.t(),
          optional(:key_id) => pos_integer() | nil,
          optional(:session_id) => pos_integer() | nil
        }

  @typedoc "Why a wire session ends, and which ones: one key, one browser session, or all."
  @type bye ::
          {{:key, pos_integer()}, :revoked | :grants}
          | {{:session, pos_integer()}, :revoked}
          | {:account, :suspended}

  @doc """
  Record `kind` for the account in `context`, else the one on the
  process, else none (an event before sign-in). `meta` holds display
  fields only (names, kinds, counts, hashes), never a secret.
  """
  @spec record(atom(), map(), context()) :: :ok
  def record(kind, meta \\ %{}, context \\ %{}) when is_atom(kind) and is_map(meta) do
    account_id = Map.get(context, :account_id) || Repo.account_id()
    now = Store.now()

    Store.write(fn ->
      Repo.insert_all(
        Event,
        [
          %{
            account_id: account_id,
            kind: Atom.to_string(kind),
            ip: Hireme.Security.clip(Map.get(context, :ip, ""), 64),
            user_agent: Hireme.Security.clip(Map.get(context, :user_agent, "")),
            meta: meta,
            key_id: Map.get(context, :key_id),
            session_id: Map.get(context, :session_id),
            rev: 1,
            inserted_at: now,
            updated_at: now
          }
        ],
        skip_account: true
      )
    end)

    changed(account_id)
  end

  @spec topic(pos_integer()) :: String.t()
  def topic(account_id), do: "account:#{account_id}"

  @doc """
  Announce a change to the account's security state to every other
  process on its topic. Recording an event does this; a change that is
  not audited (a key renamed) calls it directly.
  """
  @spec changed(pos_integer() | nil) :: :ok
  def changed(nil), do: :ok

  def changed(account_id),
    do:
      Phoenix.PubSub.broadcast_from(
        Hireme.PubSub,
        self(),
        topic(account_id),
        {__MODULE__, :changed}
      )

  @doc "End the wire sessions `bye` names; each sends BYE with the reason and drops its lease."
  @spec bye(pos_integer(), bye()) :: :ok
  def bye(account_id, {who, reason}),
    do: Phoenix.PubSub.broadcast(Hireme.PubSub, topic(account_id), {:bye, who, reason})

  @doc "The latest events for the account on the process, newest first."
  @spec recent(pos_integer()) :: [struct()]
  def recent(limit \\ 50), do: Repo.all(from(e in Event, order_by: [desc: e.id], limit: ^limit))
end
