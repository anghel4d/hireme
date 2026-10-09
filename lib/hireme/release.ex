defmodule Hireme.Release do
  @moduledoc """
  Database operations for releases, without starting the web server or seeding data.
  """

  @app :hireme

  @doc "Applies all pending migrations to the configured repositories."
  @spec migrate() :: :ok
  def migrate do
    :ok = Application.ensure_loaded(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end
end
