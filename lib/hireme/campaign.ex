defmodule Hireme.Variety do
  @moduledoc """
  A day pack is 55 apps that are not 55 copies of one role.

  Flags are non-binding. An empty batch is `:unfilled`. A short pack is
  `:short`. A pack of twenty or more with a narrow mix picks up
  `:few_companies`, `:few_locations`, or `:few_fits`.

  The batch row stores the summary as JSON. `to_map/1` and `from_map/1`
  are the inverse pair for that column.
  """

  alias Hireme.Closed

  @flags [:unfilled, :short, :few_companies, :few_locations, :few_fits]
  @counts [:apps, :companies, :roles, :locations, :fits]
  @narrow [{:few_companies, :company, 8}, {:few_locations, :location, 3}, {:few_fits, :fit, 3}]

  @type flag :: :unfilled | :short | :few_companies | :few_locations | :few_fits

  defstruct apps: 0, companies: 0, roles: 0, locations: 0, fits: 0, flags: []

  @type t :: %__MODULE__{
          apps: non_neg_integer(),
          companies: non_neg_integer(),
          roles: non_neg_integer(),
          locations: non_neg_integer(),
          fits: non_neg_integer(),
          flags: [flag()]
        }

  @type app :: %{
          required(:company) => String.t() | nil,
          required(:role) => String.t() | nil,
          required(:location) => String.t() | nil,
          required(:fit) => String.t() | nil
        }

  @spec flags() :: [flag()]
  def flags, do: @flags

  @spec summarize([app()], pos_integer()) :: t()
  def summarize(apps, target \\ 55) when is_list(apps) do
    n = length(apps)

    size =
      cond do
        n == 0 -> [:unfilled]
        n < target -> [:short]
        true -> []
      end

    mix = for {flag, key, floor} <- @narrow, n >= 20 and uniq(apps, key) < floor, do: flag

    %__MODULE__{
      apps: n,
      companies: uniq(apps, :company),
      roles: uniq(apps, :role),
      locations: uniq(apps, :location),
      fits: uniq(apps, :fit),
      flags: size ++ mix
    }
  end

  @spec label(t()) :: String.t()
  def label(%__MODULE__{apps: 0}), do: "unfilled"
  def label(%__MODULE__{flags: []}), do: "varied"
  def label(%__MODULE__{flags: flags}), do: Enum.map_join(flags, ", ", &Atom.to_string/1)

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = variety) do
    @counts
    |> Map.new(&{Atom.to_string(&1), Map.fetch!(variety, &1)})
    |> Map.put("flags", Enum.map(variety.flags, &Atom.to_string/1))
  end

  @spec from_map(map() | nil) :: t()
  def from_map(nil), do: %__MODULE__{}
  def from_map(%__MODULE__{} = variety), do: variety

  def from_map(map) when is_map(map) do
    flags =
      Enum.flat_map(List.wrap(map["flags"]), fn flag ->
        case Closed.parse(@flags, flag) do
          {:ok, known} -> [known]
          :error -> []
        end
      end)

    counts = Map.new(@counts, &{&1, count(map[Atom.to_string(&1)])})
    struct!(__MODULE__, Map.put(counts, :flags, flags))
  end

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_), do: 0

  defp uniq(apps, key) do
    apps
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> length()
  end
end

defmodule Hireme.Campaign.Scoreboard do
  @moduledoc "One reading of the desk for one day."

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
    :varieties,
    :chart
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
          varieties: [variety_row()],
          chart: Hireme.LifeEv.Chart.t()
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
    # With no snapshot yet, the row's own defaults are the targets.
    snap = Repo.one(from s in Snapshot, order_by: [desc: s.noted_on], limit: 1) || %Snapshot{}
    batches = Repo.all(from b in Batch, order_by: b.ordinal)

    queued =
      Enum.filter(batches, &(&1.queued_on == today and &1.status in [:fire_ready, :open_fire]))

    %Scoreboard{
      fire: if(Enum.any?(batches, &(&1.fire == :open_fire)), do: :open_fire, else: :hold),
      leftover_unique: snap.leftover_unique,
      leftover_noted_on: snap.noted_on,
      batches_today: length(queued),
      batches_target: snap.daily_batches,
      apps_today: count_apps(Enum.map(queued, & &1.id)),
      apps_target: snap.daily_apps,
      submitted_today: submitted(today),
      cumulative: submitted(nil),
      target_total: snap.target_total,
      target_on: snap.target_on || ~D[2026-10-31],
      varieties: Enum.map(batches, &variety_row/1),
      chart: Hireme.Desk.score_chart()
    }
  end

  defp count_apps([]), do: 0
  defp count_apps(ids), do: Repo.aggregate(from(j in Job, where: j.batch_id in ^ids), :count)

  defp submitted(nil),
    do: Repo.aggregate(from(j in Job, where: j.current_stage in ^@sent), :count)

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
