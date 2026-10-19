defmodule Hireme.McpCase do
  @moduledoc """
  Tests of MCP over HTTP (`HiremeWeb.Mcp`): requests to a running
  endpoint's `/mcp` under a fresh key, as an agent and as an attacker. A
  client is `%{url, secret, sid}`; its session's event stream is read by a
  linked process that forwards resource updates to the test.
  """

  use ExUnit.CaseTemplate
  import ExUnit.Assertions
  alias Hireme.Keys

  using do
    quote do
      use Hireme.WireCase, async: false
      import Hireme.McpCase
      alias Hireme.Keys
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, server} =
      Bandit.start_link(plug: HiremeWeb.Endpoint, ip: :loopback, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, url: "http://localhost:#{port}/mcp"}
  end

  @doc "An initialized MCP session on a fresh key with `masks`, its event stream open."
  def mcp(%{url: url, session: s}, masks \\ Keys.preset(:read_write)) do
    {:ok, %{secret: secret}} = Keys.mint(s, "mcp", masks)
    p = %{url: url, secret: secret, sid: nil, peer: nil}

    {200, headers, _} =
      post(p, %{
        jsonrpc: "2.0",
        id: 0,
        method: "initialize",
        params: %{
          protocolVersion: "2025-06-18",
          capabilities: %{},
          clientInfo: %{name: "test", version: "0"}
        }
      })

    p = %{p | sid: header(headers, "mcp-session-id")}
    {202, _, _} = post(p, %{jsonrpc: "2.0", method: "notifications/initialized"})
    listen(p)
    p
  end

  @doc "One message POSTed: `{status, headers, body}`."
  def post(p, msg, extra \\ []) do
    request = {to_charlist(p.url), headers(p) ++ extra, ~c"application/json", JSON.encode!(msg)}

    {:ok, {{_, status, _}, headers, body}} =
      :httpc.request(:post, request, [timeout: 120_000], body_format: :binary)

    {status, headers, body}
  end

  defp headers(p) do
    auth = if p.secret, do: [{~c"authorization", ~c"Bearer " ++ to_charlist(p.secret)}], else: []
    sid = if p.sid, do: [{~c"mcp-session-id", to_charlist(p.sid)}], else: []
    peer = if p[:peer], do: [{~c"x-real-ip", to_charlist(p.peer)}], else: []
    [{~c"accept", ~c"application/json, text/event-stream"}] ++ auth ++ sid ++ peer
  end

  def header(headers, name),
    do: Enum.find_value(headers, fn {k, v} -> if to_string(k) == name, do: to_string(v) end)

  @doc "A request's decoded answer."
  def call(p, method, params) do
    id = System.unique_integer([:positive])
    {status, _, body} = post(p, %{jsonrpc: "2.0", id: id, method: method, params: params})
    assert status == 200, "#{method}: HTTP #{status} #{body}"
    JSON.decode!(body)
  end

  # The session's event stream, read by a linked process; it says when it is
  # open, so nothing written after `mcp/2` returns goes unheard.
  defp listen(p) do
    me = self()

    spawn_link(fn ->
      # Its own profile, so no request queues behind the open stream on one connection.
      profile = :"mcp_stream_#{System.unique_integer([:positive])}"
      {:ok, _} = :inets.start(:httpc, profile: profile)

      {:ok, ref} =
        :httpc.request(
          :get,
          {to_charlist(p.url), headers(p)},
          [],
          [sync: false, stream: :self],
          profile
        )

      sse(ref, me, "")
    end)

    receive do
      :listening -> :ok
    after
      5_000 -> flunk("the event stream did not open")
    end
  end

  defp sse(ref, to, buf) do
    receive do
      {:http, {^ref, :stream_start, _}} ->
        send(to, :listening)
        sse(ref, to, buf)

      {:http, {^ref, :stream, chunk}} ->
        [rest | events] = String.split(buf <> chunk, "\n\n") |> Enum.reverse()

        for e <- Enum.reverse(events),
            "data: " <> data <- String.split(e, "\n"),
            {:ok, %{"method" => "notifications/resources/updated", "params" => %{"uri" => uri}}} <-
              [JSON.decode(data)],
            do: send(to, {:updated, uri})

        sse(ref, to, rest)

      {:http, {^ref, _}} ->
        :ok
    end
  end

  @doc "Whether `uri` was announced within `ms`."
  def updated(_p, uri, ms \\ 5_000) do
    receive do
      {:updated, ^uri} -> true
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
