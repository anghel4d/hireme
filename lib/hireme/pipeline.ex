defmodule Hireme.Pipeline do
  @moduledoc """
  The battleplan. Eight stages, one of them active.

  Earlier stages are done, later stages are pending. `:skipped` and
  `:blocked` stay where a person put them, unless that stage is the one
  being activated.
  """

  @stages [
    %{key: "recon", label: "Recon", hint: "Listing captured"},
    %{key: "fit", label: "Fit", hint: "Profile and gaps"},
    %{key: "tailor", label: "Tailor", hint: "CV variant and masks"},
    %{key: "submit", label: "Submit", hint: "Application sent"},
    %{key: "screen", label: "Screen", hint: "Recruiter or ATS"},
    %{key: "loop", label: "Loop", hint: "Interviews"},
    %{key: "offer", label: "Offer", hint: "Negotiation"},
    %{key: "close", label: "Close", hint: "Decision"}
  ]

  @rank Map.new(Enum.with_index(@stages), fn {stage, index} -> {stage.key, index} end)

  def stages, do: @stages
  def keys, do: Enum.map(@stages, & &1.key)

  def label(key), do: stage_field(key, :label)
  def hint(key), do: stage_field(key, :hint)
  def rank(key), do: Map.get(@rank, key, 99)

  def key?(key), do: is_map_key(@rank, key)

  @doc """
  A fresh campaign with `active` as the current stage.
  """
  def initial(active) when is_binary(active) do
    idx = rank(active)

    Enum.with_index(keys(), fn key, i ->
      state =
        cond do
          i < idx -> :done
          i == idx -> :active
          true -> :pending
        end

      %{key: key, position: i, state: state, note: ""}
    end)
  end

  @doc """
  Move the active stage to `key`. Returns the stages with updated `:state`.
  """
  def move_to(stages, key) when is_binary(key) do
    idx = rank(key)

    Enum.map(stages, fn stage ->
      i = rank(stage.key)

      state =
        cond do
          stage.key == key -> :active
          stage.state in [:skipped, :blocked] -> stage.state
          i < idx -> :done
          true -> :pending
        end

      %{stage | state: state}
    end)
  end

  def current(stages) do
    Enum.find(stages, &(&1.state == :active)) ||
      Enum.find(stages, &(&1.state == :pending)) ||
      List.last(stages)
  end

  def encode(stages) do
    stages
    |> Enum.sort_by(& &1.position)
    |> Enum.map_join(&char/1)
  end

  def char(%{state: state}), do: char(state)
  def char(:done), do: "D"
  def char(:active), do: "A"
  def char(:pending), do: "P"
  def char(:skipped), do: "S"
  def char(:blocked), do: "B"
  def char(_), do: "?"

  defp stage_field(key, field) do
    case Enum.find(@stages, &(&1.key == key)) do
      nil -> key
      stage -> Map.fetch!(stage, field)
    end
  end
end
