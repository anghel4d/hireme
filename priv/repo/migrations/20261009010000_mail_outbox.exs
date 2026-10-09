defmodule Hireme.Repo.Migrations.MailOutbox do
  use Ecto.Migration

  @moduledoc """
  Security notices are written here by the request that caused them and
  sent outside it, so a key or factor change never waits on the mail
  provider, and a notice still pending at a restart is sent after it.
  """

  def change do
    create table(:mail_outbox) do
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :address, :string, null: false
      add :kind, :string, null: false
      add :meta, :map, null: false, default: %{}
      add :attempts, :integer, null: false, default: 0
      add :next_at, :utc_datetime, null: false
      add :sent_at, :utc_datetime
      add :last_error, :string
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:mail_outbox, [:next_at], where: "sent_at IS NULL")
  end
end
