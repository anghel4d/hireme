defmodule Hireme.Desk.Variant do
  use Ecto.Schema
  import Ecto.Changeset

  schema "cv_variants" do
    field :label, :string
    field :theme, :map, default: %{}
    field :note, :string, default: ""

    belongs_to :job_app, Hireme.Desk.Job
    belongs_to :profile, Hireme.Corpus.Profile

    timestamps(type: :utc_datetime)
  end

  def changeset(variant, attrs) do
    variant
    |> cast(attrs, [:job_app_id, :profile_id, :label, :theme, :note])
    |> validate_required([:profile_id, :label])
    |> unique_constraint(:job_app_id)
    |> foreign_key_constraint(:job_app_id)
    |> foreign_key_constraint(:profile_id)
  end
end
