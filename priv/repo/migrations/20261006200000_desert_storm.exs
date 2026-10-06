defmodule Hireme.Repo.Migrations.DesertStorm do
  use Ecto.Migration

  def change do
    create table(:employers) do
      add :name, :string, null: false
      add :freshness, :string, null: false, default: "unknown"
      add :note, :text, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:employers, [:name])

    create table(:batches) do
      add :code, :string, null: false
      add :ordinal, :integer, null: false
      add :kind, :string, null: false, default: "day_pack"
      add :status, :string, null: false, default: "draft_prep"
      add :fire, :string, null: false, default: "hold"
      add :target_size, :integer, null: false, default: 55
      add :queued_on, :date
      add :squad, :string, null: false, default: ""
      add :variety, :text, null: false, default: "{}"
      add :note, :text, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:batches, [:code])
    create index(:batches, [:queued_on, :status])

    create table(:freshness_verdicts) do
      add :employer_id, references(:employers, on_delete: :nilify_all)
      add :wave, :string, null: false
      add :verdict, :string, null: false
      add :eng_urls, :integer, null: false, default: 0
      add :noted_on, :date
      add :source, :string, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:freshness_verdicts, [:wave, :verdict])

    create table(:claims) do
      add :squad, :string, null: false
      add :slice, :string, null: false
      add :note, :text, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:claims, [:squad, :slice])

    create table(:scoreboard_snapshots) do
      add :noted_on, :date, null: false
      add :leftover_unique, :integer, null: false, default: 0
      add :target_total, :integer, null: false, default: 10000
      add :target_on, :date
      add :daily_batches, :integer, null: false, default: 8
      add :daily_apps, :integer, null: false, default: 440
      add :note, :text, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:scoreboard_snapshots, [:noted_on])

    alter table(:job_apps) do
      add :employer_id, references(:employers, on_delete: :nilify_all)
      add :batch_id, references(:batches, on_delete: :nilify_all)
      add :canonical_url, :string, null: false, default: ""
      add :freshness, :string, null: false, default: "unknown"
      add :gate, :string, null: false, default: "unset"
      add :fit, :string, null: false, default: ""
      add :squad, :string, null: false, default: ""
    end

    create index(:job_apps, [:batch_id])
    create index(:job_apps, [:freshness])
    create index(:job_apps, [:gate])

    create unique_index(:job_apps, [:canonical_url],
             where: "canonical_url != ''",
             name: :job_apps_canonical_url_index
           )
  end
end
