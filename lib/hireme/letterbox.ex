defmodule Hireme.Letterbox.Id do
  @moduledoc false
  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: pos_integer()}

  @spec new(pos_integer()) :: t()
  def new(value) when is_integer(value) and value > 0, do: %__MODULE__{value: value}
end

defmodule Hireme.Letterbox.Token do
  @moduledoc false
  @enforce_keys [:ref]
  defstruct [:ref]

  @type t :: %__MODULE__{ref: reference()}
end

defmodule Hireme.Letterbox.Handle do
  @moduledoc """
  The agent's lease on one letterbox.

  `lease/2` is the constructor. The process that receives the handle is
  the only producer. The letterbox process is the only consumer. `pair`
  is the CV for the one application this letterbox owns. A command has
  no application id, so the handle cannot be aimed at a different one.
  """

  alias Hireme.CvPair
  alias Hireme.Letterbox.Id
  alias Hireme.Letterbox.Token

  @enforce_keys [:id, :token, :pid, :pair]
  defstruct [:id, :token, :pid, :pair]

  @type t :: %__MODULE__{
          id: Id.t(),
          token: Token.t(),
          pid: pid(),
          pair: CvPair.t()
        }
end

defmodule Hireme.Letterbox.Record do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  schema "letterboxes" do
    belongs_to :job_app, Hireme.Desk.Job

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:job_app_id])
    |> validate_required([:job_app_id])
    |> unique_constraint(:job_app_id)
    |> foreign_key_constraint(:job_app_id)
  end
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
  lineage. One producer process cannot hold two leases. The consumer
  accepts a command only from the producer pid, and only with the
  `reference()` token created inside the consumer. Those are different
  structs from a job id or a variant id, so they do not type-check in
  each other's place.
  """

  import Ecto.Query
  alias Hireme.Desk.Batch
  alias Hireme.Desk.Job
  alias Hireme.Letterbox.Box
  alias Hireme.Letterbox.Handle
  alias Hireme.Letterbox.Id
  alias Hireme.Letterbox.Record
  alias Hireme.Letterbox.Token
  alias Hireme.Repo

  @type command :: Hireme.Desk.command()
  @type reply :: Hireme.Desk.reply()

  @spec open!(pos_integer()) :: Record.t()
  def open!(job_id) when is_integer(job_id) do
    %Record{}
    |> Record.changeset(%{job_app_id: job_id})
    |> Repo.insert!()
  end

  @spec exists?(pos_integer()) :: boolean()
  def exists?(id) when is_integer(id) do
    Repo.exists?(from r in Record, where: r.id == ^id)
  end

  @spec for_job(pos_integer()) :: Record.t() | nil
  def for_job(job_id) when is_integer(job_id) do
    Repo.get_by(Record, job_app_id: job_id)
  end

  @spec lease(Id.t() | pos_integer(), pid()) ::
          {:ok, Handle.t()} | {:error, atom()}
  def lease(%Id{value: id}, producer) when is_pid(producer), do: lease(id, producer)

  def lease(id, producer) when is_integer(id) and id > 0 and is_pid(producer) do
    with {:ok, _record} <- fetch(id),
         {:ok, pid} <- ensure_box(id),
         :ok <- allow_sandbox(producer, pid),
         {:ok, %Handle{}} = ok <- GenServer.call(pid, {:lease, producer}) do
      ok
    end
  end

  def lease(_, _), do: {:error, :letterbox}

  @spec release(Handle.t()) :: :ok | {:error, atom()}
  def release(%Handle{pid: pid, token: %Token{ref: token}}) do
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
  def command(%Handle{} = handle, :get), do: call(handle, :get)
  def command(%Handle{} = handle, :open_generation), do: call(handle, :open_generation)

  def command(%Handle{} = handle, {:set_stage, stage}) when is_atom(stage) do
    call(handle, {:set_stage, stage})
  end

  def command(%Handle{} = handle, {:set_next, action}) when is_binary(action) do
    call(handle, {:set_next, action})
  end

  def command(%Handle{} = handle, {:tailor, item_id, attrs})
      when is_integer(item_id) and is_map(attrs) do
    call(handle, {:tailor, item_id, attrs})
  end

  @spec id(Handle.t()) :: pos_integer()
  def id(%Handle{id: %Id{value: value}}), do: value

  @spec leased?(pos_integer()) :: boolean()
  def leased?(id) when is_integer(id) do
    Registry.lookup(__MODULE__.Registry, {:leased, id}) != []
  end

  @spec permit_job(pos_integer()) :: :ok | {:error, :leased}
  def permit_job(job_id) when is_integer(job_id) do
    case Registry.lookup(__MODULE__.Registry, {:job, job_id}) do
      [{pid, _}] when pid == self() -> :ok
      [{_pid, _}] -> {:error, :leased}
      [] -> :ok
    end
  end

  @type entry :: %{
          id: pos_integer(),
          job_id: pos_integer(),
          company: String.t(),
          role: String.t(),
          stage: Hireme.Pipeline.stage(),
          batch: String.t() | nil,
          leased: boolean(),
          score_100: Hireme.LifeEv.score(),
          band: Hireme.LifeEv.band()
        }

  @spec list() :: [entry()]
  def list do
    Record
    |> join(:inner, [r], j in Job, on: j.id == r.job_app_id)
    |> join(:left, [r, j], b in Batch, on: b.id == j.batch_id)
    |> order_by([r, j], desc: j.score_100, asc: r.id)
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
    |> Enum.map(fn row ->
      row
      |> Map.put(:leased, leased?(row.id))
      |> Map.put(:band, Hireme.LifeEv.band(row.score_100))
    end)
  end

  defp fetch(id) do
    case Repo.get(Record, id) do
      nil -> {:error, :letterbox}
      record -> {:ok, record}
    end
  end

  defp ensure_box(id) do
    case Registry.lookup(__MODULE__.Registry, {:box, id}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(__MODULE__.Supervisor, {Box, id}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp call(%Handle{pid: pid, token: %Token{ref: token}}, command) do
    GenServer.call(pid, {:cmd, token, command})
  end

  defp allow_sandbox(parent, child) do
    repo = Hireme.Repo

    if repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
      Ecto.Adapters.SQL.Sandbox.allow(repo, parent, child)
    end

    :ok
  end
end
