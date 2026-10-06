defmodule Hireme.Repo.Migrations.RequireLineageOnBoundRows do
  use Ecto.Migration

  @moduledoc false

  # The employer-match triggers only fire when lineage_id is set. These
  # close the remaining gap: a variant or a line bound to an application
  # must name a lineage.

  def up do
    execute """
    CREATE TRIGGER cv_variants_require_lineage
    BEFORE INSERT ON cv_variants
    FOR EACH ROW
    WHEN NEW.job_app_id IS NOT NULL AND NEW.lineage_id IS NULL
    BEGIN
      SELECT RAISE(ABORT, 'cv variant bound to an application needs a lineage');
    END;
    """

    execute """
    CREATE TRIGGER cv_variants_require_lineage_update
    BEFORE UPDATE OF lineage_id, job_app_id ON cv_variants
    FOR EACH ROW
    WHEN NEW.job_app_id IS NOT NULL AND NEW.lineage_id IS NULL
    BEGIN
      SELECT RAISE(ABORT, 'cv variant bound to an application needs a lineage');
    END;
    """

    execute """
    CREATE TRIGGER overlays_require_lineage
    BEFORE INSERT ON overlays
    FOR EACH ROW
    WHEN NEW.lineage_id IS NULL
    BEGIN
      SELECT RAISE(ABORT, 'overlay needs a lineage');
    END;
    """

    execute """
    CREATE TRIGGER overlays_require_lineage_update
    BEFORE UPDATE OF lineage_id ON overlays
    FOR EACH ROW
    WHEN NEW.lineage_id IS NULL
    BEGIN
      SELECT RAISE(ABORT, 'overlay needs a lineage');
    END;
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS overlays_require_lineage_update"
    execute "DROP TRIGGER IF EXISTS overlays_require_lineage"
    execute "DROP TRIGGER IF EXISTS cv_variants_require_lineage_update"
    execute "DROP TRIGGER IF EXISTS cv_variants_require_lineage"
  end
end
