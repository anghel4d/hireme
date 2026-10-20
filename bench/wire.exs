# The wire against docs/rebuild.md's bounds:
#
#   BOOT <= 2 MiB deflated at 10k applications
#   PATCH <= 64 KiB per burst
#   judge <= 200 us in the NIF (every shape's p99, via Hireme.Kernel.judge/3)
#   op round trip p50 <= 5 ms on loopback
#   256 ops per OPS frame
#
# and the measurements beside them: the agent_write cap against a key
# writing flat out, and the 64-op batch.
#
#   DATABASE_PATH=/tmp/hireme-bench.db HIREME_GATE=off PHX_SERVER=true PORT=4100 \
#     mix run bench/wire.exs
#
# With the gate measured too (UDP 4433 free; the probe is the gate's example):
#
#   cargo build --release --manifest-path native/Cargo.toml -p gate --example probe
#   DATABASE_PATH=/tmp/hireme-bench.db PHX_SERVER=true PORT=4100 GATE_SOCKET=/tmp/g.sock \
#     BENCH_PROBE=native/target/release/examples/probe mix run bench/wire.exs
#
# DATABASE_PATH must name a file that does not exist yet: every number is for
# a fresh account on an empty database, seeded through OPS frames the way a
# client writes. Sizes are exact; times are wall clock on this machine, with
# the seed and counts printed so a run can be repeated. One JSON line per
# bound goes to stdout at the end, and the run exits 1 if any bound fails.

alias Hireme.{Accounts, Keys, Schema}
alias HiremeWeb.Session
alias HiremeWeb.Wire.Codec
import Ecto.Query, only: [from: 2]

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
        {:as_of, %Date{} = d} -> {Codec.as_of_col(), 1, Codec.day_to_wire(d)}
        {name, v} -> cell(Map.fetch!(cols, to_string(name)), v)
      end)

    flags = if(opts[:keyed], do: 1, else: 0)
    {System.unique_integer([:positive, :monotonic]), :put, flags, t.id, 0, nil, encoded}
  end

  defp cell(col, v) do
    ty = Codec.cell_type(col)
    v = Codec.to_wire(col, v)
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

  # An operator's or an agent's prose: notes, a battleplan, a letter.
  def prose(n) do
    for(_ <- 1..n, do: Enum.random(@words))
    |> Enum.chunk_every(12)
    |> Enum.map_join(". ", &String.capitalize(Enum.join(&1, " ")))
  end

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
            company: "Company #{rem(i * 7919, 9973)}",
            role:
              "#{Enum.random(~w(Staff Senior Principal Lead))} #{Enum.random(~w(Platform Systems Runtime Infra Data))} Engineer #{i}",
            location:
              "#{Enum.random(~w(Berlin Lisbon Toronto Zurich Tallinn Austin Kyoto Oslo Dublin Remote))}, #{rem(i, 97)}",
            listing_raw: Bench.listing(i),
            # Every inline text column filled, as a worked desk has them.
            notes: Bench.prose(60),
            battleplan: Bench.prose(120),
            letter_raw: Bench.prose(220),
            listing_url: "https://jobs.example.com/#{i}",
            canonical_url: "https://jobs.example.com/#{i}",
            score_100: rem(i * 37, 101)
          })
        end

      {t, {_frames, op}} =
        Bench.us(fn -> Bench.send_ops(op, Codec.encode_ops(ops), length(ops)) end)

      {op, [Bench.patches(watcher, 20) | sizes], [t | times]}
    end)
  end)

IO.puts(:stderr, "bench: seeded #{apps} applications in #{div(seed_us, 1000)} ms")

## BOOT for a fresh client of the same account.

{boot_frames, _} = Bench.open(:ticket, Accounts.ticket(session), "bench-cold")
boot = Enum.filter(boot_frames, &(&1.kind == :BOOT))
boot_bytes = boot |> Enum.map(& &1.bytes) |> Enum.sum()
boot_raw = boot |> Enum.map(&byte_size(&1.body)) |> Enum.sum()

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

