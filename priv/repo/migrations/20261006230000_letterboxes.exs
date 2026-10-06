defmodule Hireme.Repo.Migrations.Letterboxes do
  use Ecto.Migration

  def up do
    create table(:letterboxes) do
      add :job_app_id, references(:job_apps, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:letterboxes, [:job_app_id])

    flush()

    repo().query!("""
    INSERT INTO letterboxes (job_app_id, inserted_at, updated_at)
    SELECT id, datetime('now'), datetime('now')
    FROM job_apps
    WHERE NOT EXISTS (
      SELECT 1 FROM letterboxes WHERE letterboxes.job_app_id = job_apps.id
    )
    """)
  end

  def down do
    drop table(:letterboxes)
  end
end
