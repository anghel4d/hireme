defmodule Hireme.Repo.Migrations.AddScore100 do
  use Ecto.Migration

  def change do
    alter table(:job_apps) do
      add :score_100, :integer, null: false, default: 50
    end

    alter table(:employers) do
      add :score_100, :integer, null: false, default: 50
    end

    create index(:job_apps, [:score_100])
    create index(:employers, [:score_100])
  end
end
