defmodule HiremeWeb.ConnCase do
  @moduledoc """
  Test case that builds a conn signed into a fresh account on a
  sandboxed repo. `conn` carries a live session; `account` and
  `session` are in the context.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint HiremeWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import HiremeWeb.ConnCase
    end
  end

  setup tags do
    Hireme.DataCase.setup_sandbox(tags)
    account = Hireme.DataCase.open_account()
    {token, session} = Hireme.Accounts.start_session(account)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{HiremeWeb.Auth.session_key() => token})

    {:ok, conn: conn, account: account, session: session}
  end

  @doc "A conn with no session at all."
  def anonymous, do: Phoenix.ConnTest.build_conn()
end
