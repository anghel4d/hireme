defmodule HiremeWeb.ConnCase do
  @moduledoc """
  A test that goes through the endpoint. Requests carry an https URL so
  the `__Host-` cookie is kept between them, and `signed_in/2` puts a
  session cookie on a conn.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import HiremeWeb.ConnCase
      import Hireme.DataCase, only: [sign_in: 0, sign_in: 1, age: 3]
      @endpoint HiremeWeb.Endpoint
    end
  end

  setup tags do
    Hireme.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn(:get, "https://www.example.com/")}
  end

  @doc "A conn carrying `token` as its signed-in session cookie."
  def signed_in(conn, token) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{HiremeWeb.Auth.session_key() => token})
  end
end
