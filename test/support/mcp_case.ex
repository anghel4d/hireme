defmodule Hireme.McpCase do
  @moduledoc """
  Tests through the real `hireme-mcp` binary, speaking MCP over stdio to a
  running endpoint. They need the binary (`cargo build -p hireme-mcp`):
  `HIREME_MCP=<path> mix test test/hireme_web/mcp_test.exs`.
  """

  use ExUnit.CaseTemplate
  import ExUnit.Assertions
  alias Hireme.Keys

  using do
    quote do
      use Hireme.WireCase, async: false
      import Hireme.McpCase
      alias Hireme.Keys

      @moduletag :mcp
      if System.get_env("HIREME_MCP") in [nil, ""],
        do: @moduletag(skip: "set HIREME_MCP to a built hireme-mcp to run the MCP tests")
    end
  end

  setup do
    {:ok, server} =
      Bandit.start_link(plug: HiremeWeb.Endpoint, ip: :loopback, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, bin: System.get_env("HIREME_MCP"), port: port}
  end

  @doc "A connected `hireme-mcp` on a fresh key with `masks`, as a port."
  def mcp(%{bin: bin, port: port, session: s}, masks \\ Keys.preset(:read_write)) do
    {:ok, %{secret: secret}} = Keys.mint(s, "mcp", masks)

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
      clientInfo: %{name: "test", version: "0"}
    })

    line(p, %{jsonrpc: "2.0", method: "notifications/initialized"})
    # Until the wire session is up, the tools say so; wait for it.
    wait_connected(p, 50)
    p
  end

  def line(p, msg), do: send(p, {self(), {:command, JSON.encode!(msg) <> "\n"}})

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

  def call(p, method, params) do
    id = System.unique_integer([:positive])
    line(p, %{jsonrpc: "2.0", id: id, method: method, params: params})
    reply(p, id)
  end

  # Notifications that arrive while waiting for a reply are kept for `updated/3`.
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

  @doc "Whether `uri` was announced within `ms`, reading any lines still on the port."
  def updated(p, uri, ms \\ 5_000) do
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

  def tool(p, name, args), do: call(p, "tools/call", %{name: name, arguments: args})
  def tools(p), do: call(p, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])

  def text_of(%{"result" => %{"content" => content}}),
    do: Enum.map_join(content, "\n", & &1["text"])

  def text_of(other), do: inspect(other)

  def ok!(r) do
    refute r["result"]["isError"] || r["error"], text_of(r)
    r
  end

  def error?(%{"result" => %{"isError" => true}}), do: true
  def error?(%{"error" => _}), do: true
  def error?(_), do: false
end
