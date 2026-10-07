defmodule Hireme.Repo.Migrations.FoldStagesIntoPips do
  use Ecto.Migration

  # The rail is the pip string: `Pipeline.decode/1` inverts `encode/1`.
  # Only the notes carried information of their own, so they move onto
  # the application as one JSON object and the stages table goes.

  def up do
    alter table(:job_apps) do
      add :stage_notes, :text, null: false, default: "{}"
    end

    flush()

    repo().query!("""
    UPDATE job_apps
    SET stage_notes = (
      SELECT json_group_object(key, note) FROM stages
      WHERE stages.job_app_id = job_apps.id AND note != ''
    )
    WHERE EXISTS (
      SELECT 1 FROM stages WHERE stages.job_app_id = job_apps.id AND note != ''
    )
    """)

    drop table(:stages)
  end

  def down do
    create table(:stages) do
      add :job_app_id, references(:job_apps, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :position, :integer, null: false
      add :state, :string, null: false
      add :note, :text, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:stages, [:job_app_id, :key])

    alter table(:job_apps) do
      remove :stage_notes
    end
  end
end
