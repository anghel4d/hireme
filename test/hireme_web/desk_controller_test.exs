defmodule HiremeWeb.DeskControllerTest do
  @moduledoc """
  What the desk still serves over HTTP: the page with what the early
  connect needs, and a fresh ticket for a reconnect. The desk itself is
  the wire session's (session_test.exs).
  """

  use HiremeWeb.ConnCase, async: false

  test "the page hands its shell a ticket and the account's scope", %{conn: conn} do
    html = conn |> get("/") |> html_response(200)
    [_, ticket] = Regex.run(~r/name="wire-ticket" content="([^"]+)"/, html)
    assert {:ok, _account, _session} = HiremeWeb.Session.redeem(ticket)
    assert html =~ ~r/name="wire-scope" content="[^"]+"/
  end

  test "a reconnect gets a fresh single-use ticket", %{conn: conn} do
    %{"ticket" => ticket} = conn |> post("/api/wire/ticket", %{}) |> json_response(200)
    assert {:ok, _, _} = HiremeWeb.Session.redeem(ticket)
    assert :error = HiremeWeb.Session.redeem(ticket)
  end
end
