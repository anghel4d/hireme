defmodule HiremeWeb.McpTest do
  @moduledoc """
  `hireme-mcp`'s resources over the real binary, speaking MCP over stdio to
  a running endpoint: a subscribed row is announced when it is written, a
  resident one (an application, judged from the session's own rows) and a
  server-side one (a corporation, re-read on the advance) alike. Needs the
  binary: `HIREME_MCP=<path> mix test test/hireme_web/mcp_test.exs`.
  """

  use Hireme.WireCase, async: false

  @moduletag :mcp
  if System.get_env("HIREME_MCP") in [nil, ""],
    do: @moduletag(skip: "set HIREME_MCP to a built hireme-mcp to run the MCP resource tests")

  alias Hireme.Keys

  setup do
    {:ok, server} =
      Bandit.start_link(plug: HiremeWeb.Endpoint, ip: :loopback, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, bin: System.get_env("HIREME_MCP"), port: port}
  end

  defp mcp(%{bin: bin, port: port, session: s}) do
    {:ok, %{secret: secret}} = Keys.mint(s, "mcp", Keys.preset(:read_write))

    p =
      Port.open({:spawn_executable, bin}, [
        :binary,
        :exit_status,
        {:line, 1_000_000},
        env: [
          {~c"HIREME_KEY", String.to_charlist(secret)},
          {~c"HIREME_URL", String.to_charlist("http://localhost:#{port}")}
        ]
      ])

    call(p, "initialize", %{
      protocolVersion: "2025-06-18",
      capabilities: %{},
      clientInfo: %{name: "resources", version: "0"}
    })

    line(p, %{jsonrpc: "2.0", method: "notifications/initialized"})
    wait_connected(p, 50)
    p
  end

  defp line(p, msg), do: send(p, {self(), {:command, JSON.encode!(msg) <> "\n"}})

  defp wait_connected(p, 0),
    do: flunk("hireme-mcp never connected: #{inspect(tool(p, "hireme", %{}))}")

  defp wait_connected(p, n) do
    if text_of(tool(p, "hireme", %{})) =~ "not connected" do
      Process.sleep(100)
      wait_connected(p, n - 1)
    else
      :ok
    end
  end

  defp call(p, method, params) do
    id = System.unique_integer([:positive])
    line(p, %{jsonrpc: "2.0", id: id, method: method, params: params})
    reply(p, id)
  end

  # Notifications that arrive while waiting for a reply are kept for `updated/2`.
  defp reply(p, id) do
    receive do
      {^p, {:data, {:eol, l}}} ->
        case JSON.decode(l) do
          {:ok, %{"id" => ^id} = r} ->
            r

          {:ok, %{"method" => "notifications/resources/updated", "params" => %{"uri" => uri}}} ->
            send(self(), {:updated, uri})
            reply(p, id)

          _ ->
            reply(p, id)
        end
    after
      10_000 -> flunk("no MCP reply to #{id}")
    end
  end

  # Whether `uri` was announced within `ms`, reading any lines still on the port.
  defp updated(p, uri, ms \\ 5_000) do
    receive do
      {:updated, ^uri} ->
        true

      {^p, {:data, {:eol, l}}} ->
        case JSON.decode(l) do
          {:ok, %{"method" => "notifications/resources/updated", "params" => %{"uri" => ^uri}}} ->
            true

          _ ->
            updated(p, uri, ms)
        end
    after
      ms -> false
    end
  end

  defp tool(p, name, args), do: call(p, "tools/call", %{name: name, arguments: args})

  defp text_of(%{"result" => %{"content" => content}}),
    do: Enum.map_join(content, "\n", & &1["text"])

  defp text_of(other), do: inspect(other)

  defp ok!(r) do
    refute r["result"]["isError"] || r["error"], text_of(r)
    r
  end

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
