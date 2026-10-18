# The wire against docs/rebuild.md's bounds:
#
#   BOOT <= 2 MiB deflated at 10k applications with listing_raw deferred
#   PATCH <= 64 KiB per burst
#   find p99 <= 10 ms at 50k places
#   op round trip p50 <= 5 ms on loopback
#   256 ops per OPS frame
#
# and the measurements beside them: the agent_write cap against a key
# writing flat out, and the 64-op batch.
#
#   DATABASE_PATH=/tmp/hireme-bench.db HIREME_GATE=off PHX_SERVER=true PORT=4100 \
#     mix run bench/wire.exs
#
# DATABASE_PATH must name a file that does not exist yet: every number is for
# a fresh account on an empty database, seeded through OPS frames the way a
# client writes. Sizes are exact; times are wall clock on this machine, with
# the seed and counts printed so a run can be repeated. One JSON line per
# bound goes to stdout at the end.

alias Hireme.{Accounts, Keys, Schema}
alias HiremeWeb.Session
alias HiremeWeb.Wire.Codec

defmodule Bench do
  @moduledoc false

  # ---- a session hosted in this process, as /wire or the gate hosts one

  def open(cred, credential, label) do
    {:ok, s} =
      Session.open(%{peer_ip: "127.0.0.1", origin: HiremeWeb.Endpoint.url(), carrier: :ws})

    {:push, frames, s} = Session.frame(Codec.encode_hello(cred, credential, label), s)
    {Enum.map(frames, &decode/1), s}
  end

  def decode(frame) do
    {:ok, kind, flags, rev, body} = Codec.decode(frame)
    %{kind: kind, flags: flags, rev: rev, body: body, bytes: byte_size(frame)}
  end

  # A carrier answers PING with PONG, or the session ends at 45 s.
  def pong(frames, s) do
    Enum.reduce(frames, s, fn f, s ->
      case decode(f) do
        %{kind: :PING, body: body} ->
          {:ok, n} = Codec.nonce(body)

          case Session.frame(Codec.ping(:PONG, n), s) do
            {:ok, s} -> s
            {:push, _, s} -> s
          end

        _ ->
          s
      end
    end)
  end

  # Push one frame, then feed the session its mail until `n` verdicts are out.
  # Answers the verdict frames and every PATCH the session pushed, raw.
  def send_ops(s, frame, n) do
    {pushed, s} =
      case Session.frame(frame, s) do
        {:ok, s} -> {[], s}
        {:push, frames, s} -> {frames, s}
      end

    pump(s, n, pushed)
  end

  def pump(s, n, acc) do
    if verdicts(acc) >= n do
      {acc, s}
    else
      receive do
        msg ->
          case Session.info(msg, s) do
            {:push, frames, s} -> pump(pong(frames, s), n, acc ++ frames)
            {:ok, s} -> pump(s, n, acc)
          end
      after
        30_000 -> raise "no verdicts after 30 s (#{verdicts(acc)} of #{n})"
      end
    end
  end

  # A passive subscriber in its own process, as another tab is: it keeps the
  # byte size of every PATCH it is pushed, and hands them over on request.
  def watcher(ticket) do
    parent = self()

    spawn_link(fn ->
      {_, s} = open(:ticket, ticket, "bench-watcher")
      send(parent, :watching)
      watch(s, [])
    end)
    |> tap(fn _ -> receive do: (:watching -> :ok) end)
  end

  defp watch(s, sizes) do
    receive do
      {:take, from} ->
        send(from, {:patches, Enum.reverse(sizes)})
        watch(s, [])

      msg ->
        case Session.info(msg, s) do
          {:push, frames, s} ->
            new = for f <- frames, %{kind: :PATCH} = d <- [decode(f)], do: d.bytes
            watch(pong(frames, s), Enum.reverse(new) ++ sizes)

          {:ok, s} ->
            watch(s, sizes)
        end
    end
  end

  # The PATCH bytes the watcher got since the last take, after `settle` ms.
  def patches(watcher, settle) do
    Process.sleep(settle)
    send(watcher, {:take, self()})
    receive do: ({:patches, sizes} -> sizes)
  end

  defp verdicts(frames) do
    frames
    |> Enum.map(&decode/1)
    |> Enum.filter(&(&1.kind in [:ACK, :NACK]))
    |> Enum.map(fn %{body: <<n::little-32, _::binary>>} -> n end)
    |> Enum.sum()
  end

  def rpc(s, id, method, params) do
    {:push, frames, s} = Session.frame(Codec.encode_rpc(id, method, Jason.encode!(params)), s)

    %{
      body: <<^id::little-32, ok, _::binary-3, len::little-32, json::binary-size(len), _::binary>>
    } =
      frames |> Enum.map(&decode/1) |> Enum.find(&(&1.kind == :REPLY))

    {ok, Jason.decode!(json), s}
  end

  # ---- ops built as a client builds them: named, typed cells

  def put(table, cells, opts \\ []) do
    t = Schema.table(table)
    cols = Map.new(t.cols, &{&1.name, &1})

    encoded =
      Enum.map(cells, fn
        {:as_of, %Date{} = d} -> {Codec.as_of_col(), 1, Date.diff(d, ~D[1970-01-01])}
        {name, v} -> cell(Map.fetch!(cols, to_string(name)), v)
      end)

    flags = if(opts[:keyed], do: 1, else: 0)
    {System.unique_integer([:positive, :monotonic]), :put, flags, t.id, 0, nil, encoded}
  end

  defp cell(col, v) do
    ty = Codec.cell_type(col)
    v = if Map.get(col, :deferred), do: v, else: Codec.to_wire(col, v)
    {col.id, ty, if(ty == 4, do: v * 1.0, else: v)}
  end

  # ---- deterministic data

  @words ~w(platform distributed systems latency reliability observability rust elixir erlang
    kubernetes postgres sqlite storage replication consensus raft paxos compiler runtime kernel
    networking quic tls security incident oncall mentorship roadmap ownership architecture design
    review performance profiling caching queue stream batch pipeline ingestion schema migration
    api grpc http websocket frontend typescript wasm browser accessibility testing property fuzz
    benchmark capacity planning budget hiring team lead staff senior principal remote hybrid onsite
    benefits equity salary visa relocation travel customers product research inference training
    model evaluation dataset gpu cluster scheduler autoscaling cost efficiency documentation)

  def listing(i) do
    n = 450 + rem(i * 7919, 500)

    body =
      for(_ <- 1..n, do: Enum.random(@words))
      |> Enum.chunk_every(14)
      |> Enum.map_join(".\n", &Enum.join(&1, " "))

    "Role #{i}\n\nAbout the team\n#{body}\n"
  end

  def percentile(samples, p) do
    sorted = Enum.sort(samples)
    Enum.at(sorted, min(length(sorted) - 1, trunc(Float.ceil(p / 100 * length(sorted))) - 1))
  end

  def us(fun) do
    {t, v} = :timer.tc(fun)
    {t, v}
  end

  def line(name, value, bound, unit, extra \\ %{}) do
    ok = if is_number(bound), do: value <= bound, else: nil
    Map.merge(%{bound: name, value: value, limit: bound, unit: unit, pass: ok}, extra)
  end
