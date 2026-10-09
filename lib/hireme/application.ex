defmodule Hireme.Repo do
  @moduledoc """
  The repository, and the one place a query learns which account it is
  for. `put_account/1` names the account on the current process; every
  read after that carries `where account_id = ?`, and a read with no
  account on the process raises instead of returning another account's
  rows. Rows that are not owned by an account (the accounts themselves,
  a session or a key looked up by its secret before the account is
  known) pass `skip_account: true` on purpose.
  """

  use Ecto.Repo, otp_app: :hireme, adapter: Ecto.Adapters.SQLite3
  require Ecto.Query

  @key {__MODULE__, :account_id}

  @spec put_account(pos_integer() | nil) :: :ok
  def put_account(id) when is_integer(id) or is_nil(id) do
    Process.put(@key, id)
    :ok
  end

  @spec account_id() :: pos_integer() | nil
  def account_id, do: Process.get(@key)

  @spec account_id!() :: pos_integer()
  def account_id!,
    do: account_id() || raise("no account on this process; see Hireme.Repo.put_account/1")

  @doc "Run `fun` as `account_id`, restoring whatever the process had before."
  @spec with_account(pos_integer() | nil, (-> result)) :: result when result: term()
  def with_account(account_id, fun) do
    previous = account_id()
    put_account(account_id)

    try do
      fun.()
    after
      put_account(previous)
    end
  end

  @impl true
  def default_options(_operation), do: [account_id: account_id()]

  @impl true
  def prepare_query(_operation, query, opts) do
    cond do
      opts[:skip_account] || opts[:ecto_query] in [:schema_migration, :preload] ->
        {query, opts}

      id = opts[:account_id] ->
        {Ecto.Query.where(query, account_id: ^id), opts}

      true ->
        raise ArgumentError,
              "a query ran with no account on the process: #{inspect(query)}; " <>
                "call Hireme.Repo.put_account/1 first or pass skip_account: true"
    end
  end
end

defmodule Hireme.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Tests drain the mail outbox themselves (config/test.exs).
    outbox =
      if Application.get_env(:hireme, :mail_outbox, true), do: [Hireme.Mailer.Outbox], else: []

    children =
      [
        Hireme.Repo,
        {DNSCluster, query: Application.get_env(:hireme, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Hireme.PubSub},
        Hireme.Ops,
        {Task.Supervisor, name: Hireme.Accounts.Mail},
        Hireme.RateLimit,
        {Registry, keys: :unique, name: Hireme.Letterbox.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: Hireme.Letterbox.Supervisor}
      ] ++
        outbox ++
        [
          # The WebTransport gate's Unix socket; nothing starts without config.
          {HiremeWeb.Gate, Application.get_env(:hireme, HiremeWeb.Gate, [])},
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
