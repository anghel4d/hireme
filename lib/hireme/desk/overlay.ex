defmodule Hireme.Desk.Overlay do
  use Ecto.Schema
  import Ecto.Changeset

  @modes [:hidden, :altered, :emphasized]

  schema "overlays" do
    field :mode, Ecto.Enum, values: @modes
    field :title, :string
    field :body, :string
    field :reason, :string

    belongs_to :job_app, Hireme.Desk.Job
    belongs_to :item, Hireme.Corpus.Item

    timestamps(type: :utc_datetime)
  end

  def modes, do: @modes

  def changeset(overlay, attrs) do
    overlay
    |> cast(attrs, [:job_app_id, :item_id, :mode, :title, :body, :reason])
    |> validate_required([:job_app_id, :item_id, :mode])
    |> unique_constraint([:job_app_id, :item_id])
    |> foreign_key_constraint(:job_app_id)
    |> foreign_key_constraint(:item_id)
  end
end