end

defmodule Bench.WS do
  @moduledoc false
  import Bitwise
  # A minimal RFC 6455 client over gen_tcp: one binary message out, masked;
  # messages in, unmasked. Enough to time a frame across the loopback.

  def connect(port) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, nodelay: true])
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :ok =
      :gen_tcp.send(sock, [
        "GET /wire HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nUpgrade: websocket\r\n",
        "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n",
        "Origin: #{HiremeWeb.Endpoint.url()}\r\n\r\n"
      ])

    {:ok, rest} = headers(sock, "")
    {sock, rest}
  end

  defp headers(sock, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        if head =~ ~r/^HTTP\/1\.1 101/, do: {:ok, rest}, else: raise("upgrade refused: #{head}")

      [_] ->
        {:ok, more} = :gen_tcp.recv(sock, 0, 5_000)
        headers(sock, acc <> more)
    end
  end

  def send_bin(sock, payload) do
    mask = :crypto.strong_rand_bytes(4)
    len = byte_size(payload)

    head =
      cond do
        len < 126 -> <<0x82, 1::1, len::7>>
        len < 65_536 -> <<0x82, 1::1, 126::7, len::16>>
        true -> <<0x82, 1::1, 127::7, len::64>>
      end

    :ok = :gen_tcp.send(sock, [head, mask, masked(payload, mask)])
  end

  defp masked(payload, <<a, b, c, d>>) do
    for {byte, i} <- Enum.with_index(:binary.bin_to_list(payload)), into: <<>> do
      <<Bitwise.bxor(byte, Enum.at([a, b, c, d], rem(i, 4)))>>
    end
  end

  # Next binary message, with the leftover bytes.
  def recv(sock, buf) do
    case parse(buf) do
      {:ok, payload, rest} ->
        {payload, rest}

      :more ->
        {:ok, more} = :gen_tcp.recv(sock, 0, 10_000)
        recv(sock, buf <> more)
    end
  end

  defp parse(<<_fin_op, 0::1, 126::7, len::16, p::binary-size(len), rest::binary>>),
    do: {:ok, p, rest}

  defp parse(<<_fin_op, 0::1, 127::7, len::64, p::binary-size(len), rest::binary>>),
    do: {:ok, p, rest}

  defp parse(<<_fin_op, 0::1, len::7, p::binary-size(len), rest::binary>>) when len < 126,
    do: {:ok, p, rest}

  defp parse(_), do: :more

  # The next whole frame of kind id `kind`, raw, read by its header alone:
  # no inflate, no parse. Answers the frame, the frames after it, and the
  # socket's leftover bytes.
  def raw_until(sock, buf, frames, kind) do
    case Codec.split(frames, 64 <<< 20) do
      {:ok, <<_len::little-32, ^kind, _::binary>> = frame, rest} ->
        {frame, rest, buf}

      {:ok, _other, rest} ->
        raw_until(sock, buf, rest, kind)

      :more ->
        {payload, buf} = recv(sock, buf)
        raw_until(sock, buf, frames <> payload, kind)
    end
  end

  # Frames until one is `kind`; a message may carry several frames.
  def until(sock, buf, kind), do: until(sock, buf, kind, "")

  def until(sock, buf, kind, frames) do
    case Codec.split(frames, 64 <<< 20) do
      {:ok, frame, rest} ->
        {:ok, k, _, _, body} = Codec.decode(frame)
        if k == kind, do: {body, {buf, rest}}, else: until(sock, buf, kind, rest)

      :more ->
        {payload, buf} = recv(sock, buf)
        until(sock, buf, kind, frames <> payload)
    end
  end
end

Logger.configure(level: :warning)
database = System.get_env("DATABASE_PATH") || raise "DATABASE_PATH must name a fresh file"
seed = String.to_integer(System.get_env("BENCH_SEED", "20261018"))
apps = String.to_integer(System.get_env("BENCH_APPS", "10000"))
places = String.to_integer(System.get_env("BENCH_PLACES", "50000"))
:rand.seed(:exsss, {seed, seed, seed})

{:ok, _, session} =
  Accounts.sign_in_with(:email, %{subject: "bench@example.com", display: "bench"}, %{
    ip: "127.0.0.1"
  })

account_id = session.account_id
Hireme.Repo.put_account(account_id)
IO.puts(:stderr, "bench: account #{account_id} on #{database}, seed #{seed}")

# The operator's session (a browser ticket) seeds: operator writes are not
# under the agent's per-key budget.
{[_welcome, _boot | _], op} = Bench.open(:ticket, Accounts.ticket(session), "bench-operator")

# A second browser session watches, as another tab would: its PATCH frames
# are what a burst costs a subscriber.
watcher = Bench.watcher(Accounts.ticket(session))

## Seed 10k applications, 256 ops per OPS frame, each with its raw listing.

{seed_us, {op, patch_sizes, frame_us}} =
  Bench.us(fn ->
    1..apps
    |> Enum.chunk_every(256)
    |> Enum.reduce({op, [], []}, fn chunk, {op, sizes, times} ->
      ops =
        for i <- chunk do
          Bench.put(:applications, %{
            company: "Company #{rem(i, 1500)}",
            role: "Engineer #{i}",
            location: Enum.random(~w(Berlin Lisbon Toronto Remote Zurich Tallinn)),
            listing_raw: Bench.listing(i),
            listing_url: "https://jobs.example.com/#{i}",
            canonical_url: "https://jobs.example.com/#{i}",
            score_100: rem(i * 37, 101)
          })
        end

      {t, {_frames, op}} =
        Bench.us(fn -> Bench.send_ops(op, Codec.encode_ops(ops), length(ops)) end)

      {op, [Enum.sum(Bench.patches(watcher, 20)) | sizes], [t | times]}
    end)
  end)

IO.puts(:stderr, "bench: seeded #{apps} applications in #{div(seed_us, 1000)} ms")

## BOOT for a fresh client of the same account.

{boot_frames, _} = Bench.open(:ticket, Accounts.ticket(session), "bench-cold")
boot = Enum.filter(boot_frames, &(&1.kind == :BOOT))
boot_bytes = boot |> Enum.map(& &1.bytes) |> Enum.sum()

## One burst of 64 ordinary edits, as an agent's batch would land: its PATCH.

edits =
  for i <- 1..64 do
    Bench.put(
      :applications,
      %{canonical_url: "https://jobs.example.com/#{i * 13}", score_100: rem(i, 100)},
      keyed: true
    )
  end

{_frames, op} = Bench.send_ops(op, Codec.encode_ops(edits), 64)
burst = watcher |> Bench.patches(100) |> Enum.sum()

## 256 ops per OPS frame: a full frame is taken whole; one more is not a frame.

full = for i <- 1..256, do: Bench.put(:net_entries, %{kind: :post, title: "post #{i}"})
{frames, op} = Bench.send_ops(op, Codec.encode_ops(full), 256)

acked =
  frames
  |> Enum.map(&Bench.decode/1)
  |> Enum.filter(&(&1.kind == :ACK))
  |> Enum.map(fn %{body: <<n::little-32, _::binary>>} -> n end)
  |> Enum.sum()

over =
  Codec.encode_ops(
    for i <- 1..257, do: Bench.put(:net_entries, %{kind: :post, title: "over #{i}"})
  )

over_answer = Session.frame(over, op)

over_refused =
  case over_answer do
    {:stop, _, _, _} -> true
    {:push, frames, _} -> not Enum.any?(frames, &(Bench.decode(&1).kind == :ACK))
    {:ok, _} -> false
  end

## find at 50k places.

{place_us, op} =
  Bench.us(fn ->
    1..places
    |> Enum.chunk_every(256)
    |> Enum.reduce(op, fn chunk, op ->
      ops =
        for i <- chunk do
          Bench.put(:places, %{
            kind: :city,
            geonames_id: 1_000_000 + i,
            name: "City #{i}",
            region: Enum.random(~w(Europe Americas Asia Africa Oceania)),
            population: 10_000 + rem(i * 7907, 5_000_000),
            as_of: ~D[2026-01-01]
          })
        end

      {_frames, op} = Bench.send_ops(op, Codec.encode_ops(ops), length(ops))
      op
    end)
  end)

IO.puts(:stderr, "bench: seeded #{places} places in #{div(place_us, 1000)} ms")

# What the world lens and an agent ask: a name, a sorted filtered page, a
# substring, and the default page in id order.
queries =
  for i <- 1..500 do
    case rem(i, 4) do
      0 ->
        {:name, %{"table" => "places", "where" => %{"name" => "City #{:rand.uniform(places)}"}}}

      1 ->
        {:sorted,
         %{
           "table" => "places",
           "where" => %{"region" => "Europe"},
           "order" => "population",
           "desc" => true,
           "limit" => 50
         }}

      2 ->
        {:like,
         %{
           "table" => "places",
           "where" => %{"name" => %{"like" => "City #{:rand.uniform(999)}"}},
           "limit" => 25
         }}

      3 ->
        {:page, %{"table" => "places", "where" => %{"kind" => "city"}, "limit" => 100}}
    end
  end

# Timed over a real /wire session, a server process of its own: from the
# RPC leaving to the whole REPLY frame arriving. Nothing the client does
# with the answer (inflate, JSON) is on the clock; it is checked after.
port = String.to_integer(System.get_env("PORT", "4100"))

find_times =
  if HiremeWeb.Endpoint.config(:server) do
    {sock, buf} = Bench.WS.connect(port)

    :ok =
      Bench.WS.send_bin(sock, Codec.encode_hello(:ticket, Accounts.ticket(session), "bench-find"))

    {_, state} = Bench.WS.until(sock, buf, :BOOT)

    {times, _} =
      Enum.map_reduce(Enum.with_index(queries, 1), state, fn {{shape, q}, id}, {buf, pending} ->
        frame = Codec.encode_rpc(id, "find", Jason.encode!(q))
        t0 = System.monotonic_time(:microsecond)
        :ok = Bench.WS.send_bin(sock, frame)
        {reply, rest, buf} = Bench.WS.raw_until(sock, buf, pending, Schema.frame(:reply))
        t = System.monotonic_time(:microsecond) - t0
        {:ok, :REPLY, _, _, <<^id::little-32, ok, _::binary>>} = Codec.decode(reply)
        if ok != 1, do: IO.puts(:stderr, "bench: find refused #{inspect(q)}")
        {{shape, t}, {buf, rest}}
      end)

    :gen_tcp.close(sock)
    times
  else
    IO.puts(:stderr, "bench: the endpoint is not serving (PHX_SERVER=true); no find timing")
    []
  end

find_shapes =
  find_times
  |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  |> Map.new(fn {k, ts} -> {k, Bench.percentile(ts, 99)} end)

find_times = Enum.map(find_times, &elem(&1, 1))

## Op round trip across the loopback: one put over the /wire WebSocket, ACK back.

roundtrips =
  if HiremeWeb.Endpoint.config(:server) do
    {sock, buf} = Bench.WS.connect(port)

    :ok =
      Bench.WS.send_bin(sock, Codec.encode_hello(:ticket, Accounts.ticket(session), "bench-rt"))

    {_, state} = Bench.WS.until(sock, buf, :BOOT)

    {times, _} =
      Enum.map_reduce(1..300, state, fn i, {buf, pending} ->
        frame = Codec.encode_ops([Bench.put(:net_entries, %{kind: :draft, title: "rt #{i}"})])
        t0 = System.monotonic_time(:microsecond)
        :ok = Bench.WS.send_bin(sock, frame)
        {_, state} = Bench.WS.until(sock, buf, :ACK, pending)
        {System.monotonic_time(:microsecond) - t0, state}
      end)

    :gen_tcp.close(sock)
    # The first few warm the path; the rest are the measurement.
    Enum.drop(times, 20)
  else
    IO.puts(
      :stderr,
      "bench: the endpoint is not serving (PHX_SERVER=true); no loopback round trip"
    )

    []
  end

## Carrier: HELLO to a whole BOOT on a fresh connection, /wire WebSocket
## against the gate (WebTransport, through BENCH_PROBE, the gate's probe).

# A key, as an agent dials: a ticket needs a page's origin, which the probe
# has none of. Eight per carrier keeps both under the failed-attempt limit.
{:ok, %{secret: carrier_key}} =
  Keys.mint(
    Hireme.Repo.get(Hireme.Rows.Session, session.id, skip_account: true),
    "bench-carrier",
    Keys.preset(:read_write)
  )

carrier_ws =
  if HiremeWeb.Endpoint.config(:server) do
    for _ <- 1..8 do
      t0 = System.monotonic_time(:microsecond)
      {sock, buf} = Bench.WS.connect(port)

      :ok =
        Bench.WS.send_bin(
          sock,
          Codec.encode_hello(:ticket, Accounts.ticket(session), "bench-carrier")
        )

      {_, _} = Bench.WS.until(sock, buf, :BOOT)
      :gen_tcp.close(sock)
      System.monotonic_time(:microsecond) - t0
    end
  else
    []
  end

carrier_gate =
  with probe when is_binary(probe) <- System.get_env("BENCH_PROBE"),
       url when is_binary(url) <- HiremeWeb.Gate.url() do
    hash = HiremeWeb.Gate.cert_hash()

    file =
      Path.join(System.tmp_dir!(), "hireme-bench-hello-#{System.unique_integer([:positive])}")

    File.write!(file, Codec.encode_hello(:key, carrier_key, "bench-carrier"))

    for _ <- 1..8 do
      args = ["hello", url, "--frame", file] ++ if(hash, do: ["--hash", hash], else: [])
      {out, 0} = System.cmd(probe, args)
      %{"bulk_ms" => ms} = out |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
      round(ms * 1000)
    end
    |> tap(fn _ -> File.rm(file) end)
  else
    _ -> []
  end

## The agent's budget: a read/write key writing flat out, 64 ops a batch.

{:ok, %{secret: secret}} =
  Keys.mint(
    Hireme.Repo.get(Hireme.Rows.Session, session.id, skip_account: true),
    "bench-agent",
    Keys.preset(:read_write)
  )

{_, agent} = Bench.open(:key, secret, "bench-agent")
{1, _, agent} = Bench.rpc(agent, 1, "lease.claim", %{"count" => 0})

{agent_results, _} =
  Enum.map_reduce(1..12, agent, fn b, agent ->
    batch = for i <- 1..64, do: Bench.put(:net_entries, %{kind: :draft, title: "agent #{b}.#{i}"})
    {frames, agent} = Bench.send_ops(agent, Codec.encode_ops(batch), 64)
    decoded = Enum.map(frames, &Bench.decode/1)

    acks =
      for %{kind: :ACK, body: <<n::little-32, _::binary>>} <- decoded, reduce: 0, do: (a -> a + n)

    {acks, agent}
  end)

agent_acked = Enum.sum(agent_results)

## Report.

lines = [
  Bench.line("boot_deflated_bytes_at_#{apps}_apps", boot_bytes, 2 * 1024 * 1024, "bytes", %{
    frames: length(boot)
  }),
  Bench.line("patch_bytes_per_64_op_burst", burst, 64 * 1024, "bytes"),
  Bench.line(
    "patch_bytes_per_256_op_seed_frame_max",
    Enum.max(patch_sizes),
    64 * 1024,
    "bytes",
    %{note: "a 256-application insert burst with listing_raw deferred"}
  ),
  Bench.line(
    "find_p99_us_at_#{places}_places_over_wire",
    Bench.percentile(find_times, 99),
    10_000,
    "us",
    %{
      p50: Bench.percentile(find_times, 50),
      queries: length(find_times),
      p99_by_shape: find_shapes
    }
  ),
  Bench.line(
    "op_round_trip_p50_us_loopback",
    (roundtrips != [] && Bench.percentile(roundtrips, 50)) || nil,
    5_000,
    "us",
    %{p99: roundtrips != [] && Bench.percentile(roundtrips, 99), samples: length(roundtrips)}
  ),
  Bench.line("carrier_hello_to_boot_p50_us", nil, nil, "us", %{
    ws: carrier_ws != [] && Bench.percentile(carrier_ws, 50),
    gate: carrier_gate != [] && Bench.percentile(carrier_gate, 50),
    note:
      "fresh connection to a whole BOOT on loopback; the gate's case for itself is lossy networks and 0.5-RTT, which loopback cannot show"
  }),
  Bench.line("ops_acked_in_one_full_frame", acked, nil, "ops", %{
    pass: acked == 256,
    frame_257_refused: over_refused
  }),
  Bench.line("seed_frame_p50_us_256_ops", Bench.percentile(frame_us, 50), nil, "us", %{
    p99: Bench.percentile(frame_us, 99)
  }),
  Bench.line("agent_ops_acked_of_768_in_a_minute", agent_acked, nil, "ops", %{
    pass: agent_acked in (600 - 63)..600,
    note:
      "agent_write is 600/min per key, a batch is taken whole or refused rate; 12 batches of 64"
  })
]

for l <- lines, do: IO.puts(Jason.encode!(l))
