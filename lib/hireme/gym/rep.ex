defmodule Hireme.Gym.Rep do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "gym_reps" do
    field :done_on, :date
    field :minutes, :integer, default: 0
    field :outcome, Ecto.Enum, values: [:solved, :attempt, :skip], default: :solved
    field :note, :string, default: ""

    belongs_to :problem, Hireme.Gym.Problem

    timestamps(type: :utc_datetime)
  end

  def changeset(rep, attrs) do
    rep
    |> cast(attrs, [:problem_id, :done_on, :minutes, :outcome, :note])
    |> validate_required([:problem_id, :done_on, :outcome])
    |> validate_number(:minutes, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:problem_id)
  end
end
