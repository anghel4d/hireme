defmodule Hireme.DataCase do
  @moduledoc """
  Test case on a sandboxed repo, running as one fresh account. Every
  test gets `account` in its context; rows it opens belong to it.
  """

  use ExUnit.CaseTemplate
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Hireme.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Hireme.DataCase
    end
  end

  setup tags do
    Hireme.DataCase.setup_sandbox(tags)
    {:ok, account: Hireme.DataCase.open_account()}
  end

  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Hireme.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc "A new account, made the account on this process."
  def open_account(name \\ "Test desk") do
    account = Hireme.Accounts.create!(%{name: name})
    Hireme.Repo.put_account(account.id)
    account
  end
end
