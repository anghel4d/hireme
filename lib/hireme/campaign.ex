defmodule Hireme.Campaign.Scoreboard do
  @moduledoc """
  One reading of the desk for one day.
  """

  @enforce_keys [
    :fire,
    :leftover_unique,
    :leftover_noted_on,
    :batches_today,
    :batches_target,
    :apps_today,
    :apps_target,
    :submitted_today,
    :cumulative,
    :target_total,
    :target_on,
    :varieties
  ]
  defstruct @enforce_keys

  @type variety_row :: %{
          code: String.t(),
          fire: :hold | :open_fire,
          status: atom(),
          variety: Hireme.Variety.t(),
          label: String.t()
        }

  @type t :: %__MODULE__{
          fire: :hold | :open_fire,
          leftover_unique: non_neg_integer(),
          leftover_noted_on: Date.t() | nil,
          batches_today: non_neg_integer(),
          batches_target: pos_integer(),
          apps_today: non_neg_integer(),
          apps_target: pos_integer(),
          submitted_today: non_neg_integer(),
          cumulative: non_neg_integer(),
          target_total: pos_integer(),
          target_on: Date.t(),
          varieties: [variety_row()]
        }
end

defmodule Hireme.Campaign do
  @moduledoc """
  Scoreboard for the desk.

  Leftover URL counts come from the latest snapshot. Queued batches, queued
  applications, and submits are counted for the given day.

  Pace is submits against the snapshot's daily target. Hold is the reading
  while every batch is locked. Open fire appears once a batch has been named.
  """

  import Ecto.Query
  alias Hireme.Campaign.Scoreboard
  alias Hireme.Desk.Batch
  alias Hireme.Desk.Job
  alias Hireme.Desk.Snapshot
  alias Hireme.Repo
  alias Hireme.Variety

  @sent [:submitted, :reply]

  @spec scoreboard(Date.t()) :: Scoreboard.t()
  def scoreboard(today \\ Date.utc_today()) do
    snap = latest_snapshot()
    batches = Repo.all(from b in Batch, order_by: b.ordinal)
    queued = Enum.filter(batches, &queued?(&1, today))
    batch_ids = Enum.map(queued, & &1.id)

    %Scoreboard{
      fire: if(Enum.any?(batches, &(&1.fire == :open_fire)), do: :open_fire, else: :hold),
      leftover_unique: (snap && snap.leftover_unique) || 0,
      leftover_noted_on: snap && snap.noted_on,
      batches_today: length(queued),
      batches_target: (snap && snap.daily_batches) || 8,
      apps_today: count_apps(batch_ids),
      apps_target: (snap && snap.daily_apps) || 440,
      submitted_today: submitted(today),
      cumulative: submitted(nil),
      target_total: (snap && snap.target_total) || 10_000,
      target_on: (snap && snap.target_on) || ~D[2026-10-31],
      varieties: Enum.map(batches, &variety_row/1)
    }
  end

  defp latest_snapshot do
    Repo.one(from s in Snapshot, order_by: [desc: s.noted_on], limit: 1)
  end

  defp queued?(%Batch{queued_on: date, status: status}, today) do
    date == today and status in [:fire_ready, :open_fire]
  end

  defp count_apps([]), do: 0

  defp count_apps(ids) do
    Repo.aggregate(from(j in Job, where: j.batch_id in ^ids), :count)
  end

  defp submitted(nil) do
    Repo.aggregate(from(j in Job, where: j.current_stage in ^@sent), :count)
  end

  defp submitted(%Date{} = today) do
    Repo.aggregate(
      from(j in Job, where: j.current_stage in ^@sent and j.stage_on == ^today),
      :count
    )
  end

  defp variety_row(%Batch{} = batch) do
    variety = Variety.from_map(batch.variety)

    %{
      code: batch.code,
      fire: batch.fire,
      status: batch.status,
      variety: variety,
      label: Variety.label(variety)
    }
  end
end
