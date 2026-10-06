defmodule Hireme.Corpus.Narrative do
  @moduledoc """
  Private memory for one candidate.

  This is not a CV section and not an overlay. Application export leaves it out
  while `private` is true, which is the default.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "narratives" do
    field :body, :string, default: ""
    field :version, :integer, default: 1
    field :private, :boolean, default: true

    belongs_to :user, Hireme.Corpus.User

    timestamps(type: :utc_datetime)
  end

  def changeset(narrative, attrs) do
    narrative
    |> cast(attrs, [:user_id, :body, :version, :private])
    |> validate_required([:user_id, :body, :version])
    |> validate_number(:version, greater_than: 0)
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
  end
end
