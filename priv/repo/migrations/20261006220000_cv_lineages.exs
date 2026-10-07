defmodule Hireme.Repo.Migrations.CvLineages do
  use Ecto.Migration

  def up do
    create table(:cv_lineages) do
      add :employer_id, references(:employers, on_delete: :delete_all), null: false
      add :generation, :integer, null: false, default: 1
      add :opened_on, :date, null: false
      add :rewrites_allowed, :boolean, null: false, default: true
      add :theme, :text, null: false, default: "{}"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cv_lineages, [:employer_id])

    alter table(:cv_variants) do
      add :lineage_id, references(:cv_lineages, on_delete: :nilify_all)
    end

    alter table(:overlays) do
      add :lineage_id, references(:cv_lineages, on_delete: :nilify_all)
      add :generation, :integer, null: false, default: 1
    end

    flush()

    repo().query!("""
    INSERT INTO employers (name, freshness, note, inserted_at, updated_at)
    SELECT company, 'unknown', '', datetime('now'), datetime('now')
    FROM job_apps
    WHERE employer_id IS NULL AND company != ''
      AND company NOT IN (SELECT name FROM employers)
    GROUP BY company
    """)

    repo().query!("""
    UPDATE job_apps
    SET employer_id = (
      SELECT id FROM employers WHERE employers.name = job_apps.company
    )
    WHERE employer_id IS NULL
    """)

    repo().query!("""
    INSERT INTO cv_lineages (employer_id, generation, opened_on, rewrites_allowed, theme, inserted_at, updated_at)
    SELECT id, 1, date('now'), 1, '{}', datetime('now'), datetime('now') FROM employers
    WHERE NOT EXISTS (
      SELECT 1 FROM cv_lineages WHERE cv_lineages.employer_id = employers.id
    )
    """)

    repo().query!("""
    UPDATE cv_variants
    SET lineage_id = (
      SELECT cv_lineages.id
      FROM cv_lineages
      JOIN job_apps ON job_apps.employer_id = cv_lineages.employer_id
      WHERE job_apps.id = cv_variants.job_app_id
    )
    WHERE job_app_id IS NOT NULL
    """)

    repo().query!("""
    UPDATE overlays
    SET lineage_id = (
      SELECT lineage_id FROM cv_variants WHERE cv_variants.job_app_id = overlays.job_app_id
    )
    WHERE job_app_id IS NOT NULL
    """)

    execute """
    DELETE FROM overlays
    WHERE lineage_id IS NOT NULL
      AND id NOT IN (
        SELECT MIN(id) FROM overlays
        WHERE lineage_id IS NOT NULL
        GROUP BY lineage_id, item_id
      )
    """

    create unique_index(:overlays, [:lineage_id, :item_id])

    execute """
    CREATE TRIGGER cv_variants_employer_match
    BEFORE INSERT ON cv_variants
    FOR EACH ROW
    WHEN NEW.job_app_id IS NOT NULL
    BEGIN
      SELECT RAISE(ABORT, 'cv lineage employer mismatch')
      WHERE (
        SELECT employer_id FROM cv_lineages WHERE id = NEW.lineage_id
      ) IS NOT (
        SELECT employer_id FROM job_apps WHERE id = NEW.job_app_id
      );
    END;
    """

    execute """
    CREATE TRIGGER cv_variants_employer_match_update
    BEFORE UPDATE OF lineage_id ON cv_variants
    FOR EACH ROW
    WHEN NEW.job_app_id IS NOT NULL
    BEGIN
      SELECT RAISE(ABORT, 'cv lineage employer mismatch')
      WHERE (
        SELECT employer_id FROM cv_lineages WHERE id = NEW.lineage_id
      ) IS NOT (
        SELECT employer_id FROM job_apps WHERE id = NEW.job_app_id
      );
    END;
    """

    execute """
    CREATE TRIGGER overlays_lineage_employer_match
    BEFORE INSERT ON overlays
    FOR EACH ROW
    WHEN NEW.lineage_id IS NOT NULL AND NEW.job_app_id IS NOT NULL
    BEGIN
      SELECT RAISE(ABORT, 'cv lineage employer mismatch')
      WHERE (
        SELECT employer_id FROM cv_lineages WHERE id = NEW.lineage_id
      ) IS NOT (
        SELECT employer_id FROM job_apps WHERE id = NEW.job_app_id
      );
    END;
    """

    execute """
    CREATE TRIGGER overlays_lineage_employer_match_update
    BEFORE UPDATE OF lineage_id, job_app_id ON overlays
    FOR EACH ROW
    WHEN NEW.lineage_id IS NOT NULL AND NEW.job_app_id IS NOT NULL
    BEGIN
      SELECT RAISE(ABORT, 'cv lineage employer mismatch')
      WHERE (
        SELECT employer_id FROM cv_lineages WHERE id = NEW.lineage_id
      ) IS NOT (
        SELECT employer_id FROM job_apps WHERE id = NEW.job_app_id
      );
    END;
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS overlays_lineage_employer_match_update"
    execute "DROP TRIGGER IF EXISTS overlays_lineage_employer_match"
    execute "DROP TRIGGER IF EXISTS cv_variants_employer_match_update"
    execute "DROP TRIGGER IF EXISTS cv_variants_employer_match"
    drop_if_exists index(:overlays, [:lineage_id, :item_id])

    alter table(:overlays) do
      remove :generation
      remove :lineage_id
    end

    alter table(:cv_variants) do
      remove :lineage_id
    end

    drop table(:cv_lineages)
  end
end
