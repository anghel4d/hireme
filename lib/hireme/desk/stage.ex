defmodule Hireme.Desk.Stage do
  use Ecto.Schema
  import Ecto.Changeset

  @states [:pending, :active, :done, :skipped, :blocked]

  schema "stages" do
    field :key, :string
    field :position, :integer
    field :state, Ecto.Enum, values: @states
    field :note, :string, default: ""

    belongs_to :job_app, Hireme.Desk.Job

    timestamps(type: :utc_datetime)
  end

  def states, do: @states

  def changeset(stage, attrs) do
    stage
    |> cast(attrs, [:job_app_id, :key, :position, :state, :note])
    |> validate_required([:job_app_id, :key, :position, :state])
    |> validate_inclusion(:key, Hireme.Pipeline.keys())
    |> unique_constraint([:job_app_id, :key])
    |> foreign_key_constraint(:job_app_id)
  end
end
