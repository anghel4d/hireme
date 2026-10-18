defmodule HiremeWeb.ConnCase do
  @moduledoc """
  A test that goes through the endpoint. Requests carry an https URL so
  the `__Host-` cookie is kept between them; `signed_in/2` puts a session
  cookie on a conn; a conn that has answered is recycled before the next
  request, its cookies carried over as a browser's would be.
  """

  use ExUnit.CaseTemplate
  import ExUnit.Assertions

  using do
    quote do
      import Plug.Conn
      import HiremeWeb.ConnCase
      import Hireme.DataCase, only: [sign_in: 0, sign_in: 1, age: 3]
    end
  end

  setup tags do
    Hireme.DataCase.setup_sandbox(tags)
    Hireme.DataCase.fresh_window(tags[:window])
    {:ok, conn: build_conn()}
  end

  @doc "A request to this origin over https; it skips the CSRF check unless a test puts it back."
  def build_conn(method \\ :get, url \\ "https://www.example.com/"),
    do: method |> Plug.Test.conn(url) |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)

  @doc "A conn carrying `token` as its signed-in session cookie."
  def signed_in(conn, token),
    do: Plug.Test.init_test_session(conn, %{HiremeWeb.Auth.session_key() => token})

  def get(conn, path, params \\ %{}), do: dispatch(conn, :get, path, params)
  def post(conn, path, params \\ %{}), do: dispatch(conn, :post, path, params)

  defp dispatch(conn, method, path, params) do
    conn = if conn.state == :unset, do: conn, else: recycle(conn)
    conn |> Plug.Adapters.Test.Conn.conn(method, path, params) |> HiremeWeb.Endpoint.call([])
  end

  @doc "The next request after `conn`: its cookies and its accept and authorization headers."
  def recycle(conn) do
    kept =
      for {k, _} = h <- conn.req_headers, k in ~w(accept accept-language authorization), do: h

    build_conn(:get, "#{conn.scheme}://#{conn.host}/")
    |> Plug.Test.recycle_cookies(conn)
    |> Map.update!(:req_headers, &(kept ++ &1))
  end

  def html_response(conn, status), do: body(conn, status, "text/html")
  def json_response(conn, status), do: conn |> body(status, "application/json") |> JSON.decode!()

  def redirected_to(conn, status \\ 302) do
    assert conn.status == status, "expected a #{status} redirect, got #{conn.status}"
    [to] = Plug.Conn.get_resp_header(conn, "location")
    to
  end

  defp body(conn, status, type) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    assert [content_type | _] = Plug.Conn.get_resp_header(conn, "content-type")
    assert content_type =~ type
    conn.resp_body
  end
end
