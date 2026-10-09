defmodule Hireme.Repo.Migrations.WireOps do
  use Ecto.Migration

  @moduledoc """
  The desk's write path moves to `Hireme.Ops`: one sequencer per
  account, one revision counter per account, and a ledger of client ops.

  `desk_rev` counts committed desk changes. It is bumped in the same
  transaction as the change, so a reader that sees the revision sees the
  change, and a writer in another VM shows up as a gap.

  `wire_ops` stores each client op's outcome for 24 hours under the
  client's 64-bit id, so a resend after a reconnect gets the first
  answer back instead of writing twice.
  """

  def change do
    alter table(:accounts) do
      add :desk_rev, :integer, null: false, default: 0
    end

    create table(:wire_ops) do
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :op_id, :integer, null: false
      add :kind, :string, null: false
      add :rev, :integer, null: false
      add :refusal, :string
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:wire_ops, [:account_id, :op_id])
    create index(:wire_ops, [:account_id, :inserted_at])
  end
end
