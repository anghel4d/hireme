defmodule Hireme.Letterbox do
  @moduledoc """
  Leases: which process may write one application, and its CV lineage.

  An agent leases an application by its job id. The lease is held by the
  process that claims it, one process per lease: an agent's lane on its
  wire session (`HiremeWeb.LetterboxStream`). While it holds the lease,
  every write to that job from anyone else is refused `:leased`
  (`permit_job/2`), and so is a lease of another application on the same
  employer's lineage. A claim is two unique keys in
  `Hireme.Letterbox.Registry`, owned by the claiming process; `release/1`
  drops them at once, and the registry drops them when the process
  exits. The browser sees a job's `leased` column change either way.
  """

  alias Hireme.CvPair
  alias Hireme.Ops
  alias Hireme.Repo

  @registry __MODULE__.Registry

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
