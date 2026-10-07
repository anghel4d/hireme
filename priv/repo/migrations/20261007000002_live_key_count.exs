defmodule Hireme.Repo.Migrations.LiveKeyCount do
  use Ecto.Migration

  @moduledoc """
  The cap on live keys is one update of the account, not a count-then-insert.
  Two mints that both read "99" cannot both write the hundredth key.
  """

  def up do
    alter table(:accounts) do
      add :live_key_count, :integer, null: false, default: 0
    end

    execute """
    UPDATE accounts
    SET live_key_count = (
      SELECT count(*) FROM api_keys
      WHERE api_keys.account_id = accounts.id AND api_keys.revoked_at IS NULL
    )
    """
  end

  def down do
    alter table(:accounts) do
      remove :live_key_count
    end
  end
end
