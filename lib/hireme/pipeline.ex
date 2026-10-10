defmodule Hireme.Pipeline.Rung do
  @moduledoc """
  One rung of the battleplan for one application.
  """

  @enforce_keys [:key, :position, :state]
  defstruct [:key, :position, :state, note: ""]

  @type t :: %__MODULE__{
          key: Hireme.Pipeline.stage(),
          position: non_neg_integer(),
          state: Hireme.Pipeline.pip(),
          note: String.t()
        }
end

defmodule Hireme.Pipeline do
  @moduledoc """
  Battleplan. One stage is active.

  Stage keys and pip states are closed sets of atoms. Strings from the
  wire, the URL, or a JSON pack go through `parse/1` once. Inside the
  desk a stage is always one of `stages/0` and a pip is always one of
  `pips/0`, so an unknown value has no representation past the edge.

  `encode/1` and `decode/1` are inverse on well-formed rails. A rail is
  one rung per stage, in order.

  Freshness (open/thin/closed/blocked) and the gate (pursue/maybe/skip)
  are fields on the application, not extra rungs. `open_fire` and
  `submitted` are refused while the batch is on FIRE HOLD. Naming open
  fire is a human act. This desk does not submit.
  """

  alias Hireme.Pipeline.Rung

  @type stage ::
          :discovered
          | :freshness
          | :gated
          | :in_batch
          | :draft_ready
          | :fire_ready
          | :open_fire
          | :submitted
          | :reply
          | :closed

  @type pip :: :done | :active | :pending | :skipped | :blocked

  @type rail :: [Rung.t()]

  @stages [
    %{key: :discovered, label: "Discovered", hint: "Listing captured"},
    %{key: :freshness, label: "Freshness", hint: "Open, thin, closed, or blocked"},
    %{key: :gated, label: "Gated", hint: "Pursue, maybe, or skip"},
    %{key: :in_batch, label: "In batch", hint: "Named batch"},
    %{key: :draft_ready, label: "Draft ready", hint: "Tailored CV drafted"},
    %{key: :fire_ready, label: "Fire ready", hint: "Packed. Submit stays locked."},
    %{key: :open_fire, label: "Open fire", hint: "Batch named. Submit is allowed."},
    %{key: :submitted, label: "Submitted", hint: "Sent by hand. This desk does not submit."},
    %{key: :reply, label: "Reply", hint: "Reply or interview"},
    %{key: :closed, label: "Closed", hint: "Done"}
  ]

  @keys Enum.map(@stages, & &1.key)
  @rank Map.new(Enum.with_index(@keys))
  @by_key Map.new(@stages, &{&1.key, &1})

  @pips [:done, :active, :pending, :skipped, :blocked]
  @pip_chars %{done: "D", active: "A", pending: "P", skipped: "S", blocked: "B"}
  @char_pips Map.new(@pip_chars, fn {pip, char} -> {char, pip} end)

  @fire_locked [:open_fire, :submitted]

  @spec stages() :: [%{key: stage(), label: String.t(), hint: String.t()}]
  def stages, do: @stages

  @spec keys() :: [stage()]
  def keys, do: @keys

  @spec fire_locked?(stage()) :: boolean()
  def fire_locked?(key) when key in @keys, do: key in @fire_locked

  @doc """
  One stage from the wire. Accepts the atom itself or its name.
  """
  @spec parse(term()) :: {:ok, stage()} | :error
  def parse(value), do: Hireme.Closed.parse(@keys, value)

  @spec parse!(term()) :: stage()
  def parse!(value) do
    case parse(value) do
      {:ok, stage} -> stage
      :error -> raise ArgumentError, "unknown stage #{inspect(value)}"
    end
  end

  @spec name(stage()) :: String.t()
  def name(key) when key in @keys, do: Atom.to_string(key)

  @spec label(stage()) :: String.t()
  def label(key) when key in @keys, do: Map.fetch!(@by_key, key).label

  @spec rank(stage()) :: non_neg_integer()
  def rank(key) when key in @keys, do: Map.fetch!(@rank, key)

  @spec initial(stage()) :: rail()
  def initial(active) when active in @keys do
    idx = rank(active)

    Enum.with_index(@keys, fn key, i ->
      state =
        cond do
          i < idx -> :done
          i == idx -> :active
          true -> :pending
        end

      %Rung{key: key, position: i, state: state}
    end)
  end

  @spec move_to(rail(), stage()) :: rail()
  def move_to(rail, key) when key in @keys do
    idx = rank(key)

    Enum.map(rail, fn %Rung{} = rung ->
      i = rank(rung.key)

      state =
        cond do
          rung.key == key -> :active
          rung.state in [:skipped, :blocked] -> rung.state
          i < idx -> :done
          true -> :pending
        end

      %Rung{rung | state: state}
    end)
  end

  @spec current(rail()) :: Rung.t() | nil
  def current(rail) do
    Enum.find(rail, &(&1.state == :active)) ||
      Enum.find(rail, &(&1.state == :pending)) ||
      List.last(rail)
  end

  @doc """
  The rail as one character per rung, in position order.
  """
  @spec encode(rail()) :: String.t()
  def encode(rail) do
    rail
    |> Enum.sort_by(& &1.position)
    |> Enum.map_join(&char/1)
  end

  @doc """
  The rail a pip string describes. One character per stage, in order.
  Notes are not part of the encoding and come back empty.
  """
  @spec decode(String.t()) :: {:ok, rail()} | :error
  def decode(pips) when is_binary(pips) do
    chars = String.graphemes(pips)

    if length(chars) == length(@keys) and Enum.all?(chars, &is_map_key(@char_pips, &1)) do
      rail =
        Enum.zip_with(Enum.with_index(@keys), chars, fn {key, i}, char ->
          %Rung{key: key, position: i, state: Map.fetch!(@char_pips, char)}
        end)

      {:ok, rail}
    else
      :error
    end
  end

  @spec char(Rung.t() | pip()) :: String.t()
  defp char(%Rung{state: state}), do: char(state)
  defp char(pip) when pip in @pips, do: Map.fetch!(@pip_chars, pip)
end