# And a burst of 64 prose edits, an agent rewriting notes, plans and letters.
prose_edits =
  for i <- 1..64 do
    Bench.put(
      :applications,
      %{
        canonical_url: "https://jobs.example.com/#{i * 17}",
        notes: Bench.prose(60),
        battleplan: Bench.prose(120),
        letter_raw: Bench.prose(220)
      },
      keyed: true
    )
  end

{_frames, op} = Bench.send_ops(op, Codec.encode_ops(prose_edits), 64)
prose_burst = watcher |> Bench.patches(100) |> Enum.sum()

## 256 ops per OPS frame: a full frame is taken whole; one more is not a frame.

full = for i <- 1..256, do: Bench.put(:items, %{kind: :skill, key: "post #{i}", title: "post"})
{frames, op} = Bench.send_ops(op, Codec.encode_ops(full), 256)

acked =
  frames
  |> Enum.map(&Bench.decode/1)
  |> Enum.filter(&(&1.kind == :ACK))
  |> Enum.map(fn %{body: <<n::little-32, _::binary>>} -> n end)
  |> Enum.sum()

over =
  Codec.encode_ops(
    for i <- 1..257, do: Bench.put(:items, %{kind: :skill, key: "over #{i}", title: "over"})
  )

over_answer = Session.frame(over, op)

over_refused =
  case over_answer do
    {:stop, _, _, _} -> true
    {:push, frames, _} -> not Enum.any?(frames, &(Bench.decode(&1).kind == :ACK))
    {:ok, _} -> false
  end

port = String.to_integer(System.get_env("PORT", "4100"))

## judge across Rustler: Hireme.Kernel.judge/3 on the sequencer's own
## resource (the 10k desk), as check 4 calls it, for each op shape.

[{sequencer, _}] = Registry.lookup(Hireme.Sequencer.Registry, account_id)
kernel = :sys.get_state(sequencer).kernel

app_ids =
  Hireme.Repo.all(
    from(a in Hireme.Rows.Application, select: a.id, order_by: fragment("random()"), limit: 500)
  )

judge_shapes = %{
  "score edit" => fn i -> %{score_100: rem(i, 100)} end,
  "prose edit" => fn i -> %{notes: Bench.prose(60 + rem(i, 40))} end
}

{judge_p99, judge_refused} =
  for {shape, cells} <- judge_shapes, reduce: {%{}, 0} do
    {p99s, refused} ->
      {times, refused} =
        Enum.map_reduce(1..2_000, refused, fn i, refused ->
          id = Enum.at(app_ids, rem(i, length(app_ids)))
          {op_id, :put, _, subject, _, _, encoded} = Bench.put(:applications, cells.(i))
          raw = IO.iodata_to_binary(Codec.encode_op({op_id, :put, 0, subject, id, nil, encoded}))
          now = DateTime.utc_now()

          ctx = %{
            actor: :human,
            key_id: nil,
            now_day: Codec.day_to_wire(DateTime.to_date(now)),
            now_s: DateTime.to_unix(now),
            session_label: "bench",
            held_ids: [],
            target: id
          }

          t0 = System.monotonic_time(:microsecond)
          {result, _} = Hireme.Kernel.judge(kernel, raw, ctx)
          t = System.monotonic_time(:microsecond) - t0
          {t, if(match?({:ok, _}, result), do: refused, else: refused + 1)}
        end)

      {Map.put(p99s, shape, Bench.percentile(times, 99)), refused}
  end

## Op round trip across the loopback: one put over the /wire WebSocket, ACK back.

# BENCH_NETEM (netem's arguments, e.g. "delay 25ms loss 1%") puts a lossy
# link on lo for the round trip and the carrier, and only inside a named
# network namespace (bench/netns.sh), never on the machine's own lo.
netem = System.get_env("BENCH_NETEM")

qdisc = fn args ->
  {_, 0} = System.cmd("sudo", ["-n", "tc", "qdisc" | args], stderr_to_stdout: true)
end

if netem do
  {name, 0} = System.cmd("ip", ["netns", "identify"])
  if String.trim(name) == "", do: raise("BENCH_NETEM runs only inside a named netns")
  qdisc.(["replace", "dev", "lo", "root", "netem" | String.split(netem)])
  IO.puts(:stderr, "bench: netem #{netem} on #{String.trim(name)}'s lo")
