defmodule Hireme.Repo.Migrations.ScoreApplications do
  use Ecto.Migration

  def change do
    alter table(:job_apps) do
      add :score, :integer
    end

    create index(:job_apps, [:score])
  end
end
