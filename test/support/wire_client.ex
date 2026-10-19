defmodule Hireme.WireClient do
  @moduledoc """
  A wire client over a real `/wire` WebSocket, as an agent or a browser
  tab speaks to the node: it sends frames and delivers every frame it
  receives to its owner as `{:wire, client, %{kind, flags, rev, body}}`.
  """

  use GenServer
  alias HiremeWeb.Wire.Codec

  def connect(port, origin \\ nil) do
    {:ok, pid} = GenServer.start_link(__MODULE__, {self(), port, origin})
    pid
  end

  def send_frame(client, frame), do: GenServer.call(client, {:send, frame})

  def close(client), do: GenServer.stop(client)

  @doc "Waits for the next frame of `kind` from `client`; frames of other kinds before it are returned too."
  def await(client, kind, timeout \\ 3_000, seen \\ []) do
    receive do
      {:wire, ^client, %{kind: ^kind} = f} -> {f, Enum.reverse(seen)}
      {:wire, ^client, f} -> await(client, kind, timeout, [f | seen])
    after
      timeout ->
        raise "no #{kind} within #{timeout} ms; saw #{inspect(Enum.map(seen, & &1.kind))}"
    end
  end

  @doc "Sends one put in its own OPS frame and waits for its verdict: `{:ack, id}` or `{:nack, refusal}`."
  def put(client, op) do
    send_frame(client, HiremeWeb.Wire.Codec.frame(:OPS, 0, [<<1::little-32, 0::32>>, op.raw]))

    receive do
      {:wire, ^client,
       %{
         kind: :ACK,
         body: <<1::little-32, 0::32, _::little-64, _::little-64, id::little-32, _::32>>
       }} ->
        {:ack, id}

      {:wire, ^client,
       %{kind: :NACK, body: <<1::little-32, 0::32, _::little-64, code::little-16, _::binary>>}} ->
        {:nack, Hireme.Schema.refusal_name(code)}
    after
      3_000 -> ExUnit.Assertions.flunk("no verdict")
    end
  end

  @doc "The PATCHes `client` receives until it has been quiet for `quiet_ms`."
  def patches(client, quiet_ms, acc \\ []) do
    receive do
      {:wire, ^client, %{kind: :PATCH} = f} -> patches(client, quiet_ms, [f | acc])
      {:wire, ^client, _} -> patches(client, quiet_ms, acc)
    after
      quiet_ms -> Enum.reverse(acc)
    end
  end

  @doc "Sends an RPC and waits for its REPLY: `{:ok, result}` or `{:error, error}`."
  def rpc(client, id, method, params) do
    send_frame(client, Codec.encode_rpc(id, method, JSON.encode!(params)))
    reply(client, id)
  end

  defp reply(client, id) do
    {%{body: body}, _} = await(client, :REPLY)

    case body do
      <<^id::little-32, ok, 0::24, n::little-32, json::binary-size(n), _::binary>> ->
        if ok == 1, do: {:ok, JSON.decode!(json)}, else: {:error, JSON.decode!(json)}

      _ ->
        reply(client, id)
    end
  end

  @impl GenServer
  def init({owner, port, origin}) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    headers = if origin, do: [{"origin", origin}], else: []
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/wire", headers)
    {conn, status, resp_headers, early} = upgrade_response(conn, ref, nil, [], [])
    {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, status, resp_headers)
    s = %{owner: owner, conn: conn, ref: ref, ws: ws}

    # Frames the node sent at once (a BYE to a session past a cap) can ride
    # the same read as the 101; they are decoded now, not dropped.
    ws =
      Enum.reduce(early, ws, fn data, ws ->
        {:ok, ws, messages} = Mint.WebSocket.decode(ws, data)
        Enum.each(messages, &deliver(&1, s))
        ws
      end)

    {:ok, %{s | ws: ws}}
  end

  defp upgrade_response(conn, ref, status, headers, early) do
    receive do
      msg ->
        {:ok, conn, responses} = Mint.WebSocket.stream(conn, msg)

        {status, headers, early, done} =
          Enum.reduce(responses, {status, headers, early, false}, fn
            {:status, ^ref, s}, {_, h, e, d} -> {s, h, e, d}
            {:headers, ^ref, h}, {s, _, e, d} -> {s, h, e, d}
            {:data, ^ref, data}, {s, h, e, d} -> {s, h, e ++ [data], d}
            {:done, ^ref}, {s, h, e, _} -> {s, h, e, true}
            _, acc -> acc
          end)

        if done and is_integer(status),
          do: {conn, status, headers, early},
          else: upgrade_response(conn, ref, status, headers, early)
    after
      3_000 -> raise "no WebSocket upgrade"
    end
  end

  @impl GenServer
  def handle_call({:send, frame}, _from, s) do
    {:ok, ws, data} = Mint.WebSocket.encode(s.ws, {:binary, frame})

    case Mint.WebSocket.stream_request_body(s.conn, s.ref, data) do
      {:ok, conn} ->
        {:reply, :ok, %{s | ws: ws, conn: conn}}

      # The node already closed this carrier: that is the answer.
      {:error, conn, _reason} ->
        send(s.owner, {:wire, self(), %{kind: :CLOSE, flags: 0, rev: 0, body: ""}})
        {:reply, {:error, :closed}, %{s | ws: ws, conn: conn}}
    end
  end

  @impl GenServer
  def handle_info(msg, s) do
    case Mint.WebSocket.stream(s.conn, msg) do
      {:ok, conn, responses} ->
        s = %{s | conn: conn}

        s =
          Enum.reduce(responses, s, fn
            {:data, ref, data}, s when ref == s.ref ->
              {:ok, ws, messages} = Mint.WebSocket.decode(s.ws, data)
              Enum.each(messages, &deliver(&1, s))
              %{s | ws: ws}

            _, s ->
              s
          end)

        {:noreply, s}

      _ ->
        {:noreply, s}
    end
  end

  defp deliver({:binary, frame}, s) do
    {:ok, kind, flags, rev, body} = Codec.decode(frame)
    send(s.owner, {:wire, self(), %{kind: kind, flags: flags, rev: rev, body: body}})
  end

  defp deliver({:close, code, reason}, s),
    do: send(s.owner, {:wire, self(), %{kind: :CLOSE, flags: 0, rev: code, body: reason}})

  defp deliver(_other, _s), do: :ok
end
