defmodule Hireme.Audit do
  @moduledoc """
  The security trail: who did what to an account, when, from where.
  Append only; nothing here is edited or deleted by the application.
  CIS Controls v8.1 safeguard 8.2 and 8.5: every event carries its
  source address, user agent, time, and kind.
  """

  import Ecto.Query
  alias Hireme.Audit.Event
  alias Hireme.Repo
  alias Hireme.Store

  @type context :: %{
          optional(:account_id) => pos_integer() | nil,
          optional(:ip) => String.t(),
          optional(:user_agent) => String.t()
        }

  @doc """
  Record `kind` for the account in `context`, or the one on the process,
  or none (an event before sign-in).
  """
  @spec record(atom(), map(), context()) :: Event.t()
  def record(kind, meta \\ %{}, context \\ %{}) when is_atom(kind) do
    account_id = Map.get(context, :account_id) || Repo.account_id()

    event =
      %Event{}
      |> Event.changeset(%{
        account_id: account_id,
        kind: Atom.to_string(kind),
        ip: Map.get(context, :ip, ""),
        user_agent: String.slice(Map.get(context, :user_agent, ""), 0, 200),
        meta: meta,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Store.write(&Repo.insert!/1)

    changed(account_id)
    event
  end

  @doc """
  The topic where an account's security state is announced: keys,
  sessions, ways in, factors. A browser session redraws its account
  tables on `{Hireme.Audit, :changed}`.
  """
  @spec topic(pos_integer()) :: String.t()
  def topic(account_id), do: "account:#{account_id}"

  @doc """
  Announce a change to the account's security state. Every recorded event
  announces itself; a change that is not audited (a key renamed) calls
  this directly. The calling process is left out: it already knows.
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

  @doc "The latest events for the account on the process."
  @spec recent(pos_integer()) :: [Event.t()]
  def recent(limit \\ 50) do
    Repo.all(from e in Event, order_by: [desc: e.id], limit: ^limit)
  end
end
