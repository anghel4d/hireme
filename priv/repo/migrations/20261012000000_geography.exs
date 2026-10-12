defmodule Hireme.Repo.Migrations.Geography do
  use Ecto.Migration

  @moduledoc """
  The career-geography chart and the one holder profile per account.
  Cities carry no passport. The profile does.
  """

  def up do
    create table(:geography_places) do
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :position, :integer, null: false, default: 0
      add :name, :string, null: false
      add :country, :string, null: false
      add :region, :string, null: false
      add :cost, :float, null: false
      add :qol, :float, null: false
      add :mobility, :string, null: false
      add :language, :string, null: false
      add :tech, :integer, null: false
      add :ease, :integer, null: false
      add :labeled, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:geography_places, [:account_id, :name],
             name: :geography_places_account_id_name_index
           )

    create index(:geography_places, [:account_id, :position])

    create table(:geography_profiles) do
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :field, :string, null: false, default: ""
      add :citizenships, :string, null: false, default: ""
      add :languages, :string, null: false, default: ""
      add :weight_qol, :integer, null: false, default: 3
      add :weight_afford, :integer, null: false, default: 2
      add :weight_lang, :integer, null: false, default: 3
      add :weight_route, :integer, null: false, default: 3
      add :weight_tech, :integer, null: false, default: 3
      add :weight_ease, :integer, null: false, default: 2
      timestamps(type: :utc_datetime)
    end

    create unique_index(:geography_profiles, [:account_id])
  end

  def down do
    drop table(:geography_profiles)
    drop table(:geography_places)
  end
end
