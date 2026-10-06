defmodule Hireme.Kv do
  @moduledoc """
  Namespaced key-value pairs.

  `global` is the person. `profile:<id>` is a positioning. `app:<id>` is
  process metadata for one application (recruiter, req id) and shadows
  nothing on the CV. CV lines are items and overlays, not this table.
  """

  import Ecto.Query
  alias Hireme.Kv.Pair
  alias Hireme.Repo

  def put(namespace, key, value) when is_binary(namespace) and is_binary(key) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Pair{}
    |> Pair.changeset(%{namespace: namespace, key: key, value: value})
    |> Repo.insert!(
      on_conflict: [set: [value: value, updated_at: now]],
      conflict_target: [:namespace, :key]
    )
  end

  def list(namespace) do
    Repo.all(from p in Pair, where: p.namespace == ^namespace, order_by: p.key)
  end

  def get(namespace, key) do
    Repo.get_by(Pair, namespace: namespace, key: key)
  end
end
