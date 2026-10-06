defmodule Hireme.Campaign do
  @moduledoc """
  Scoreboard for the desk.

  Leftover URL counts come from the latest snapshot. Queued batches, queued
  applications, and submits are counted for the given day.

  Pace is submits against the snapshot's daily target. Hold is the reading
  while every batch is locked. Open fire appears once a batch has been named.
  """

  import Ecto.Query
  alias Hireme.Desk.Batch
  alias Hireme.Desk.Job
  alias Hireme.Desk.Snapshot
  alias Hireme.Repo
  alias Hireme.Variety

  @name "Desk"

  def name, do: @name

  def scoreboard(today \\ Date.utc_today()) do
    snap = latest_snapshot()
    batches = Repo.all(from b in Batch, order_by: b.ordinal)
    queued = Enum.filter(batches, &queued?(&1, today))
    batch_ids = Enum.map(queued, & &1.id)

    %{
      name: @name,
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

  defp queued?(%{queued_on: date, status: status}, today) do
    date == today and status in [:fire_ready, :open_fire]
  end

  defp count_apps([]), do: 0

  defp count_apps(ids) do
    Repo.aggregate(from(j in Job, where: j.batch_id in ^ids), :count)
  end

  defp submitted(nil) do
    Repo.aggregate(from(j in Job, where: j.current_stage in ["submitted", "reply"]), :count)
  end

  defp submitted(today) do
    Repo.aggregate(
      from(j in Job,
        where: j.current_stage in ["submitted", "reply"] and j.stage_on == ^today
      ),
      :count
    )
  end

  defp variety_row(batch) do
    variety = batch.variety || %{}
    flags = Map.get(variety, "flags", [])
    apps = Map.get(variety, "apps", 0)

    label =
      if flags == [] and apps == 0 do
        "unfilled"
      else
        Variety.label(%{"flags" => flags})
      end

    %{
      code: batch.code,
      fire: batch.fire,
      status: batch.status,
      flags: flags,
      label: label,
      apps: apps
    }
  end
end
