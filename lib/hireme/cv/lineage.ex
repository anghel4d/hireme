defmodule Hireme.Cv.Lineage do
  @moduledoc """
  The one CV for an employer. Applications do not carry a free-floating variant.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "cv_lineages" do
    field :generation, :integer, default: 1
    field :opened_on, :date
    field :rewrites_allowed, :boolean, default: true
    field :theme, :map, default: %{}

    belongs_to :employer, Hireme.Desk.Employer

    timestamps(type: :utc_datetime)
  end

  def changeset(lineage, attrs) do
    lineage
    |> cast(attrs, [:employer_id, :generation, :opened_on, :rewrites_allowed, :theme])
    |> validate_required([:employer_id, :generation, :opened_on])
    |> unique_constraint(:employer_id)
    |> foreign_key_constraint(:employer_id)
  end
end
