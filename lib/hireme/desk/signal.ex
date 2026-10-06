defmodule Hireme.Desk.Signal do
  @moduledoc """
  One change on the desk, broadcast on the `"desk"` topic as
  `{:desk_event, %Signal{}}`.

  `kind` is the closed set of things that can change. `job_id` is set for
  every change to one application and nil for a batch-level change, so a
  letterbox can match its own application with one field.
  """

  @kinds [:application_opened, :stage, :cv, :open_fire]

  @type kind :: :application_opened | :stage | :cv | :open_fire

  @enforce_keys [:kind]
  defstruct [:kind, :job_id, :lineage_id, :stage, :batch]

  @type t :: %__MODULE__{
          kind: kind(),
          job_id: pos_integer() | nil,
          lineage_id: pos_integer() | nil,
          stage: Hireme.Pipeline.stage() | nil,
          batch: String.t() | nil
        }

  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @spec application_opened(pos_integer(), pos_integer()) :: t()
  def application_opened(job_id, lineage_id) do
    %__MODULE__{kind: :application_opened, job_id: job_id, lineage_id: lineage_id}
  end

  @spec stage(pos_integer(), Hireme.Pipeline.stage()) :: t()
  def stage(job_id, stage), do: %__MODULE__{kind: :stage, job_id: job_id, stage: stage}

  @spec cv(pos_integer(), pos_integer()) :: t()
  def cv(job_id, lineage_id), do: %__MODULE__{kind: :cv, job_id: job_id, lineage_id: lineage_id}

  @spec open_fire(String.t()) :: t()
  def open_fire(batch), do: %__MODULE__{kind: :open_fire, batch: batch}

  @spec about?(t(), pos_integer()) :: boolean()
  def about?(%__MODULE__{job_id: job_id}, job_id) when is_integer(job_id), do: true
  def about?(%__MODULE__{}, _job_id), do: false

  @doc """
  The wire shape. Nil fields are left out.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = signal) do
    %{"type" => Atom.to_string(signal.kind)}
    |> put("job_id", signal.job_id)
    |> put("lineage_id", signal.lineage_id)
    |> put("stage", signal.stage && Atom.to_string(signal.stage))
    |> put("batch", signal.batch)
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
