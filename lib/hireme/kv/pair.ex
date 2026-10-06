defmodule Hireme.Kv.Pair do
  use Ecto.Schema
  import Ecto.Changeset

  schema "kv_pairs" do
    field :namespace, :string
    field :key, :string
    field :value, :string, default: ""

    timestamps(type: :utc_datetime)
  end

  def changeset(pair, attrs) do
    pair
    |> cast(attrs, [:namespace, :key, :value])
    |> validate_required([:namespace, :key])
    |> unique_constraint([:namespace, :key])
  end
end
