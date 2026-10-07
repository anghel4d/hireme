defmodule Hireme.Repo.Migrations.Desk do
  use Ecto.Migration

  @moduledoc """
  The whole desk in one migration. Rows are the durable truth and this
  is the last place they are rows; everything above reads columns.
  """

  @mismatch "cv lineage employer mismatch"

  def up do
    # Corpus: the person, their profiles, the lines a CV is built from.
    create table(:users) do
      add :name, :string, null: false
      add :email, :string, null: false, default: ""
      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email], where: "email != ''", name: :users_email_index)

    create table(:narratives) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :body, :text, null: false, default: ""
      add :version, :integer, null: false, default: 1
      add :private, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create unique_index(:narratives, [:user_id])

    create table(:profiles) do
      add :user_id, references(:users, on_delete: :nilify_all)
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

    # Campaign: employers, batches, the scoreboard reading, claims.
    create table(:employers) do
      add :name, :string, null: false
      add :freshness, :string, null: false, default: "unknown"
      add :note, :text, null: false, default: ""
      add :score_100, :integer, null: false, default: 50
      timestamps(type: :utc_datetime)
    end

    create unique_index(:employers, [:name])
    create index(:employers, [:score_100])

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
      add :target_total, :integer, null: false, default: 10_000
      add :target_on, :date
      add :daily_batches, :integer, null: false, default: 8
      add :daily_apps, :integer, null: false, default: 440
      add :note, :text, null: false, default: ""
      timestamps(type: :utc_datetime)
    end

    create unique_index(:scoreboard_snapshots, [:noted_on])

    # Applications. The rail is the pip string; notes ride beside it.
    create table(:job_apps) do
      add :profile_id, references(:profiles, on_delete: :nilify_all), null: false
      add :employer_id, references(:employers, on_delete: :nilify_all)
      add :batch_id, references(:batches, on_delete: :nilify_all)
      add :company, :string, null: false
      add :role, :string, null: false
      add :location, :string, null: false, default: ""
      add :listing_url, :string, null: false, default: ""
      add :canonical_url, :string, null: false, default: ""
      add :listing, :text, null: false, default: ""
      add :heat, :integer, null: false, default: 3
      add :status, :string, null: false, default: "open"
      add :next_action, :string, null: false, default: ""
      add :next_due, :date
      add :source, :string, null: false, default: ""
      add :stage_on, :date
      add :current_stage, :string, null: false
      add :pips, :string, null: false, default: "APPPPPPPPP"
      add :stage_notes, :text, null: false, default: "{}"
      add :freshness, :string, null: false, default: "unknown"
      add :gate, :string, null: false, default: "unset"
      add :fit, :string, null: false, default: ""
      add :squad, :string, null: false, default: ""
      add :department, :string, null: false, default: ""
      add :score_100, :integer, null: false, default: 50
      add :heat_override, :boolean, null: false, default: false
      add :heat_override_reason, :string, null: false, default: ""
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
    create index(:job_apps, [:batch_id])
    create index(:job_apps, [:freshness])
    create index(:job_apps, [:gate])
    create index(:job_apps, [:score_100])

    create unique_index(:job_apps, [:canonical_url],
             where: "canonical_url != ''",
             name: :job_apps_canonical_url_index
           )

    create table(:events) do
      add :job_app_id, references(:job_apps, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :body, :text, null: false, default: ""
      timestamps(type: :utc_datetime)
    end

    create index(:events, [:job_app_id, :inserted_at])

    create table(:letterboxes) do
      add :job_app_id, references(:job_apps, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:letterboxes, [:job_app_id])

    # CV: one lineage per employer, one variant per application, lines on the lineage.
    create table(:cv_lineages) do
      add :employer_id, references(:employers, on_delete: :delete_all), null: false
      add :generation, :integer, null: false, default: 1
      add :opened_on, :date, null: false
      add :rewrites_allowed, :boolean, null: false, default: true
      add :theme, :text, null: false, default: "{}"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:cv_lineages, [:employer_id])

    create table(:cv_variants) do
      add :job_app_id, references(:job_apps, on_delete: :delete_all)
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :lineage_id, references(:cv_lineages, on_delete: :nilify_all)
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
      add :lineage_id, references(:cv_lineages, on_delete: :nilify_all)
      add :generation, :integer, null: false, default: 1
      add :mode, :string, null: false
      add :title, :string
      add :body, :text
      add :reason, :text
      timestamps(type: :utc_datetime)
    end

    create unique_index(:overlays, [:job_app_id, :item_id])
    create unique_index(:overlays, [:lineage_id, :item_id])

    # Lanes beside the desk.
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

    create table(:gym_reps) do
      add :problem_id, references(:gym_problems, on_delete: :delete_all), null: false
      add :done_on, :date, null: false
      add :minutes, :integer, null: false, default: 0
      add :outcome, :string, null: false, default: "solved"
      add :note, :string, null: false, default: ""
      timestamps(type: :utc_datetime)
    end

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

    create index(:net_entries, [:shipped_on])

    # The CV pairing is enforced in the database too: a variant or a
    # line bound to an application names that application's employer's
    # lineage, and names one at all.
    for {table, event, extra} <- [
          {"cv_variants", "INSERT", "NEW.job_app_id IS NOT NULL"},
          {"cv_variants", "UPDATE OF lineage_id, job_app_id", "NEW.job_app_id IS NOT NULL"},
          {"overlays", "INSERT", "1"},
          {"overlays", "UPDATE OF lineage_id, job_app_id", "1"}
        ] do
      name = "#{table}_#{if String.starts_with?(event, "INSERT"), do: "insert", else: "update"}"

      execute """
      CREATE TRIGGER #{name}_lineage
      BEFORE #{event} ON #{table}
      FOR EACH ROW
      WHEN #{extra}
      BEGIN
        SELECT RAISE(ABORT, '#{table} bound to an application needs a lineage')
        WHERE NEW.lineage_id IS NULL;
        SELECT RAISE(ABORT, '#{@mismatch}')
        WHERE (SELECT employer_id FROM cv_lineages WHERE id = NEW.lineage_id)
          IS NOT (SELECT employer_id FROM job_apps WHERE id = NEW.job_app_id);
      END;
      """
    end
  end

  def down do
    for name <-
          ~w(cv_variants_insert_lineage cv_variants_update_lineage overlays_insert_lineage overlays_update_lineage) do
      execute "DROP TRIGGER IF EXISTS #{name}"
    end

    for table <-
          ~w(net_entries gym_reps gym_problems overlays cv_variants cv_lineages letterboxes events job_apps
                    scoreboard_snapshots claims freshness_verdicts batches employers kv_pairs items profiles narratives users)a do
      drop table(table)
    end
  end
end
