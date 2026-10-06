defmodule Hireme.Desk.FreshnessVerdict do
  use Ecto.Schema
  import Ecto.Changeset

  schema "freshness_verdicts" do
    field :wave, :string
    field :verdict, Ecto.Enum, values: [:open, :thin, :closed, :blocked]
    field :eng_urls, :integer, default: 0
    field :noted_on, :date
    field :source, :string, default: ""

    belongs_to :employer, Hireme.Desk.Employer

    timestamps(type: :utc_datetime)
  end

  def changeset(verdict, attrs) do
    verdict
    |> cast(attrs, [:employer_id, :wave, :verdict, :eng_urls, :noted_on, :source])
    |> validate_required([:wave, :verdict])
    |> unique_constraint([:wave, :verdict])
  end
end
