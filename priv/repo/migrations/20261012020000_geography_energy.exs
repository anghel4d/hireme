defmodule Hireme.Repo.Migrations.GeographyEnergy do
  use Ecto.Migration

  @moduledoc """
  Primary energy use per person, as a figure and the year it was measured.
  Countries carry the national figure. Cities carry their own, which is
  the national figure adjusted for the local climate.
  """

  def up do
    alter table(:geography_places) do
      add :energy, :float
      add :energy_year, :integer
    end

    create table(:geography_countries) do
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :energy, :float, null: false
      add :energy_year, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:geography_countries, [:account_id, :name],
             name: :geography_countries_account_id_name_index
           )

    alter table(:geography_profiles) do
      add :weight_energy, :integer, null: false, default: 5
    end
  end

  def down do
    alter table(:geography_profiles) do
      remove :weight_energy
    end

    drop table(:geography_countries)

    alter table(:geography_places) do
      remove :energy
      remove :energy_year
    end
  end
end
