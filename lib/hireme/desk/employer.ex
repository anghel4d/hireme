defmodule Hireme.Desk.Employer do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "employers" do
    field :name, :string

    field :freshness, Ecto.Enum,
      values: [:unknown, :open, :thin, :closed, :blocked],
      default: :unknown

    field :note, :string, default: ""
    field :score_100, :integer, default: 50

    timestamps(type: :utc_datetime)
  end

  def changeset(employer, attrs) do
    employer
    |> cast(attrs, [:name, :freshness, :note, :score_100])
    |> validate_required([:name])
    |> validate_number(:score_100, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> unique_constraint(:name)
  end
end
