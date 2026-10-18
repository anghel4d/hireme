defmodule HiremeWeb.McpTest do
  @moduledoc """
  `hireme-mcp`'s resources over the real binary, speaking MCP over stdio to
  a running endpoint: a subscribed row is announced when it is written, a
  resident one (an application, judged from the session's own rows) and a
  server-side one (a corporation, re-read on the advance) alike. Needs the
  binary: `HIREME_MCP=<path> mix test test/hireme_web/mcp_test.exs`.
  """

  use Hireme.McpCase

  test "a subscribed application and a subscribed corporation are announced when written", ctx do
    p = mcp(ctx)
    ok!(tool(p, "lease", %{}))

    [_, id] =
      Regex.run(
        ~r/-> id (\d+)/,
        text_of(
          ok!(tool(p, "put", %{table: "applications", set: %{company: "Acme", role: "Engineer"}}))
        )
      )

    ok!(
      tool(p, "put", %{table: "corporations", key: %{domain: "acme.test"}, set: %{name: "Acme"}})
    )

    no =
      text_of(tool(p, "find", %{table: "applications", cols: ["no"]}))
      |> then(&Regex.run(~r/"no": (\d+)/, &1))
      |> List.last()

    app = "hireme://applications/#{no}"
    corp = "hireme://corporations/acme.test"
    assert %{"result" => %{}} = call(p, "resources/subscribe", %{uri: app})
    assert %{"result" => %{}} = call(p, "resources/subscribe", %{uri: corp})

    # The resident row: the application rewritten.
    ok!(
      tool(p, "put", %{
        table: "applications",
        id: String.to_integer(id),
        set: %{role: "Staff Engineer"}
      })
    )

    assert updated(p, app), "no update for #{app}"

    # The server-side row: re-read when the account advances.
    ok!(
      tool(p, "put", %{
        table: "corporations",
        key: %{domain: "acme.test"},
        set: %{name: "Acme Corp"}
      })
    )

    assert updated(p, corp), "no update for #{corp}"

    # Unsubscribed, a write is silent.
    assert %{"result" => %{}} = call(p, "resources/unsubscribe", %{uri: corp})

    ok!(
      tool(p, "put", %{
        table: "corporations",
        key: %{domain: "acme.test"},
        set: %{name: "Acme Inc"}
      })
    )

    refute updated(p, corp, 1_500), "#{corp} announced after unsubscribe"

    # A row that does not exist cannot be subscribed to.
    assert %{"error" => %{"code" => _}} =
             call(p, "resources/subscribe", %{uri: "hireme://corporations/none.test"})
  end

  # Every line up to the reply to `id`, decoded.
  defp lines_until(p, id, acc \\ []) do
    receive do
      {^p, {:data, {:eol, l}}} ->
        case JSON.decode(l) do
          {:ok, %{"id" => ^id} = r} -> Enum.reverse([r | acc])
          {:ok, m} -> lines_until(p, id, [m | acc])
          _ -> lines_until(p, id, acc)
        end
    after
      10_000 -> flunk("no MCP reply to #{id}")
    end
  end

  test "a JSON-RPC response from the client is not answered; requests around it are", ctx do
    p = mcp(ctx)
    line(p, %{jsonrpc: "2.0", id: 4242, result: %{}})
    line(p, %{jsonrpc: "2.0", id: 4243, error: %{code: -32_000, message: "client side"}})
    line(p, %{jsonrpc: "2.0", id: 4244, method: "ping"})
    seen = lines_until(p, 4244)
    assert %{"result" => %{}} = List.last(seen)
    refute Enum.any?(seen, &(&1["id"] in [4242, 4243])), inspect(seen)
    # An object that is neither a request nor a response is still an invalid request.
    line(p, %{jsonrpc: "2.0", id: 4245})
    assert %{"error" => %{"code" => -32_600}} = List.last(lines_until(p, 4245))
  end
end
