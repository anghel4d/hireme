defmodule Hireme.Gym.Problem do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "gym_problems" do
    field :platform, Ecto.Enum, values: [:leetcode, :codeforces, :other]
    field :slug, :string
    field :title, :string, default: ""

    field :topic, Ecto.Enum,
      values: [:arrays, :graphs, :strings, :dp, :trees, :systems, :other],
      default: :other

    field :difficulty, Ecto.Enum, values: [:easy, :medium, :hard, :unknown], default: :unknown
    field :url, :string, default: ""

    has_many :reps, Hireme.Gym.Rep

    timestamps(type: :utc_datetime)
  end

  def changeset(problem, attrs) do
    problem
    |> cast(attrs, [:platform, :slug, :title, :topic, :difficulty, :url])
    |> validate_required([:platform, :slug, :title])
    |> unique_constraint([:platform, :slug])
  end
end