end

roundtrips =
  if HiremeWeb.Endpoint.config(:server) do
    {sock, buf} = Bench.WS.connect(port)

    :ok =
      Bench.WS.send_bin(sock, Codec.encode_hello(:ticket, Accounts.ticket(session), "bench-rt"))

    {_, state} = Bench.WS.until(sock, buf, :BOOT)

    {times, _} =
      Enum.map_reduce(1..300, state, fn i, {buf, pending} ->
        frame =
          Codec.encode_ops([Bench.put(:items, %{kind: :skill, key: "rt #{i}", title: "rt"})])

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

    # The HELLO carries a key's secret: a private directory, the file
    # written 0600, both gone after.
    dir =
      Path.join(
        System.tmp_dir!(),
        "hireme-bench-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    file = Path.join(dir, "hello")
    File.touch!(file)
    File.chmod!(file, 0o600)
    File.write!(file, Codec.encode_hello(:key, carrier_key, "bench-carrier"))

    try do
      for _ <- 1..8 do
        args = ["hello", url, "--frame", file] ++ if(hash, do: ["--hash", hash], else: [])
        {out, 0} = System.cmd(probe, args)

        %{"bulk_ms" => ms} =
          out |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

        round(ms * 1000)
      end
    after
      File.rm_rf!(dir)
    end
  else
    _ -> []
  end

if netem, do: qdisc.(["del", "dev", "lo", "root"])

## The agent's budget: a read/write key writing flat out, 64 ops a batch.

{:ok, %{secret: secret}} =
  Keys.mint(
    Hireme.Repo.get(Hireme.Rows.Session, session.id, skip_account: true),
    "bench-agent",
    Keys.preset(:read_write)
  )

{_, agent} = Bench.open(:key, secret, "bench-agent")
{1, _, agent} = Bench.rpc(agent, 1, "lease.claim", %{"count" => 0})

# agent_write is a wall-clock-minute window; start the batches just past a
# minute boundary so the run measures one window, not two.
Process.sleep(60_000 - rem(System.os_time(:millisecond), 60_000) + 200)

{agent_results, _} =
  Enum.map_reduce(1..12, agent, fn b, agent ->
    batch =
      for i <- 1..64,
          do: Bench.put(:items, %{kind: :skill, key: "agent #{b}.#{i}", title: "agent"})

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
    frames: length(boot),
    raw: boot_raw,
    note: "every text column filled, texts whole"
  }),
  Bench.line("patch_bytes_per_64_op_burst", burst, 64 * 1024, "bytes", %{note: "score edits"}),
  Bench.line("patch_bytes_per_64_prose_edit_burst", prose_burst, 64 * 1024, "bytes", %{
    note: "notes, battleplan and letter_raw rewritten"
  }),
  Bench.line(
    "patch_bytes_per_256_op_seed_frame_max",
    patch_sizes |> Enum.map(&Enum.sum/1) |> Enum.max(),
    64 * 1024,
    "bytes",
    %{
      note: "a 256-application insert frame, summed over the PATCH frames it causes",
      largest_patch_frame: patch_sizes |> List.flatten() |> Enum.max(fn -> 0 end)
    }
  ),
  Bench.line(
    # Every shape's p99, across the NIF boundary, on a normal scheduler.
    "judge_worst_shape_p99_us_at_#{apps}_apps_via_nif",
    judge_p99 |> Map.values() |> Enum.max(),
    200,
    "us",
    %{p99_by_shape: judge_p99, refused: judge_refused, calls: 2_000 * map_size(judge_shapes)}
  ),
  Bench.line(
    # The bound is on loopback; under netem the number is a measurement.
    if(netem, do: "op_round_trip_p50_us_netem", else: "op_round_trip_p50_us_loopback"),
    (roundtrips != [] && Bench.percentile(roundtrips, 50)) || nil,
    if(netem, do: nil, else: 5_000),
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

# A bound that fails fails the run.
failed = for %{pass: false, bound: name} <- lines, do: name

if failed != [] do
  IO.puts(:stderr, "bench: FAILED #{Enum.join(failed, ", ")}")
  System.halt(1)
end
