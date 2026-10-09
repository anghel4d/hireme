defmodule Hireme.Letterbox.Handle do
  @moduledoc """
  The agent's lease on one letterbox.

  `Hireme.Letterbox.lease/2` is the constructor. The process that
  receives the handle is the only producer. The letterbox process is the
  only consumer. `pair` is the CV for the one application this letterbox
  owns. A command has no application id, so the handle cannot be aimed
  at a different one. `token` is a reference made inside the consumer;
  the consumer accepts a command only from the producer pid with that
  token.
  """

  @enforce_keys [:id, :token, :pid, :pair]
  defstruct [:id, :token, :pid, :pair]

  @type t :: %__MODULE__{
          id: pos_integer(),
          token: reference(),
          pid: pid(),
          pair: Hireme.CvPair.t()
        }
end

defmodule Hireme.Letterbox do
  @moduledoc """
  One letterbox, one application, one producer, one consumer.

  An MCP connection leases a letterbox id. That lease is a `Handle.t()`
  and it is what opens the full-duplex socket. The handle closes over
  the CV pair for that application. Commands are literals (`:get`,
  `{:set_stage, stage}`, `{:tailor, item_id, attrs}`) with no target id.
  The consumer applies them to the pair in its state.

  A second connection cannot lease that letterbox. A second connection
  cannot lease another application that shares the employer's CV
  lineage. One producer process cannot hold two leases.
  """

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Hireme.Desk.Batch
  alias Hireme.Desk.Job
  alias Hireme.Letterbox.Box
  alias Hireme.Letterbox.Handle
  alias Hireme.Letterbox.Record
  alias Hireme.Repo

  @registry __MODULE__.Registry

  @type command :: Hireme.Desk.command()
  @type reply :: Hireme.Desk.reply()

  @type entry :: %{
          id: pos_integer(),
          job_id: pos_integer(),
          company: String.t(),
          role: String.t(),
          stage: Hireme.Pipeline.stage(),
          batch: String.t() | nil,
          score_100: Hireme.LifeEv.score(),
          leased: boolean()
        }

  @spec open!(pos_integer()) :: Record.t()
  def open!(job_id) when is_integer(job_id) do
    %Record{} |> Record.changeset(%{job_app_id: job_id}) |> Repo.insert!()
  end

  @spec exists?(pos_integer()) :: boolean()
  def exists?(id) when is_integer(id), do: Repo.exists?(from r in Record, where: r.id == ^id)

  @spec for_job(pos_integer()) :: Record.t() | nil
  def for_job(job_id) when is_integer(job_id), do: Repo.get_by(Record, job_app_id: job_id)

  @spec lease(pos_integer(), pid()) :: {:ok, Handle.t()} | {:error, atom()}
  def lease(id, producer) when is_integer(id) and id > 0 and is_pid(producer) do
    with {:ok, pid} <- start_box(id) do
      allow_sandbox(producer, pid)
      GenServer.call(pid, {:lease, producer})
    end
  end

  @spec release(Handle.t()) :: :ok | {:error, :lease}
  def release(%Handle{pid: pid, token: token}) do
    GenServer.call(pid, {:release, token})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Run one command on the application this handle closes over. The
  reply is `Hireme.Desk.perform/2`'s, or `{:error, :lease}` when the
  caller is not the producer or the token is not this lease's.
  """
  @spec command(Handle.t(), command()) :: reply() | {:error, :lease}
  def command(%Handle{pid: pid, token: token}, command)
      when command in [:get, :open_generation] or
             (is_tuple(command) and
                elem(command, 0) in [:set_stage, :set_next, :set_score, :tailor]) do
    GenServer.call(pid, {:cmd, token, command})
  end

  @doc "A box exists only while a lease is held or being taken."
  @spec leased?(pos_integer()) :: boolean()
  def leased?(id) when is_integer(id), do: Registry.lookup(@registry, {:box, id}) != []

  @doc """
  A write to `job_id` is allowed unless a lease other than `holder`'s
  holds it. `holder` is the box whose command is being run, when a write
  is carried out by another process on its behalf.
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

  @spec list() :: [entry()]
  def list do
    Record
    |> join(:inner, [r], j in Job, on: j.id == r.job_app_id)
    |> join(:left, [r, j], b in Batch, on: b.id == j.batch_id)
    |> order_by([r], r.id)
    |> select([r, j, b], %{
      id: r.id,
      job_id: j.id,
      company: j.company,
      role: j.role,
      stage: j.current_stage,
      batch: b.code,
      score_100: j.score_100
    })
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :leased, leased?(&1.id)))
  end

  defp start_box(id) do
    if exists?(id) do
      case DynamicSupervisor.start_child(__MODULE__.Supervisor, {Box, {id, Repo.account_id!()}}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, _pid}} -> {:error, :busy}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :letterbox}
    end
  end

  defp allow_sandbox(parent, child) do
    if Repo.config()[:pool] == Sandbox do
      Sandbox.allow(Repo, parent, child)
    end
  end
end
