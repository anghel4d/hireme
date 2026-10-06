defmodule Hireme.Desk.Job do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:open, :paused, :hired, :closed]

  schema "job_apps" do
    field :company, :string
    field :role, :string
    field :location, :string, default: ""
    field :listing_url, :string, default: ""
    field :listing, :string, default: ""
    field :heat, :integer, default: 3
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :next_action, :string, default: ""
    field :next_due, :date
    field :source, :string, default: ""
    field :stage_on, :date
    field :current_stage, :string
    field :pips, :string, default: "APPPPPPP"
    field :keyword_hits, :integer, default: 0
    field :keyword_total, :integer, default: 0
    field :mask_hidden, :integer, default: 0
    field :mask_altered, :integer, default: 0
    field :mask_emphasized, :integer, default: 0

    belongs_to :profile, Hireme.Corpus.Profile

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :profile_id,
      :company,
      :role,
      :location,
      :listing_url,
      :listing,
      :heat,
      :status,
      :next_action,
      :next_due,
      :source,
      :stage_on,
      :current_stage,
      :pips,
      :keyword_hits,
      :keyword_total,
      :mask_hidden,
      :mask_altered,
      :mask_emphasized
    ])
    |> validate_required([:profile_id, :company, :role, :heat, :status, :current_stage, :pips])
    |> validate_number(:heat, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> validate_inclusion(:current_stage, Hireme.Pipeline.keys())
    |> foreign_key_constraint(:profile_id)
  end
end
