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
    :ets.delete_all_objects(Hireme.RateLimit)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc "A new account, made the account on this process."
  def open_account(name \\ "Test desk") do
    account = Hireme.Accounts.create!(%{name: name})
    Hireme.Repo.put_account(account.id)
    # The sandbox hands this id out again; its sequencer goes with the test.
    on_exit(fn -> Hireme.Ops.stop(account.id) end)
    account
  end

  @doc """
  A session aged past the step-up window: both stamps backdated, the
  updated row back. An account ages every session it has.
  """
  def age!(%Hireme.Accounts.Account{id: id}),
    do: for(s <- Hireme.Accounts.list_sessions(id), do: age!(s))

  def age!(%Hireme.Accounts.Session{} = session) do
    stale =
      DateTime.utc_now()
      |> DateTime.add(-(Hireme.Security.step_up_window() + 1), :second)
      |> DateTime.truncate(:second)

    session
    |> Ecto.Changeset.change(authenticated_at: stale, mfa_at: stale)
    |> Hireme.Repo.update!(skip_account: true)
  end
end
