defmodule Hireme.Pipeline do
  @moduledoc """
  Battleplan. One stage is active.

  Freshness (open/thin/closed/blocked) and the gate (pursue/maybe/skip)
  are fields on the application, not extra rungs. The stage `freshness`
  means a verdict has been recorded. The stage `gated` means the gate
  was chosen. That split is a non-binding hunch: the suggested tokens
  `freshness_open` and `gated/pursue` stay queryable without a
  fifteen-rung rail.

  `open_fire` and `submitted` are refused while the batch is on FIRE HOLD.
  Naming open fire is a human act. This desk does not submit.
  """

  @stages [
    %{key: "discovered", label: "Discovered", hint: "Listing captured"},
    %{key: "freshness", label: "Freshness", hint: "Open, thin, closed, or blocked"},
    %{key: "gated", label: "Gated", hint: "Pursue, maybe, or skip"},
    %{key: "in_batch", label: "In batch", hint: "Named batch"},
    %{key: "draft_ready", label: "Draft ready", hint: "Tailored CV drafted"},
    %{key: "fire_ready", label: "Fire ready", hint: "Packed. Submit stays locked."},
    %{key: "open_fire", label: "Open fire", hint: "Batch named. Submit is allowed."},
    %{key: "submitted", label: "Submitted", hint: "Sent by hand. This desk does not submit."},
    %{key: "reply", label: "Reply", hint: "Reply or interview"},
    %{key: "closed", label: "Closed", hint: "Done"}
  ]

  @rank Map.new(Enum.with_index(@stages), fn {stage, index} -> {stage.key, index} end)

  @fire_locked ~w(open_fire submitted)

  def stages, do: @stages
  def keys, do: Enum.map(@stages, & &1.key)
  def fire_locked?(key), do: key in @fire_locked

  def label(key), do: stage_field(key, :label)
  def hint(key), do: stage_field(key, :hint)
  def rank(key), do: Map.get(@rank, key, 99)
  def key?(key), do: is_map_key(@rank, key)

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
