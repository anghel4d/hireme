defmodule Hireme.Corpus.Item do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds [:experience, :project, :education, :skill, :timeline, :fact]

  @type t :: %__MODULE__{}

  schema "items" do
    field :kind, Ecto.Enum, values: @kinds
    field :key, :string
    field :title, :string
    field :body, :string, default: ""
    field :org, :string, default: ""
    field :span, :string, default: ""
    field :position, :integer, default: 0
    field :keywords, {:array, :string}, default: []

    belongs_to :profile, Hireme.Corpus.Profile

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :profile_id,
      :kind,
      :key,
      :title,
      :body,
      :org,
      :span,
      :position,
      :keywords
    ])
    |> validate_required([:kind, :key, :title, :position])
    |> unique_constraint(:key)
  end
end
