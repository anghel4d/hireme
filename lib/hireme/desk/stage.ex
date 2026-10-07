defmodule Hireme.Desk.Stage do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hireme.Pipeline
  alias Hireme.Pipeline.Rung

  schema "stages" do
    field :key, Ecto.Enum, values: Pipeline.keys()
    field :position, :integer
    field :state, Ecto.Enum, values: Pipeline.pips()
    field :note, :string, default: ""

    belongs_to :job_app, Hireme.Desk.Job

    timestamps(type: :utc_datetime)
  end

  def changeset(stage, attrs) do
    stage
    |> cast(attrs, [:job_app_id, :key, :position, :state, :note])
    |> validate_required([:job_app_id, :key, :position, :state])
    |> unique_constraint([:job_app_id, :key])
    |> foreign_key_constraint(:job_app_id)
  end

  @spec to_rung(%__MODULE__{}) :: Rung.t()
  def to_rung(%__MODULE__{} = stage) do
    %Rung{key: stage.key, position: stage.position, state: stage.state, note: stage.note || ""}
  end

  @spec from_rung(Rung.t(), pos_integer()) :: map()
  def from_rung(%Rung{} = rung, job_id) do
    %{
      job_app_id: job_id,
      key: rung.key,
      position: rung.position,
      state: rung.state,
      note: rung.note
    }
  end
end
