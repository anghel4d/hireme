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
    %Event{}
    |> Event.changeset(%{
      account_id: Map.get(context, :account_id) || Repo.account_id(),
      kind: Atom.to_string(kind),
      ip: Map.get(context, :ip, ""),
      user_agent: String.slice(Map.get(context, :user_agent, ""), 0, 200),
      meta: meta,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  @doc "The latest events for the account on the process."
  @spec recent(pos_integer()) :: [Event.t()]
  def recent(limit \\ 50) do
    Repo.all(from e in Event, order_by: [desc: e.id], limit: ^limit)
  end
end
