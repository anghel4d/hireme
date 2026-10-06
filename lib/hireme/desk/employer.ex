defmodule Hireme.Desk.Employer do
  use Ecto.Schema
  import Ecto.Changeset

  schema "employers" do
    field :name, :string

    field :freshness, Ecto.Enum,
      values: [:unknown, :open, :thin, :closed, :blocked],
      default: :unknown

    field :note, :string, default: ""

    timestamps(type: :utc_datetime)
  end

  def changeset(employer, attrs) do
    employer
    |> cast(attrs, [:name, :freshness, :note])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
