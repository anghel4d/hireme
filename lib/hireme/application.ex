defmodule Hireme.Repo do
  use Ecto.Repo, otp_app: :hireme, adapter: Ecto.Adapters.SQLite3
end

defmodule Hireme.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Hireme.Repo,
      # Outside a release the migrations run from `mix ecto.migrate`.
      {Ecto.Migrator,
       repos: Application.fetch_env!(:hireme, :ecto_repos),
       skip: System.get_env("RELEASE_NAME") == nil},
      {DNSCluster, query: Application.get_env(:hireme, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Hireme.PubSub},
      {Registry, keys: :unique, name: Hireme.Letterbox.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Hireme.Letterbox.Supervisor},
      HiremeWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Hireme.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    HiremeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
