defmodule Hireme.Repo.Migrations.DropLetterboxes do
  use Ecto.Migration

  @moduledoc """
  A letterbox row was the handle an MCP connection leased an application
  by. Agents now lease by job id on their wire session, with the lease
  held by the lane process, so the table records nothing.
  """

  def up do
    drop table(:letterboxes)
  end

  def down do
    create table(:letterboxes) do
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :job_app_id, references(:job_apps, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:letterboxes, [:job_app_id])
  end
end
