defmodule Hireme.Letterbox do
  @moduledoc """
  Leases: which agent may write which applications.

  An agent holds one lease, on one block: the account's applications
  numbered `from..to` (`Desk.Job.no`, from 1, never reused), held by the
  agent's own wire session (`HiremeWeb.Session`), one process per agent.
  Blocks are aligned powers of two, as a buddy allocator's: asked for a
  size (`{:count, c}`), the desk grants the aligned block of the next
  power of two that splits the least free space, so freed blocks merge
  back into whole larger ones. Asked for a range (`{:range, from, to}`),
  it grants exactly that, clamped to 1..n, with a warning when the range
  ran past n or is a power of two off its alignment. A block is all or
  nothing: one that overlaps another agent's is refused, naming the
  numbers held and a free block of the same size. The block's writes
  ride its own lane, numbered by its first entry.

  While an agent holds a block, every write to its applications from
  anyone else is refused `:leased` (`permit_job/2`), and the agent may
  write only those. A CV is shared by an employer's applications, so the
  agent's first CV write for an employer also claims that employer's
  lineage; another agent's CV write there is refused `:lineage_busy`.
  Every claim is a unique key in `Hireme.Letterbox.Registry` (each number
  of the block, and each application in it), owned by the session;
  `release/1` drops them at once, and the registry drops them when the
  session exits. The browser sees a job's `leased` column change either way.
  """

  import Ecto.Query

  alias Hireme.ApiKeys
  alias Hireme.CvPair
  alias Hireme.Desk.Job
  alias Hireme.Ops
  alias Hireme.Repo

  @registry __MODULE__.Registry

  @type block :: %{
          from: pos_integer(),
          to: pos_integer(),
          lane: pos_integer(),
          jobs: [{pos_integer(), pos_integer()}],
          held: map()
        }
  @type want :: {:range, integer(), integer()} | {:count, integer()}
  @typedoc "What an agent asked for and what it got instead; every field is data, not prose."
  @type warning ::
          %{code: :truncated, asked: {integer(), integer()}, n: non_neg_integer()}
          | %{code: :count_capped, asked: integer(), n: non_neg_integer()}
          | %{
              code: :align,
              asked: {integer(), integer()},
              aligned: {pos_integer(), pos_integer()}
            }
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
    account = Repo.account_id!()
    numbered = Repo.all(from j in Job, order_by: j.no, select: {j.no, j.id})
    n = numbered |> List.last({0, nil}) |> elem(0)
    held = held(account, n)

    with {:ok, from, to, warnings} <- window(want, n, held),
         jobs = for({no, id} <- numbered, no in from..to//1, do: {no, id}),
         :ok <- claim(account, from, to, jobs, n) do
      ids = Enum.map(jobs, &elem(&1, 1))
      Ops.touch(account, ids)
      block = %{from: from, to: to, lane: from, jobs: jobs, held: Map.new(ids, &{&1, true})}
      {:ok, block, warnings}
    end
  end

  @doc "Give a block back now, with the lineages its CV writes claimed."
  @spec release(block() | nil) :: :ok
  def release(nil), do: :ok

  def release(%{held: held}) do
    for key <- Registry.keys(@registry, self()), do: Registry.unregister(@registry, key)
    Ops.touch(Repo.account_id!(), Map.keys(held))
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

  defp window(want, 0, _held), do: {:error, %{code: :empty, asked: asked(want), n: 0}}

  defp window({:range, from, to}, n, held) when from > to,
    do: window({:range, to, from}, n, held)

  defp window({:range, from, to}, n, _held) do
    case {max(from, 1), min(to, n)} do
      {f, t} when f > t -> {:error, %{code: :empty, asked: {from, to}, n: n}}
      {^from, ^to} -> {:ok, from, to, align(from, to)}
      {f, t} -> {:ok, f, t, [%{code: :truncated, asked: {from, to}, n: n}]}
    end
  end

  defp window({:count, count}, n, held) when count < 1, do: window({:count, 1}, n, held)

  defp window({:count, count}, n, held) when count > n do
    with {:ok, from, to, []} <- window({:count, n}, n, held),
         do: {:ok, from, to, [%{code: :count_capped, asked: count, n: n}]}
  end

  defp window({:count, count}, n, held) do
    case buddy(pow2(count), n, held) do
      {from, _to} -> {:ok, from, min(from + count - 1, n), []}
      nil -> {:error, %{code: :busy, held: [], free: nil, n: n}}
    end
  end

  defp asked({:range, from, to}), do: {from, to}
  defp asked(_count), do: nil

  # A power-of-two range off its alignment is granted, naming the aligned
  # block of its size that holds its first entry.
  defp align(from, to) do
    size = to - from + 1

    case {pow2(size) == size, rem(from - 1, size)} do
      {true, off} when off > 0 ->
        [%{code: :align, asked: {from, to}, aligned: {from - off, from - off + size - 1}}]

      _ ->
        []
    end
  end

  defp pow2(c), do: Integer.pow(2, ceil(:math.log2(max(c, 1))))

  # Buddy best fit: of the free aligned blocks of `size`, the one whose
  # smallest enclosing aligned block is already split (holds a lease), so
  # whole larger blocks stay whole; full-length blocks before the short
  # one at the end, then the lowest.
  defp buddy(size, n, held) do
    any? = fn f, t -> elem(held, min(t, n)) - elem(held, f - 1) > 0 end
    top = pow2(n)

    for f <- 1..n//size, not any?.(f, f + size - 1) do
      {{f + size - 1 > n, split(f, size * 2, top, any?), f}, {f, min(f + size - 1, n)}}
    end
    |> Enum.min_by(&elem(&1, 0), fn -> {nil, nil} end)
    |> elem(1)
  end

  # The size of the smallest aligned block around `f` that a lease has split.
  defp split(_f, size, top, _any?) when size > top, do: size

  defp split(f, size, top, any?) do
    start = div(f - 1, size) * size + 1
    if any?.(start, start + size - 1), do: size, else: split(f, size * 2, top, any?)
  end

  # How many of the numbers 0..i other leases hold, as a tuple for O(1) ranges.
  defp held(account, n) do
    taken =
      @registry
      |> Registry.select([{{{:no, account, :"$1"}, :_, :_}, [], [:"$1"]}])
      |> MapSet.new()

    Enum.scan(0..n, 0, fn i, acc -> acc + if(MapSet.member?(taken, i), do: 1, else: 0) end)
    |> List.to_tuple()
  end

  # All or nothing: a key already held by another lease refuses the block.
  # Registering is the check, so two agents racing for one free block cannot
  # both win it: the loser gives back what it took and is told who holds
  # the rest.
  defp claim(account, from, to, jobs, n) do
    keys = Enum.map(from..to, &{:no, account, &1}) ++ Enum.map(jobs, &{:job, elem(&1, 1)})
    taken = Enum.map(keys, &{&1, Registry.register(@registry, &1, true)})

    case for({{:no, _, i}, {:error, _}} <- taken, do: i) do
      [] ->
        :ok

      lost ->
        for {key, {:ok, _}} <- taken, do: Registry.unregister(@registry, key)
        free = buddy(pow2(to - from + 1), n, held(account, n))
        {:error, %{code: :busy, held: lost, free: free, n: n}}
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
