defmodule Hireme.Repo.Migrations.ApplicationNo do
  use Ecto.Migration

  @moduledoc """
  Each application gets a per-account number, `no`, so a lease can name a
  contiguous range of them ("1 to 16"). Numbers come from the account's
  `next_no` counter, bumped in the transaction that opens the
  application, so one is never reused, even after a delete. Existing
  applications are numbered in the order they were opened (by id).
  """

  def up do
    alter table(:accounts) do
      add :next_no, :integer, null: false, default: 1
    end

    alter table(:job_apps) do
      add :no, :integer, null: false, default: 0
    end

    execute """
    UPDATE job_apps SET no = (
      SELECT count(*) FROM job_apps AS earlier
      WHERE earlier.account_id = job_apps.account_id AND earlier.id <= job_apps.id
    )
    """

    execute """
    UPDATE accounts SET next_no = 1 + (
      SELECT coalesce(max(no), 0) FROM job_apps WHERE job_apps.account_id = accounts.id
    )
    """

    create unique_index(:job_apps, [:account_id, :no])
  end

  def down do
    drop index(:job_apps, [:account_id, :no])

    alter table(:job_apps) do
      remove :no
    end

    alter table(:accounts) do
      remove :next_no
    end
  end
end
