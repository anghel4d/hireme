defmodule Hireme.Desk.Filters do
  @moduledoc """
  The board's filter, parsed once from the URL and written back to it.

  `from_params/1` never fails: an unknown stage, status, or band falls
  back to the default. `to_query/1` is the inverse and leaves defaults
  out so the URL stays short.

  `min` is the lowest score shown. `band` picks one band of the score
  scale instead; it wins over `min` when both are given.
  """

  alias Hireme.Desk.Job
  alias Hireme.Pipeline
  alias Hireme.Score

  @type t :: %__MODULE__{
          q: String.t(),
          stage: Pipeline.stage() | :all,
          profile: String.t() | :all,
          status: Job.status() | :all,
          batch: String.t() | :leftover | :all,
          min: Score.t() | nil,
          band: Score.band() | :all
        }

  defstruct q: "", stage: :all, profile: :all, status: :open, batch: :all, min: nil, band: :all

  @keys [:q, :stage, :profile, :status, :batch, :min, :band]

  @spec from_params(map()) :: t()
  def from_params(params) when is_map(params) do
    %__MODULE__{
      q: params["q"] || "",
      stage: stage(params["stage"]),
      profile: slug(params["profile"]),
      status: status(params["status"]),
      batch: batch(params["batch"]),
      min: min(params["min"]),
      band: band(params["band"])
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
    |> put("min", filters.min, nil)
    |> put("band", filters.band, :all)
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

  defp min(value) do
    case Score.parse(value) do
      {:ok, score} -> score
      :error -> nil
    end
  end

  defp band(value) do
    case Score.parse_band(value) do
      {:ok, band} -> band
      :error -> :all
    end
  end

  defp put(query, _key, value, value), do: query
  defp put(query, key, value, _default), do: Map.put(query, key, to_string(value))
end
