defmodule Hireme.Desk.Batch do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "batches" do
    field :code, :string
    field :ordinal, :integer

    field :kind, Ecto.Enum,
      values: [:day_pack, :leftover, :universe_gaps, :linkedin],
      default: :day_pack

    field :status, Ecto.Enum,
      values: [:draft_prep, :fire_ready, :open_fire, :closed],
      default: :draft_prep

    field :fire, Ecto.Enum, values: [:hold, :open_fire], default: :hold
    field :target_size, :integer, default: 55
    field :queued_on, :date
    field :squad, :string, default: ""
    field :variety, :map, default: %{}
    field :note, :string, default: ""

    timestamps(type: :utc_datetime)
  end

  def changeset(batch, attrs) do
    batch
    |> cast(attrs, [
      :code,
      :ordinal,
      :kind,
      :status,
      :fire,
      :target_size,
      :queued_on,
      :squad,
      :variety,
      :note
    ])
    |> validate_required([:code, :ordinal])
    |> unique_constraint(:code)
  end
end
