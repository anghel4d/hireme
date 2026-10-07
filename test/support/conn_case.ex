defmodule HiremeWeb.ConnCase do
  @moduledoc """
  Test case that builds a conn on a sandboxed repo.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint HiremeWeb.Endpoint

      use HiremeWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import HiremeWeb.ConnCase
    end
  end

  setup tags do
    Hireme.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
