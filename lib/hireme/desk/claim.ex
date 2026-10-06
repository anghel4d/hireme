defmodule Hireme.Desk.Claim do
  use Ecto.Schema
  import Ecto.Changeset

  schema "claims" do
    field :squad, :string
    field :slice, :string
    field :note, :string, default: ""

    timestamps(type: :utc_datetime)
  end

  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [:squad, :slice, :note])
    |> validate_required([:squad, :slice])
    |> unique_constraint([:squad, :slice])
  end
end
