defmodule Hireme.Repo do
  @moduledoc """
  The repository, and the one place a query learns which account it is
  for. `put_account/1` names the account on the current process; every
  query after that carries `where account_id = ?`, and a query with no
  account on the process raises instead of returning another account's
  rows. Rows no account owns (accounts themselves, a magic link, a session
  or key looked up by its secret before the account is known) pass
  `skip_account: true` on purpose.

  Inserts are not filtered by Ecto: a writer stamps the account on the row
  it inserts (`account_id/0`).
  """

  use Ecto.Repo, otp_app: :hireme, adapter: Ecto.Adapters.SQLite3
  require Ecto.Query

  @key {__MODULE__, :account_id}

  # SQLite's settings for every connection; config may override any of them.
  # WAL lets readers run beside the one writer; the busy timeout covers a
  # writer from another VM (a release RPC), since in-VM writers queue on
  # `Hireme.Store`'s lock instead.
  @pragmas [
    journal_mode: :wal,
    synchronous: :normal,
    foreign_keys: :on,
    temp_store: :memory,
    busy_timeout: 5_000,
    cache_size: -64_000
  ]

  @impl true
  def init(_context, config), do: {:ok, Keyword.merge(@pragmas, config)}

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
