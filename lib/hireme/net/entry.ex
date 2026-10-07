defmodule Hireme.Net.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "net_entries" do
    field :kind, Ecto.Enum, values: [:observer, :artifact, :post, :draft]
    field :channel, Ecto.Enum, values: [:broadside, :x, :other], default: :other
    field :title, :string, default: ""
    field :url, :string, default: ""
    field :body, :string, default: ""
    field :shipped_on, :date

    timestamps(type: :utc_datetime)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:kind, :channel, :title, :url, :body, :shipped_on])
    |> validate_required([:kind, :channel, :title])
  end
end
