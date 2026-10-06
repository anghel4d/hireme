defmodule Hireme.Desk.Snapshot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "scoreboard_snapshots" do
    field :noted_on, :date
    field :leftover_unique, :integer, default: 0
    field :target_total, :integer, default: 10_000
    field :target_on, :date
    field :daily_batches, :integer, default: 8
    field :daily_apps, :integer, default: 440
    field :note, :string, default: ""

    timestamps(type: :utc_datetime)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :noted_on,
      :leftover_unique,
      :target_total,
      :target_on,
      :daily_batches,
      :daily_apps,
      :note
    ])
    |> validate_required([:noted_on])
    |> unique_constraint(:noted_on)
  end
end
