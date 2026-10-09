defmodule Hireme.Letterbox do
  @moduledoc """
  Leases: which process may write one application, and its CV lineage.

  An agent leases an application by its job id. The lease is held by the
  process that claims it: the agent's own wire session
  (`HiremeWeb.Session`), one process per agent, holding each lease on a
  lane of its own. While it holds the lease,
  every write to that job from anyone else is refused `:leased`
  (`permit_job/2`), and so is a lease of another application on the same
  employer's lineage. A claim is two unique keys in
  `Hireme.Letterbox.Registry`, owned by the claiming process; `release/1`
  drops them at once, and the registry drops them when the process
  exits. The browser sees a job's `leased` column change either way.
  """

  alias Hireme.ApiKeys
  alias Hireme.CvPair
  alias Hireme.Ops
  alias Hireme.Repo

  @registry __MODULE__.Registry
  # The ops a lease may run: the job's own, never the desk's.
  @lease_kinds [:stage, :next, :note, :score, :overlay, :heat_override, :generation]

  @doc """
  The agent a presented API key names, counted once against the peer's
  key limiter. An agent's session calls this once, for its HELLO.
  """
  @spec agent_key(term(), String.t()) ::
          {:ok, %{account_id: pos_integer(), key_id: String.t(), expires_at: term()}} | :error
  def agent_key(token, peer) when is_binary(peer) do
    case ApiKeys.authenticate(token, peer) do
      {:ok, key} ->
        {:ok, %{account_id: key.account_id, key_id: key.key_id, expires_at: key.expires_at}}

      :error ->
        :error
    end
  end

  @doc "Whether `op` is one a lease on `pair` may run: its job's own kinds, on its job."
  @spec lease_op?(map(), CvPair.t()) :: boolean()
  def lease_op?(%{kind: kind, target: target}, pair),
    do: kind in @lease_kinds and target == CvPair.job_id(pair)

  @doc """
  Lease `job_id`, in the account on the process, for the calling
  process. Refused `:not_found` for a job the account cannot see,
  `:busy` when another lease holds it, `:lineage_busy` when another
  lease holds its employer's lineage.
  """
  @spec claim(pos_integer()) :: {:ok, CvPair.t()} | {:error, :not_found | :busy | :lineage_busy}
  def claim(job_id) when is_integer(job_id) do
    with {:ok, pair} <- bind(job_id),
         :ok <- register({:job, CvPair.job_id(pair)}, :busy),
         :ok <- lineage(pair) do
      Ops.touch(Repo.account_id!(), [job_id])
      {:ok, pair}
    end
  end

  @doc "Give a lease back now, so the next claim sees it free."
  @spec release(CvPair.t()) :: :ok
  def release(pair) do
    Registry.unregister(@registry, {:job, CvPair.job_id(pair)})
    Registry.unregister(@registry, {:lineage, CvPair.lineage_id(pair)})
    Ops.touch(Repo.account_id!(), [CvPair.job_id(pair)])
  end

  @doc """
  A write to `job_id` is allowed unless a lease other than `holder`'s
  holds it. `holder` is the process a write runs for (`Ops.holder/0`).
  """
  @spec permit_job(pos_integer(), pid()) :: :ok | {:error, :leased}
  def permit_job(job_id, holder \\ self()) when is_integer(job_id) and is_pid(holder) do
    case Registry.lookup(@registry, {:job, job_id}) do
      [{pid, _}] when pid != holder -> {:error, :leased}
      _ -> :ok
    end
  end

  @doc """
  Every job a lease holds right now. Job ids are unique across
  accounts, so the caller filters its own cards by membership.
  """
  @spec leased_jobs() :: MapSet.t(pos_integer())
  def leased_jobs do
    @registry
    |> Registry.select([{{{:job, :"$1"}, :_, :_}, [], [:"$1"]}])
    |> MapSet.new()
  end

  defp bind(job_id) do
    case CvPair.bind(job_id) do
      {:ok, pair} -> {:ok, pair}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp lineage(pair) do
    with {:error, reason} <- register({:lineage, CvPair.lineage_id(pair)}, :lineage_busy) do
      Registry.unregister(@registry, {:job, CvPair.job_id(pair)})
      {:error, reason}
    end
  end

  defp register(key, refusal) do
    case Registry.register(@registry, key, true) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> {:error, refusal}
    end
  end
end
