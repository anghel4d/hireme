defmodule Hireme.Desk.Filters do
  @moduledoc """
  The board's filter, parsed once from the URL and written back to it.

  `from_params/1` never fails: an unknown stage, status, or band falls
  back to the default. `to_query/1` is the inverse and leaves defaults
  out so the URL stays short.

  `min_score` is the lowest `score_100` shown. `band` picks one band of
  the Life-EV ladder; both apply when both are given. `heat` is company
  load after the governor paints the card (`cool` / `warm` / `hot` /
  `blocked`); it is not a SQL column.
  """

  alias Hireme.Desk.Job
  alias Hireme.Heat
  alias Hireme.LifeEv
  alias Hireme.Pipeline

  @type t :: %__MODULE__{
          q: String.t(),
          stage: Pipeline.stage() | :all,
          profile: String.t() | :all,
          status: Job.status() | :all,
          batch: String.t() | :leftover | :all,
          min_score: LifeEv.score(),
          band: LifeEv.band() | :all,
          heat: :all | :cool | :warm | :hot | :blocked
        }

  defstruct q: "",
            stage: :all,
            profile: :all,
            status: :open,
            batch: :all,
            min_score: 0,
            band: :all,
            heat: :all

  @keys [:q, :stage, :profile, :status, :batch, :min_score, :band, :heat]

  @spec from_params(map()) :: t()
  def from_params(params) when is_map(params) do
    %__MODULE__{
      q: params["q"] || "",
      stage: stage(params["stage"]),
      profile: slug(params["profile"]),
      status: status(params["status"]),
      batch: batch(params["batch"]),
      min_score: min_score(params["min_score"]),
      band: band(params["band"]),
      heat: heat(params["heat"])
    }
  end

  @spec merge(t(), map()) :: t()
  def merge(%__MODULE__{} = filters, overrides) when is_map(overrides) do
    struct!(filters, Map.take(overrides, @keys))
  end

  @spec to_query(t()) :: map()
  def to_query(%__MODULE__{} = filters) do
    %{}
    |> put("q", filters.q, "")
    |> put("stage", filters.stage, :all)
    |> put("profile", filters.profile, :all)
    |> put("status", filters.status, :open)
    |> put("batch", filters.batch, :all)
    |> put("min_score", filters.min_score, 0)
    |> put("band", filters.band, :all)
    |> put("heat", filters.heat, :all)
  end

  defp stage(value) do
    case Pipeline.parse(value) do
      {:ok, stage} -> stage
      :error -> :all
    end
  end

  defp status("all"), do: :all

  defp status(value) do
    case Job.parse_status(value) do
      {:ok, status} -> status
      :error -> :open
    end
  end

  defp slug(value) when is_binary(value) and value not in ["", "all"], do: value
  defp slug(_), do: :all

  defp batch("leftover"), do: :leftover
  defp batch(value) when is_binary(value) and value not in ["", "all"], do: value
  defp batch(_), do: :all

  defp min_score(n) when is_integer(n), do: LifeEv.clamp(n)

  defp min_score(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> LifeEv.clamp(n)
      _ -> 0
    end
  end

  defp min_score(_), do: 0

  defp band(value) do
    case LifeEv.parse_band(value) do
      {:ok, band} -> band
      :error -> :all
    end
  end

  defp heat(value) do
    case Heat.parse_state(value) do
      {:ok, state} -> state
      :error -> :all
    end
  end

  defp put(query, _key, value, value), do: query
  defp put(query, key, value, _default), do: Map.put(query, key, to_string(value))
end
