defmodule Hireme.Corpus.Profile do
  use Ecto.Schema
  import Ecto.Changeset

  schema "profiles" do
    field :slug, :string
    field :name, :string
    field :headline, :string
    field :summary, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:slug, :name, :headline, :summary])
    |> validate_required([:slug, :name, :headline, :summary])
    |> unique_constraint(:slug)
  end
end
