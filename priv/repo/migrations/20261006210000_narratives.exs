defmodule Hireme.Repo.Migrations.Narratives do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :name, :string, null: false
      add :email, :string, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email], where: "email != ''", name: :users_email_index)

    create table(:narratives) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :body, :text, null: false, default: ""
      add :version, :integer, null: false, default: 1
      add :private, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:narratives, [:user_id])

    alter table(:profiles) do
      add :user_id, references(:users, on_delete: :nilify_all)
    end
  end
end
