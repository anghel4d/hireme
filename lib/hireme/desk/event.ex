defmodule Hireme.Desk.Event do
  use Ecto.Schema
  import Ecto.Changeset

  schema "events" do
    field :kind, :string
    field :body, :string, default: ""

    belongs_to :job_app, Hireme.Desk.Job

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:job_app_id, :kind, :body])
    |> validate_required([:job_app_id, :kind, :body])
    |> foreign_key_constraint(:job_app_id)
  end
end
