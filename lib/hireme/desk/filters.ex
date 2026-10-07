defmodule Hireme.Desk.Filters do
  @moduledoc """
  The board's filter, parsed once from the URL and written back to it.

  `from_params/1` never fails: an unknown stage or status falls back to
  the default. `to_query/1` is the inverse and leaves defaults out so
  the URL stays short.
  """

  alias Hireme.Desk.Job
  alias Hireme.Pipeline

  @type t :: %__MODULE__{
          q: String.t(),
          stage: Pipeline.stage() | :all,
          profile: String.t() | :all,
          status: Job.status() | :all,
          batch: String.t() | :leftover | :all
        }

  defstruct q: "", stage: :all, profile: :all, status: :open, batch: :all

  @spec from_params(map()) :: t()
  def from_params(params) when is_map(params) do
    %__MODULE__{
      q: params["q"] || "",
      stage: stage(params["stage"]),
      profile: slug(params["profile"]),
      status: status(params["status"]),
      batch: batch(params["batch"])
    }
  end

  @spec merge(t(), map()) :: t()
  def merge(%__MODULE__{} = filters, overrides) when is_map(overrides) do
    struct!(filters, Map.take(overrides, [:q, :stage, :profile, :status, :batch]))
  end

  @spec to_query(t()) :: map()
  def to_query(%__MODULE__{} = filters) do
    %{}
    |> put("q", filters.q, "")
    |> put("stage", filters.stage, :all)
    |> put("profile", filters.profile, :all)
    |> put("status", filters.status, :open)
    |> put("batch", filters.batch, :all)
  end

  @spec stage_value(t()) :: String.t()
  def stage_value(%__MODULE__{stage: :all}), do: "all"
  def stage_value(%__MODULE__{stage: stage}), do: Pipeline.name(stage)

  @spec status_value(t()) :: String.t()
  def status_value(%__MODULE__{status: status}), do: Atom.to_string(status)

  @spec profile_value(t()) :: String.t()
  def profile_value(%__MODULE__{profile: :all}), do: "all"
  def profile_value(%__MODULE__{profile: slug}), do: slug

  @spec batch_value(t()) :: String.t()
  def batch_value(%__MODULE__{batch: :all}), do: "all"
  def batch_value(%__MODULE__{batch: :leftover}), do: "leftover"
  def batch_value(%__MODULE__{batch: code}), do: code

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

  defp put(query, _key, value, value), do: query
  defp put(query, key, value, _default), do: Map.put(query, key, to_string(value))
end
