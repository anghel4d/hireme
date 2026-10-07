defmodule Hireme.DataCase do
  @moduledoc """
  Test case that checks out a sandbox connection for the repo.
  """

  use ExUnit.CaseTemplate

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
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Hireme.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
