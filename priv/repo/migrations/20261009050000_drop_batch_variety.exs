defmodule Hireme.Repo.Migrations.DropBatchVariety do
  use Ecto.Migration

  @moduledoc """
  A batch's variety (how many companies, roles, locations and fits it
  spans) was summarized on import and stored. The kernel derives it from
  the batch's applications, so the server stores the state and not its
  arithmetic.
  """

  def change do
    alter table(:batches) do
      remove :variety, :text, null: false, default: "{}"
    end
  end
end
