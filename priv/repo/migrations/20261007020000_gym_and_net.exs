defmodule Hireme.Repo.Migrations.GymAndNet do
  use Ecto.Migration

  def change do
    create table(:gym_problems) do
      add :platform, :string, null: false
      add :slug, :string, null: false
      add :title, :string, null: false, default: ""
      add :topic, :string, null: false, default: "other"
      add :difficulty, :string, null: false, default: "unknown"
      add :url, :string, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:gym_problems, [:platform, :slug])
    create index(:gym_problems, [:topic])

    create table(:gym_reps) do
      add :problem_id, references(:gym_problems, on_delete: :delete_all), null: false
      add :done_on, :date, null: false
      add :minutes, :integer, null: false, default: 0
      add :outcome, :string, null: false, default: "solved"
      add :note, :string, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create index(:gym_reps, [:done_on])
    create index(:gym_reps, [:problem_id, :done_on])

    create table(:net_entries) do
      add :kind, :string, null: false
      add :channel, :string, null: false, default: "other"
      add :title, :string, null: false, default: ""
      add :url, :string, null: false, default: ""
      add :body, :text, null: false, default: ""
      add :shipped_on, :date

      timestamps(type: :utc_datetime)
    end

    create index(:net_entries, [:kind])
    create index(:net_entries, [:shipped_on])
  end
end
