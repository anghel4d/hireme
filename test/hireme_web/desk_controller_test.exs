defmodule HiremeWeb.DeskControllerTest do
  @moduledoc """
  What the desk still serves over HTTP: the page with what the early
  connect needs, and a fresh ticket for a reconnect. The desk itself is
  the wire session's (session_test.exs).
  """

  use HiremeWeb.ConnCase, async: false

  test "the page hosts the shell and hands it a ticket, scope and kernel", %{conn: conn} do
    html = conn |> get("/") |> html_response(200)
    assert html =~ ~s(<div id="desk" class="desk"></div>)
    assert html =~ "/assets/js/app.js"
    assert html =~ ~s(rel="preload" href="/wasm/kernel.wasm")
    [_, ticket] = Regex.run(~r/name="wire-ticket" content="([^"]+)"/, html)
    assert {:ok, _account, _session} = HiremeWeb.Session.redeem(ticket)
    assert html =~ ~r/name="wire-scope" content="[0-9a-f]{24}"/
  end

  test "a reconnect gets a fresh single-use ticket", %{conn: conn} do
    %{"ticket" => ticket} = conn |> post("/api/wire/ticket", %{}) |> json_response(200)
    assert {:ok, _, _} = HiremeWeb.Session.redeem(ticket)
    assert :error = HiremeWeb.Session.redeem(ticket)
  end
end
