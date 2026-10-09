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

  @doc """
  Who a conn's cookie signs in, found the way a browser finds out: it
  asks for a wire ticket and redeems it. The answer is `{session,
  account}` with the account put on the process, `:second_factor` for a
  session that still owes one, or nil.
  """
  def whoami(conn) do
    asked =
      conn
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Phoenix.ConnTest.dispatch(HiremeWeb.Endpoint, :post, "/api/wire/ticket", nil)

    case {asked.status, Jason.decode!(asked.resp_body)} do
      {200, %{"ticket" => ticket}} ->
        {:ok, account_id, session_id} = HiremeWeb.Session.redeem(ticket)
        Hireme.Repo.put_account(account_id)

        {Hireme.Repo.get!(Hireme.Accounts.Session, session_id),
         Hireme.Repo.get!(Hireme.Accounts.Account, account_id, skip_account: true)}

      {401, %{"error" => "second_factor"}} ->
        :second_factor

      _ ->
        nil
    end
  end

  @doc """
  One `account/<method>` command from the browser a conn stands for, run
  as its wire session runs it (`HiremeWeb.Account.call/3` for the session
  its ticket names), and answered the way the HTTP routes were: the
  status, checked, and the JSON body with string keys. A browser that is
  not signed in, or still owes its second factor, has no wire session
  and gets 401.
  """
  def account(conn, method, params \\ %{}, status) do
    {code, body} =
      case whoami(conn) do
        {session, account} ->
          ctx = %{account_id: account.id, session_id: session.id, ip: "127.0.0.1"}
          params = Jason.decode!(Jason.encode!(params))

          case HiremeWeb.Account.call("account/#{method}", params, ctx) do
            {:ok, result, _} -> {200, result}
            {:signed_out, result} -> {200, result}
            {:error, code, message} -> {code, %{error: message}}
          end

        :second_factor ->
          {401, %{error: "second_factor"}}

        nil ->
          {401, %{error: "unauthenticated"}}
      end

    unless code == status,
      do:
        raise(ExUnit.AssertionError, message: "expected #{status}, got #{code}: #{inspect(body)}")

    Jason.decode!(Jason.encode!(body))
  end
end
