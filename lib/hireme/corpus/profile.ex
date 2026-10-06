defmodule Hireme.Corpus.Profile do
  use Ecto.Schema
  import Ecto.Changeset

  schema "profiles" do
    field :slug, :string
    field :name, :string
    field :headline, :string
    field :summary, :string

    belongs_to :user, Hireme.Corpus.User

    timestamps(type: :utc_datetime)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:slug, :name, :headline, :summary, :user_id])
    |> validate_required([:slug, :name, :headline, :summary])
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:user_id)
  end
end
