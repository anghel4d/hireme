defmodule Hireme.Desk.Job do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:open, :paused, :hired, :closed]

  @type status :: :open | :paused | :hired | :closed
  @type t :: %__MODULE__{}

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
    field :current_stage, Ecto.Enum, values: Hireme.Pipeline.keys()
    field :pips, :string, default: Hireme.Pipeline.encode(Hireme.Pipeline.initial(:discovered))
    field :stage_notes, :map, default: %{}
    field :keyword_hits, :integer, default: 0
    field :keyword_total, :integer, default: 0
    field :mask_hidden, :integer, default: 0
    field :mask_altered, :integer, default: 0
    field :mask_emphasized, :integer, default: 0
    field :canonical_url, :string, default: ""

    field :freshness, Ecto.Enum,
      values: [:unknown, :open, :thin, :closed, :blocked],
      default: :unknown

    field :gate, Ecto.Enum, values: [:unset, :pursue, :maybe, :skip], default: :unset
    field :fit, :string, default: ""
    field :squad, :string, default: ""

    belongs_to :profile, Hireme.Corpus.Profile
    belongs_to :employer, Hireme.Desk.Employer
    belongs_to :batch, Hireme.Desk.Batch

    timestamps(type: :utc_datetime)
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec parse_status(term()) :: {:ok, status()} | :error
  def parse_status(status) when status in @statuses, do: {:ok, status}

  def parse_status(name) when is_binary(name) do
    case Enum.find(@statuses, &(Atom.to_string(&1) == name)) do
      nil -> :error
      status -> {:ok, status}
    end
  end

  def parse_status(_), do: :error

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
      :stage_notes,
      :keyword_hits,
      :keyword_total,
      :mask_hidden,
      :mask_altered,
      :mask_emphasized,
      :canonical_url,
      :freshness,
      :gate,
      :fit,
      :squad,
      :employer_id,
      :batch_id
    ])
    |> validate_required([:profile_id, :company, :role, :heat, :status, :current_stage, :pips])
    |> validate_number(:heat, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> validate_length(:pips, is: length(Hireme.Pipeline.keys()))
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:batch_id)
    |> foreign_key_constraint(:employer_id)
    |> unique_constraint(:canonical_url)
  end
end
