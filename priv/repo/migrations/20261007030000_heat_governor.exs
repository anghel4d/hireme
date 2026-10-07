defmodule Hireme.Repo.Migrations.HeatGovernor do
  use Ecto.Migration

  def change do
    alter table(:job_apps) do
      add :department, :string, null: false, default: ""
      add :heat_override, :boolean, null: false, default: false
      add :heat_override_reason, :string, null: false, default: ""
    end
  end
end
