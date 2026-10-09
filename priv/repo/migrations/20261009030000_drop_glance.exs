defmodule Hireme.Repo.Migrations.DropGlance do
  use Ecto.Migration

  @moduledoc """
  Keyword coverage and mask counts were stored on each application so a
  board need not resolve every CV. Every client now derives them from the
  overlays, the lines and the listing it already holds, so the server
  keeps the state and not its arithmetic.
  """

  def change do
    alter table(:job_apps) do
      remove :keyword_hits, :integer, default: 0
      remove :keyword_total, :integer, default: 0
      remove :mask_hidden, :integer, default: 0
      remove :mask_altered, :integer, default: 0
      remove :mask_emphasized, :integer, default: 0
    end
  end
end
