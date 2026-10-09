defmodule Hireme.Letterbox do
  @moduledoc """
  Leases: which agent may write which applications.

  An agent holds one lease, on one block: a contiguous run of the
  account's applications, numbered 1..n in the order they were added (by
  id), so a block keeps its entries as new applications arrive. The
  lease is held by the agent's own wire session (`HiremeWeb.Session`),
  one process per agent. An agent asks for a range (`{:range, from, to}`,
  clamped to 1..n with a warning) or for the first free block of a size
  (`{:count, n}`). A block is all or nothing: one that overlaps another
  agent's is refused, naming the entries held and the nearest free block
  of the same size.

  While an agent holds a block, every write to its applications from
  anyone else is refused `:leased` (`permit_job/2`), and the agent may
  write only those. A CV is shared by an employer's applications, so the
  agent's first CV write for an employer also claims that employer's
  lineage; another agent's CV write there is refused `:lineage_busy`.
  Every claim is a unique key in `Hireme.Letterbox.Registry`, owned by
  the session; `release/1` drops them at once, and the registry drops
  them when the session exits. The browser sees a job's `leased` column
  change either way.
  """

  import Ecto.Query

  alias Hireme.ApiKeys
  alias Hireme.CvPair
  alias Hireme.Desk.Job
  alias Hireme.Ops
  alias Hireme.Repo

  @registry __MODULE__.Registry

  @type block :: %{from: pos_integer(), to: pos_integer(), jobs: [pos_integer()], held: map()}
  @type want :: {:range, integer(), integer()} | {:count, integer()}
  @typedoc "What an agent asked for and what it got instead; every field is data, not prose."
  @type warning ::
          %{code: :truncated, asked: {integer(), integer()}, n: non_neg_integer()}
          | %{code: :count_capped, asked: integer(), n: non_neg_integer()}
  @type refusal ::
          %{code: :empty, asked: {integer(), integer()} | nil, n: non_neg_integer()}
          | %{
              code: :busy,
              held: [pos_integer()],
              free: {pos_integer(), pos_integer()} | nil,
              n: non_neg_integer()
            }

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

  @doc """
  Lease a block for the calling process, in the account on it. The
  answer carries the block and any warnings (a range clamped to what
  exists); a refusal carries what is held and the nearest free block.
  """
  @spec acquire(want()) :: {:ok, block(), [warning()]} | {:error, refusal()}
  def acquire(want) do
    entries = Repo.all(from j in Job, order_by: j.id, select: j.id)

    with {:ok, from, to, warnings} <- window(want, entries),
         jobs = Enum.slice(entries, from - 1, to - from + 1),
         :ok <- claim(jobs, from, entries) do
      Ops.touch(Repo.account_id!(), jobs)
      {:ok, %{from: from, to: to, jobs: jobs, held: Map.new(jobs, &{&1, true})}, warnings}
    end
  end

  @doc "Give a block back now, with the lineages its CV writes claimed."
  @spec release(block() | nil) :: :ok
  def release(nil), do: :ok

  def release(%{jobs: jobs}) do
    for key <- Registry.keys(@registry, self()), do: Registry.unregister(@registry, key)
    Ops.touch(Repo.account_id!(), jobs)
  end

  @doc """
  Whether a lease on `block` may run `op`. An application's own ops need
  the application in the block, and a CV op the employer's lineage too;
  the desk's own ops (gym, net, narrative, open fire) need no lease.
  """
  @spec permit(block() | nil, map()) :: :ok | {:error, term()}
  def permit(%{held: held}, %{kind: kind, target: job})
      when kind in [:overlay, :generation] and is_map_key(held, job),
      do: lineage(job)

  def permit(%{held: held}, %{kind: kind, target: job})
      when kind in [:stage, :next, :note, :score, :heat_override] and is_map_key(held, job),
      do: :ok

  def permit(_block, %{kind: kind})
      when kind in [:stage, :next, :note, :score, :heat_override, :overlay, :generation],
      do: {:error, {:leased, "That application is not in this agent's block: lease it first."}}

  def permit(_block, _op), do: :ok

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

  # ---- Blocks ----

  defp window(want, []), do: {:error, %{code: :empty, asked: asked(want), n: 0}}

  defp window({:range, from, to}, entries) when from > to, do: window({:range, to, from}, entries)

  defp window({:range, from, to}, entries) do
    n = length(entries)

    case {max(from, 1), min(to, n)} do
      {f, t} when f > t -> {:error, %{code: :empty, asked: {from, to}, n: n}}
      {^from, ^to} -> {:ok, from, to, []}
      {f, t} -> {:ok, f, t, [%{code: :truncated, asked: {from, to}, n: n}]}
    end
  end

  defp window({:count, count}, entries) when count < 1, do: window({:count, 1}, entries)

  defp window({:count, count}, entries) when count > length(entries) do
    with {:ok, from, to, []} <- free(entries, length(entries)),
         do: {:ok, from, to, [%{code: :count_capped, asked: count, n: length(entries)}]}
  end

  defp window({:count, count}, entries), do: free(entries, count)

  defp asked({:range, from, to}), do: {from, to}
  defp asked(_count), do: nil

  # The first run of `count` entries no lease holds.
  defp free(entries, count) do
    held = leased_jobs()

    entries
    |> Enum.with_index(1)
    |> Enum.reduce_while({nil, 0}, fn {id, i}, {start, run} ->
      case {MapSet.member?(held, id), run + 1} do
        {true, _} -> {:cont, {nil, 0}}
        {false, ^count} -> {:halt, {start || i, count}}
        {false, run} -> {:cont, {start || i, run}}
      end
    end)
    |> case do
      {from, ^count} -> {:ok, from, from + count - 1, []}
      _ -> {:error, %{code: :busy, held: [], free: nil, n: length(entries)}}
    end
  end

  # All or nothing: a key already held by another lease refuses the block.
  # Registering is the check, so two agents racing for one free run cannot
  # both win it: the loser gives back what it took and is told who holds
  # the rest.
  defp claim(jobs, from, entries) do
    taken = Enum.map(jobs, &Registry.register(@registry, {:job, &1}, true))

    case for({{:error, _}, i} <- Enum.with_index(taken, from), do: i) do
      [] ->
        :ok

      held ->
        for {{:ok, _}, id} <- Enum.zip(taken, jobs),
            do: Registry.unregister(@registry, {:job, id})

        free =
          case free(entries, length(jobs)) do
            {:ok, f, t, _} -> {f, t}
            {:error, _} -> nil
          end

        {:error, %{code: :busy, held: held, free: free, n: length(entries)}}
    end
  end

  # A CV write claims the employer's lineage for this lease, once.
  defp lineage(job_id) do
    with {:ok, pair} <- CvPair.bind(job_id),
         {:error, {:already_registered, pid}} when pid != self() <-
           Registry.register(@registry, {:lineage, CvPair.lineage_id(pair)}, true) do
      {:error, :lineage_busy}
    else
      {:error, :unbound} -> {:error, :not_found}
      _ -> :ok
    end
  end
end
