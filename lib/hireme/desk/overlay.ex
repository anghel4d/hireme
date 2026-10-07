defmodule Hireme.Desk.Overlay do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hireme.Mask

  schema "overlays" do
    field :mode, Ecto.Enum, values: Mask.modes()
    field :title, :string
    field :body, :string
    field :reason, :string
    field :generation, :integer, default: 1

    belongs_to :job_app, Hireme.Desk.Job
    belongs_to :item, Hireme.Corpus.Item
    belongs_to :lineage, Hireme.Cv.Lineage

    timestamps(type: :utc_datetime)
  end

  @doc """
  One overlay mode from the wire. `inherit` is the absence of an overlay
  and is parsed by the caller that drops a line.
  """
  @spec parse_mode(term()) :: {:ok, :hidden | :altered | :emphasized} | :error
  def parse_mode(mode) when mode in [:hidden, :altered, :emphasized], do: {:ok, mode}

  def parse_mode(name) when is_binary(name) do
    case Enum.find(Mask.modes(), &(Atom.to_string(&1) == name)) do
      nil -> :error
      mode -> {:ok, mode}
    end
  end

  def parse_mode(_), do: :error

  def changeset(overlay, attrs) do
    overlay
    |> cast(attrs, [
      :job_app_id,
      :item_id,
      :lineage_id,
      :mode,
      :title,
      :body,
      :reason,
      :generation
    ])
    |> validate_required([:job_app_id, :item_id, :lineage_id, :mode])
    |> unique_constraint([:job_app_id, :item_id])
    |> unique_constraint([:lineage_id, :item_id])
    |> foreign_key_constraint(:job_app_id)
    |> foreign_key_constraint(:item_id)
  end
end
