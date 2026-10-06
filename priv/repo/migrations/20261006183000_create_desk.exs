defmodule Hireme.Repo.Migrations.CreateDesk do
  use Ecto.Migration

  def change do
    create table(:profiles) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :headline, :string, null: false
      add :summary, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:profiles, [:slug])

    create table(:items) do
      add :profile_id, references(:profiles, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :key, :string, null: false
      add :title, :string, null: false
      add :body, :text, null: false, default: ""
      add :org, :string, null: false, default: ""
      add :span, :string, null: false, default: ""
      add :position, :integer, null: false, default: 0
      add :keywords, :text, null: false, default: "[]"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:items, [:key])
    create index(:items, [:profile_id, :kind])

    create table(:kv_pairs) do
      add :namespace, :string, null: false
      add :key, :string, null: false
      add :value, :text, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:kv_pairs, [:namespace, :key])

    create table(:job_apps) do
      add :profile_id, references(:profiles, on_delete: :nilify_all), null: false
      add :company, :string, null: false
      add :role, :string, null: false
      add :location, :string, null: false, default: ""
      add :listing_url, :string, null: false, default: ""
      add :listing, :text, null: false, default: ""
      add :heat, :integer, null: false, default: 3
      add :status, :string, null: false, default: "open"
      add :next_action, :string, null: false, default: ""
      add :next_due, :date
      add :source, :string, null: false, default: ""
      add :stage_on, :date
      add :current_stage, :string, null: false
      add :pips, :string, null: false, default: "APPPPPPP"
      add :keyword_hits, :integer, null: false, default: 0
      add :keyword_total, :integer, null: false, default: 0
      add :mask_hidden, :integer, null: false, default: 0
      add :mask_altered, :integer, null: false, default: 0
      add :mask_emphasized, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:job_apps, [:status, :heat])
    create index(:job_apps, [:profile_id])
    create index(:job_apps, [:current_stage])

    create table(:cv_variants) do
      add :job_app_id, references(:job_apps, on_delete: :delete_all)
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :label, :string, null: false
      add :theme, :text, null: false, default: "{}"
      add :note, :text, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cv_variants, [:job_app_id])

    create unique_index(:cv_variants, [:profile_id],
             where: "job_app_id IS NULL",
             name: :cv_variants_one_root_per_profile
           )

    create table(:overlays) do
      add :job_app_id, references(:job_apps, on_delete: :delete_all), null: false
      add :item_id, references(:items, on_delete: :delete_all), null: false
      add :mode, :string, null: false
      add :title, :string
      add :body, :text
      add :reason, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:overlays, [:job_app_id, :item_id])

    create table(:stages) do
      add :job_app_id, references(:job_apps, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :position, :integer, null: false
      add :state, :string, null: false
      add :note, :text, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:stages, [:job_app_id, :key])

    create table(:events) do
      add :job_app_id, references(:job_apps, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :body, :text, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create index(:events, [:job_app_id, :inserted_at])
  end
end
