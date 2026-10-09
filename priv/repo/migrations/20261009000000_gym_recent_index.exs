defmodule Hireme.Repo.Migrations.GymRecentIndex do
  use Ecto.Migration

  def change do
    # Gym.recent/1 (also in progress/1) reads one tenant's newest forty reps.
    # SQLite's implicit rowid is the id tie-breaker, so reverse traversal
    # satisfies ORDER BY done_on DESC, id DESC without storing id twice.
    create index(:gym_reps, [:account_id, :done_on])
  end
end
