defmodule Hireme.Repo.Migrations.Identities do
  use Ecto.Migration

  @moduledoc """
  The ways into an account. An identity is a verified address or a
  provider's user bound to one account; a magic link is a one-time
  proof of an address that may not have an account yet, so it names
  none.
  """

  def up do
    create table(:identities) do
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :subject, :string, null: false
      add :display, :string, null: false, default: ""
      add :verified_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:identities, [:provider, :subject])
    create index(:identities, [:account_id])

    # The mail carries a random token; only its hash is here (ASVS 7.2.1).
    create table(:magic_links) do
      add :email, :string, null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :ip, :string, null: false, default: ""
      add :user_agent, :string, null: false, default: ""
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:magic_links, [:token_hash])
    create index(:magic_links, [:email, :expires_at])
  end

  def down do
    drop table(:magic_links)
    drop table(:identities)
  end
end
