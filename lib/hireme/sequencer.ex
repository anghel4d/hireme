defmodule Hireme.Sequencer do
  @moduledoc """
  One process per account, the only writer of its tables: it orders every
  `put`, `drop` and `command`, judges each in six checks, writes it, keeps
  the 24 h ledger and sends the deltas.

  Ops arrive from wire sessions as casts and are taken in arrival order,
  up to 64 per SQLite transaction (the writer lock is taken once per
  batch). Each op runs in its own savepoint, so a refusal undoes exactly
  that op. The checks, in order:

  1. **grant** (`Hireme.Grants`): the write mask covers the domain; a drop
     needs `may_delete`; a key may not run a `human_only` command or write a
     `human_only` column.
  2. **lease** (`Hireme.Lease`): the session holds the channel; an
     application another session holds is `leased`.
  3. **shape**: the table or command, its columns and their wire types,
     the target row, the natural key of a keyed op, required columns.
  4. **domain**: the kernel's `judge` (`Hireme.Kernel`), which also returns
     the op's realization as effects: the cells to write, derived ones
     included (a stage move's pips, a listing's keywords, an event).
  5. **provenance** (`Hireme.Provenance`): metrics need `as_of` and are
     never older than what is stored; prose needs `expect_rev` and a source;
     culture and ratings need a trusted host.
  6. **limits**: `too_large` (1 MiB of text per op), `rate` (a key's
     `:agent_write` budget), `cap` (rows per account per table).

  Then the effects are written (`rev + 1` on every row written, one
  citation per metric or prose cell), the ledger records the verdict, and
  the op's rows go to the kernel resource at once, so the next op in the
  batch is judged on them. After the commit every subscriber gets one
  PATCH for the batch, filtered by its read mask, and only then do the
  submitting sessions get their ACK and NACK frames: an op's PATCH never
  follows its ACK.

  The ledger keeps each writer's ACKs for 24 h: a resent `op_id` that was
  ACKed answers its first ACK and writes nothing. A refused op wrote
  nothing and is not recorded, so its resend is judged again against the
  state it now meets.

  A deleted row takes its dependents with it: rows whose required ref
  names it are deleted, nullable refs are cleared, each as a write of its
  own, so subscribers and the kernel see every row that moved.
  """

  # Temporary: a crashed sequencer is started again by its next caller
  # (sessions are told BYE restart and reconnect), never in a hot loop.
  use GenServer, restart: :temporary

  import Bitwise, only: [<<<: 2]
  import Ecto.Query
  require Logger

  alias Hireme.{Grants, Kernel, Lease, Provenance, Repo, Schema, Security, Store}
  alias Hireme.Schema.Parser
  alias HiremeWeb.Wire.Codec

  @batch 64
  @max_op_text 1 <<< 20
  @idle_ms :timer.minutes(10)
  @as_of 0xFFF0
  @source 0xFFF1
  @ledger_s 24 * 3600
  @purge_ms :timer.hours(1)

  # ---------------------------------------------------------------- API

  @doc false
  def child_spec(account_id),
    do: %{
      id: {__MODULE__, account_id},
      start: {__MODULE__, :start_link, [account_id]},
      restart: :temporary
    }

  @doc false
  def start_link(account_id),
    do: GenServer.start_link(__MODULE__, account_id, name: via(account_id))

  defp via(account_id), do: {:via, Registry, {Hireme.Sequencer.Registry, account_id}}

  @doc "The account's sequencer, started when it is not running; nil when it cannot start."
  def whereis(account_id) do
    # The registry drops a dead sequencer's entry only once it sees the
    # exit; until then the entry is skipped and a fresh one registers over it.
    case Registry.lookup(Hireme.Sequencer.Registry, account_id) do
      [{pid, _}] -> if Process.alive?(pid), do: pid, else: start(account_id)
      [] -> start(account_id)
    end
  end

  defp start(account_id) do
    case DynamicSupervisor.start_child(Hireme.Sequencer.Dynamic, {__MODULE__, account_id}) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        pid

      {:error, reason} ->
        Logger.error("sequencer #{account_id} did not start: #{inspect(reason)}")
        nil
    end
  end

  defp with_pid(account_id, fun, retry? \\ true) do
    case whereis(account_id) do
      nil ->
        {:error, :unavailable}

      pid ->
        try do
          fun.(pid)
        catch
          # The sequencer stopped idle between the lookup and the call: it
          # stops only with an empty mailbox, so the call never ran.
          :exit, {reason, {GenServer, :call, _}} when retry? and reason in [:noproc, :normal] ->
            with_pid(account_id, fun, false)
        end
    end
  end

  @doc """
  A wire session joins: `session` is `%{id, label, grants, key_id,
  session_id}` and the caller's pid is the subscriber. Returns `{:ok,
  %{rev, lease, frames}}` where `frames` is the initial train: a BOOT, or
  a PATCH when `snapshot_rev` is current, the last flagged END. Deltas then
  arrive as `{:sequencer, :patch, rev, body}` and verdicts as
  `{:sequencer, :verdicts, rev, acks, nacks}`.
  """
  def subscribe(account_id, session, snapshot_rev),
    do:
      with_pid(
        account_id,
        &GenServer.call(&1, {:subscribe, self(), session, snapshot_rev}, 30_000)
      )

  @doc """
  Submits decoded ops (`HiremeWeb.Wire.Codec.ops/1`) for the calling
  session. When the sequencer cannot run, every op is answered `internal`.
  """
  def submit(account_id, ops) do
    case whereis(account_id) do
      nil ->
        send(self(), {:sequencer, :verdicts, 0, [], Enum.map(ops, &nack(&1, :internal, %{}))})

      pid ->
        GenServer.cast(pid, {:ops, self(), ops})
    end

    :ok
  end

  @doc """
  Runs ops for a caller that is not a wire session (the importer), as
  `actor` (`%{label, grants, key_id}`), and answers their verdicts:
  `{:ok, rev, acks, nacks}`. Subscribers get the PATCH as usual.
  """
  def call(account_id, actor, ops),
    do: with_pid(account_id, &GenServer.call(&1, {:call, actor, ops}, :infinity))

  @doc "A lease request; see `Hireme.Lease`."
  def lease(account_id, request) do
    case with_pid(account_id, &GenServer.call(&1, {:lease, self(), request})) do
      {:error, :unavailable} -> {:refused, :internal, %{}}
      reply -> reply
    end
  end

  @doc "Whether the account's sequencer is running (it is not started)."
  def running?(account_id), do: Registry.lookup(Hireme.Sequencer.Registry, account_id) != []

  @doc "The account's committed rev."
  def rev(account_id), do: with_pid(account_id, &GenServer.call(&1, :rev))

  @doc "Rebuilds the kernel resource from SQLite."
  def resync(account_id), do: with_pid(account_id, &GenServer.call(&1, :resync, 60_000))

  # ------------------------------------------------------------ server

  @impl GenServer
  def init(account_id) do
    Repo.put_account(account_id)

    {rev, text_bytes} =
      Repo.one!(
        from(a in Hireme.Rows.Account,
          where: a.id == ^account_id,
          select: {a.desk_rev, a.text_bytes}
        ),
        skip_account: true
      )

    state = %{
      account_id: account_id,
      rev: rev,
      lease: %Lease{},
      lease_rows: [],
      subs: %{},
      counts: %{},
      kernel: nil,
      rows: nil,
      backfill_after: 0,
      text_bytes: text_bytes
    }

    # A revoked or changed key, a revoked browser session or a suspension is
    # heard here too: its sessions stop writing the moment the sequencer
    # knows, not when their carrier closes.
    Phoenix.PubSub.subscribe(Hireme.PubSub, Hireme.Audit.topic(account_id))
    # Read after subscribing, so a resume in between is not lost.
    state = %{state | lease: paused_keys(account_id)}
    # The first purge, and every hour's, runs as messages between batches.
    send(self(), :purge)
    send(self(), :backfill)
    {:ok, rebuild(state), @idle_ms}
  end

  @impl GenServer
  def handle_call({:subscribe, pid, session, snapshot_rev}, _from, state) do
    held =
      Enum.count(state.subs, fn {_, s} -> session.key_id != nil and s.key_id == session.key_id end)

    # One key holds at most this many wire sessions at once.
    if held >= Security.key_sessions(),
      do: {:reply, {:error, :too_many}, state, @idle_ms},
      else: subscribe_session(pid, session, snapshot_rev, state)
  end

  def handle_call({:lease, pid, request}, _from, state) do
    {reply, after_} =
      case lease_allowed(request, subscriber(state, request)) do
        :ok -> lease_request(request, pid, state)
        refused -> {refused, state}
      end

    send(self(), {:audit_channels, state.lease, after_.lease})
    {:reply, reply, after_, @idle_ms}
  rescue
    e ->
      Logger.error(
        "sequencer #{state.account_id}: lease #{inspect(request)}: #{Exception.message(e)}"
      )

      {:reply, {:refused, :internal, %{}}, state, @idle_ms}
  end

  def handle_call({:call, actor, ops}, _from, state) do
    {state, acks, nacks} = run_as(actor, ops, state)
    {:reply, {:ok, state.rev, acks, nacks}, state, @idle_ms}
  end

  def handle_call(:rev, _from, state), do: {:reply, state.rev, state, @idle_ms}
  def handle_call(:resync, _from, state), do: {:reply, :ok, rebuild(state), @idle_ms}

  @impl GenServer
  def handle_cast({:ops, pid, ops}, state) do
    submissions = [{pid, ops}] |> take_more(length(ops)) |> Enum.filter(&within_rate(&1, state))
    {state, _} = run(submissions, state)
    {:noreply, state, @idle_ms}
  end

  # A key's budget per minute: ops (:agent_write) and their text bytes
  # (:agent_write_bytes); either one spent refuses the whole submission.
  defp spend(key_id, n, bytes) do
    with :ok <- Security.hit(:agent_write, key_id, max(n, 1)) do
      if bytes > 0, do: Security.hit(:agent_write_bytes, key_id, bytes), else: :ok
    end
  end

  # Check 6's `rate` is taken as ops arrive, for every op a key sends,
  # refused ones too: a flood of cheap refusals still spends the budget.
  defp within_rate({pid, ops}, state) do
    bytes =
      Enum.reduce(ops, 0, fn op, n ->
        n +
          Enum.reduce(op.cells, 0, fn
            {_, 2, v}, m -> m + byte_size(v)
            _, m -> m
          end)
      end)

    with %{key_id: key_id} when key_id != nil <- state.subs[pid],
         {:error, retry_ms} <- spend(key_id, length(ops), bytes) do
      nacks = Enum.map(ops, &nack(&1, :rate, %{retry_ms: retry_ms}))
      send(pid, {:sequencer, :verdicts, state.rev, [], nacks})
      false
    else
      _ -> true
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    case state.subs do
      %{^pid => %{ref: ^ref, id: id}} ->
        after_ = %{state | subs: Map.delete(state.subs, pid), lease: Lease.leave(state.lease, id)}
        send(self(), {:audit_channels, state.lease, after_.lease})
        after_ = if MapSet.size(Lease.held(state.lease, id)) > 0, do: rescan(after_), else: after_
        {:noreply, broadcast_leases(after_, []), @idle_ms}

      _ ->
        {:noreply, state, @idle_ms}
    end
  end

  def handle_info({:bye, who, _reason}, state) do
    ended = for {pid, sub} <- state.subs, ends?(who, sub), do: {pid, sub}

    after_ =
      Enum.reduce(ended, state, fn {pid, sub}, st ->
        if sub.ref, do: Process.demonitor(sub.ref, [:flush])
        %{st | subs: Map.delete(st.subs, pid), lease: Lease.leave(st.lease, sub.id)}
      end)

    if ended != [], do: send(self(), {:audit_channels, state.lease, after_.lease})
    held = Enum.any?(ended, fn {_, sub} -> MapSet.size(Lease.held(state.lease, sub.id)) > 0 end)
    after_ = if held, do: rescan(after_), else: after_
    {:noreply, broadcast_leases(after_, []), @idle_ms}
  end

  # The operator resumed a paused key: its sessions may claim again.
  def handle_info({:resume, {:key, id}}, state) do
    # The row is the truth: a pause written after this message was sent stands.
    lease =
      case Repo.one(from(k in Hireme.Rows.ApiKey, where: k.id == ^id, select: k.paused_at)) do
        nil -> Lease.lift(state.lease, id)
        since -> state.lease |> Lease.lift(id) |> Lease.hold(id, since)
      end

    {:noreply, %{state | lease: lease}, @idle_ms}
  end

  def handle_info(:backfill, state) do
    {:noreply, backfill(state), @idle_ms}
  rescue
    e ->
      Logger.error("sequencer #{state.account_id}: keywords backfill: #{Exception.message(e)}")
      {:noreply, state, @idle_ms}
  end

  def handle_info({:audit_channels, before, after_}, state) do
    audit_channels(before, after_, state.account_id)
    {:noreply, state, @idle_ms}
  rescue
    e ->
      Logger.error("sequencer #{state.account_id}: lease audit: #{Exception.message(e)}")
      {:noreply, state, @idle_ms}
  end

  def handle_info(:purge, state) do
    Process.send_after(self(), :purge, @purge_ms)
    handle_info(:purge_more, state)
  end

  # One chunk per message, so ops queued meanwhile run between chunks.
  def handle_info(:purge_more, state) do
    if purge_ledger(Store.now()), do: send(self(), :purge_more)
    # The purge moved the ledger's count; the next write reads it afresh.
    ledger = Schema.table("op_ledger").id
    {:noreply, %{state | counts: Map.delete(state.counts, ledger)}, @idle_ms}
  end

  def handle_info(:timeout, %{subs: subs} = state) when map_size(subs) == 0,
    do: {:stop, :normal, state}

  def handle_info(:timeout, state), do: {:noreply, state, @idle_ms}
  def handle_info(_, state), do: {:noreply, state, @idle_ms}

  defp subscribe_session(pid, session, snapshot_rev, state) do
    now = Store.now()
    ref = Process.monitor(pid)
    sub = Map.merge(session, %{ref: ref, pid: pid})

    state = %{
      state
      | subs: Map.put(state.subs, pid, sub),
        lease: Lease.join(state.lease, session, now)
    }

    # A key's masks may have changed since its snapshot, so only the
    # operator's session resumes; a key always gets a BOOT.
    resume = snapshot_rev == state.rev and snapshot_rev > 0 and session.key_id == nil

    {state, body} =
      if resume,
        do: {state, wire_tables(state, session.grants, now)},
        else: snapshot(session.grants, state, now)

    kind = if resume, do: :PATCH, else: :BOOT
    frames = [Codec.frame(kind, state.rev, body, end: true, deflate: true)]
    state = broadcast_leases(state, except: pid)

    reply = %{
      rev: state.rev,
      lease: Lease.channel?(state.lease, session.id),
      frames: frames,
      pid: self()
    }

    {:reply, {:ok, reply}, state, @idle_ms}
  end

  # The backfill's ops are the operator's (writer 0) and ledgered: their ids
  # must not repeat across restarts as unique_integer's do.
  defp random_op_id do
    <<id::unsigned-63, _::1>> = :crypto.strong_rand_bytes(8)
    id
  end

  defp ends?({:key, id}, %{key_id: id}) when id != nil, do: true
  defp ends?({:session, id}, %{session_id: id}) when id != nil, do: true
  defp ends?(:account, _sub), do: true
  defp ends?(_who, _sub), do: false

  # Ops from a caller that is not a wire session, as a passing session.
  defp run_as(actor, ops, state) do
    key = {:call, make_ref()}
    session = Map.merge(%{id: System.unique_integer([:positive]), session_id: nil}, actor)
    sub = Map.merge(session, %{ref: nil, pid: key})

    state = %{
      state
      | subs: Map.put(state.subs, key, sub),
        lease: Lease.join(state.lease, session, Store.now())
    }

    {state, verdicts} = run([{key, ops}], state)

    state = %{
      state
      | subs: Map.delete(state.subs, key),
        lease: Lease.leave(state.lease, session.id)
    }

    acks = for {^key, {:ack, a}} <- verdicts, do: a
    nacks = for {^key, {:nack, n}} <- verdicts, do: n
    {state, acks, nacks}
  end

  # Keywords are the kernel's extraction from listing_raw, stored with its
  # version. When the kernel's version moves, every listing is put again
  # through the sequencer, a batch per turn, so the kernel re-extracts it.
  defp backfill(state) do
    version = Kernel.keywords_version()
    held = MapSet.new(Map.keys(state.lease.holder))

    # Held applications wait for their holder to let go; a text that is not
    # UTF-8 (only a hand-edited database has one) is left alone.
    after_id = state.backfill_after

    stale =
      Repo.all(
        from(r in Hireme.Rows.Application,
          where:
            r.id > ^after_id and not is_nil(r.listing_raw) and
              (is_nil(r.keywords_version) or r.keywords_version != ^version),
          select: {r.id, r.listing_raw},
          order_by: r.id,
          limit: ^(@batch + MapSet.size(held))
        )
      )
      |> Enum.reject(fn {id, text} -> id in held or not String.valid?(text) end)
      |> Enum.take(@batch)

    if stale == [] do
      # The scan reached the end; a release starts it again from the top.
      %{state | backfill_after: 0}
    else
      t = Schema.table(:applications)
      listing = col(t, "listing_raw")

      ops =
        for {id, text} <- stale do
          raw =
            Codec.encode_op({random_op_id(), :put, 0, t.id, id, nil, [{listing.id, 2, text}]})

          {:ok, op, ""} = Codec.op(raw)
          op
        end

      {state, acks, nacks} =
        run_as(%{label: "keywords", grants: Grants.operator(), key_id: nil}, ops, state)

      # The cursor walks past refused rows, so they cannot stall the scan.
      send(self(), :backfill)

      if nacks != [],
        do:
          Logger.warning(
            "sequencer #{state.account_id}: keywords backfill refused #{length(nacks)}"
          )

      _ = acks
      %{state | backfill_after: stale |> List.last() |> elem(0)}
    end
  end

  # Ops already waiting join this turn's batches, in arrival order.
  defp take_more(acc, n) when n >= @batch * 4, do: Enum.reverse(acc)

  defp take_more(acc, n) do
    receive do
      {:"$gen_cast", {:ops, pid, ops}} -> take_more([{pid, ops} | acc], n + length(ops))
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ------------------------------------------------------------ batches

  defp run(submissions, state) do
    flat = for {pid, ops} <- submissions, op <- ops, do: {pid, op}

    {state, all} =
      flat
      |> Enum.chunk_every(@batch)
      |> Enum.reduce({state, []}, fn chunk, {state, all} ->
        {state, verdicts} = batch(chunk, state)
        {state, all ++ verdicts}
      end)

    state = broadcast_leases(state, [])
    tallies = Enum.reduce(all, %{}, &tally/2)

    for {pid, {acks, nacks}} <- tallies, sub = state.subs[pid], sub.key_id do
      Hireme.Audit.record(
        :agent_ops,
        %{count: acks + nacks, acks: acks, nacks: nacks},
        %{
          account_id: state.account_id,
          key_id: sub.key_id,
          session_id: nil,
          ip: sub[:ip],
          user_agent: sub[:user_agent]
        }
      )
    end

    {state, all}
  end

  defp tally({pid, {:ack, _}}, t), do: Map.update(t, pid, {1, 0}, fn {a, n} -> {a + 1, n} end)
  defp tally({pid, {:nack, _}}, t), do: Map.update(t, pid, {0, 1}, fn {a, n} -> {a, n + 1} end)

  defp batch(chunk, state) do
    now = Store.now()
    turn = %{now: now, today: DateTime.to_date(now), deltas: [], acked: 0, text: 0}

    result =
      try do
        Store.transaction(fn ->
          {state, turn, verdicts} =
            Enum.reduce(chunk, {state, turn, []}, fn {pid, op}, {state, turn, vs} ->
              {state, turn, verdict} = one(pid, op, state, turn)
              {state, turn, [{pid, verdict} | vs]}
            end)

          rev = state.rev + turn.acked

          if turn.acked > 0 or turn.text != 0 do
            from(a in Hireme.Rows.Account, where: a.id == ^state.account_id)
            |> Repo.update_all([set: [desk_rev: rev], inc: [text_bytes: turn.text]],
              skip_account: true
            )
          end

          {%{state | rev: rev, text_bytes: state.text_bytes + turn.text}, turn,
           Enum.reverse(verdicts)}
        end)
      rescue
        e ->
          Logger.error(
            "sequencer #{state.account_id}: #{Exception.format(:error, e, __STACKTRACE__)}"
          )

          {:error, :raised}
      end

    case result do
      {:ok, {state, turn, verdicts}} ->
        state = if turn.acked > 0, do: %{state | rows: nil}, else: state
        state = publish(turn.deltas, forget_gone(state, turn.deltas))
        deliver(verdicts, state.rev)
        {state, verdicts}

      {:error, reason} ->
        Logger.error("sequencer #{state.account_id}: batch rolled back: #{inspect(reason)}")
        verdicts = for {pid, op} <- chunk, do: {pid, {:nack, nack(op, :internal, %{})}}
        deliver(verdicts, state.rev)
        {rebuild(state), verdicts}
    end
  end

  # Deleted applications leave the claims that held them.
  # (Released ones may have waited for the backfill; see backfill/1.)
  defp forget_gone(state, deltas) do
    ids = for {:gone, %{name: "applications"}, id} <- deltas, do: id
    if ids == [], do: state, else: %{state | lease: Lease.forget(state.lease, ids)}
  end

  defp deliver(verdicts, rev) do
    verdicts
    |> Enum.filter(fn {pid, _} -> is_pid(pid) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {pid, vs} ->
      acks = for {:ack, a} <- vs, do: a
      nacks = for {:nack, n} <- vs, do: n
      send(pid, {:sequencer, :verdicts, rev, acks, nacks})
    end)
  end

  # One op: the ledger, then the checks and the write in a savepoint.
  defp one(pid, op, state, turn) do
    sub = state.subs[pid]

    cond do
      sub == nil ->
        {state, turn, {:nack, nack(op, :lease_missing, %{})}}

      first = ledgered(op.op_id, sub.key_id, turn.now) ->
        {state, turn, first}

      true ->
        :ok = Store.savepoint(:open)

        verdict =
          try do
            judge(op, sub, state, turn)
          rescue
            e in [Ecto.ConstraintError, Ecto.ChangeError, Exqlite.Error] ->
              {refusal, data} = constraint(e)
              {:refused, refusal, data, state}

            # Anything else is a bug, but it costs only this op: the kernel
            # takes an op's rows only once it has been written whole.
            e ->
              Logger.error(
                "sequencer #{state.account_id}: op #{op.op_id}: #{Exception.format(:error, e, __STACKTRACE__)}"
              )

              {:refused, :internal, %{}, state}
          end

        case verdict do
          {:ok, state, after_, ack} ->
            :ok = Store.savepoint(:keep)
            state = record(op, sub, ack, after_.now, state)
            # The account's rev counts writes: an op that wrote nothing (a stage
            # move to where the application stands) moves no rev, or a client's
            # snapshot would lag a PATCH that never came.
            wrote = length(after_.deltas) > length(turn.deltas)
            {state, %{after_ | acked: after_.acked + if(wrote, do: 1, else: 0)}, {:ack, ack}}

          {:refused, refusal, data, state} ->
            :ok = Store.savepoint(:undo)
            {state, turn, {:nack, nack(op, refusal, redact(refusal, data, op, sub))}}
        end
    end
  end

  # A refusal says why in its data (a stage, a rev, a stored date); a key
  # that may not read the table gets only the refusal, never its rows' state.
  # The lease's refusals say nothing of any row: a key that cannot read the
  # table still learns it holds no channel, or that the operator paused it.
  defp redact(:lease_missing, data, _op, _sub), do: data

  defp redact(_refusal, data, op, sub) do
    table =
      case op.verb do
        :command -> (c = Schema.command(op.subject)) && Schema.table(c.table)
        _ -> Schema.table(op.subject)
      end

    if table == nil or Grants.read?(sub.grants, table), do: data, else: %{}
  end

  defp constraint(%Ecto.ChangeError{message: msg}), do: {:type, %{reason: msg}}

  defp constraint(%{message: msg}) do
    cond do
      # The schema's triggers refuse a ref to another account's row.
      msg =~ ~r/\bref \w+\.\w+/ ->
        {:not_found, %{reason: "a ref names no row"}}

      msg =~ "UNIQUE" or msg =~ "unique" ->
        {:natural_key, %{reason: "a unique column already holds this value"}}

      msg =~ "FOREIGN KEY" or msg =~ "foreign" ->
        {:not_found, %{reason: "a ref names no row"}}

      true ->
        {:internal, %{}}
    end
  end

  defp nack(op, refusal, {:json, data}),
    do: %{
      op_id: op.op_id,
      code: Schema.refusal(refusal),
      data: data |> JSON.decode!() |> reasoned(refusal) |> JSON.encode!()
    }

  defp nack(op, refusal, data),
    do: %{
      op_id: op.op_id,
      code: Schema.refusal(refusal),
      data: JSON.encode!(data |> reasoned(refusal) |> Map.put(:refusal, refusal))
    }

  # docs/rebuild.md, 'The sequencer's checks': "A refusal's `reason` names
  # the cause in the server's words" (every refusal, by shannon's ruling).
  # A site that names its own keeps it; any other gets its code's.
  @reasons %{
    scope: "the key's masks do not allow this",
    human_only: "only the operator's browser session may do this",
    lease_missing: "this session holds no write lease",
    leased: "another session holds this application",
    column: "a column is unknown, not writable, or missing",
    type: "a value does not fit its column",
    not_found: "the row, or a row a ref names, does not exist",
    natural_key: "a row with this natural key already exists",
    stage: "the pipeline does not allow this move",
    fire_hold: "submitted follows only the operator's open_fire",
    heat: "the heat governor defers this move",
    lineage_busy: "the lineage is mid-generation; only new overlays",
    cooldown: "the lineage's cooldown has not passed",
    freshness: "a metric needs as_of no later than today",
    stale: "a newer value is already stored",
    rev: "the row has moved past expect_rev",
    source_missing: "this cell needs a source",
    source_trust: "this source's host is not trusted for this cell",
    too_large: "the op is over its size bound",
    rate: "over the rate limit; retry later",
    cap: "a table or the account is at its cap",
    internal: "the server failed on this op; it wrote nothing"
  }

  @doc """
  `data` with a `reason`: its own, else the refusal code's, marked
  `reason_default: true` so a client can tell the two apart without
  copying the wording.
  """
  def reasoned(data, refusal) when is_map(data) do
    if Map.has_key?(data, :reason) or Map.has_key?(data, "reason"),
      do: data,
      else:
        Map.merge(data, %{
          reason: @reasons[refusal] || String.replace(to_string(refusal), "_", " "),
          reason_default: true
        })
  end

  def reasoned(data, _refusal), do: data

  # op_id is a u64 on the wire and an i64 in SQLite.
  defp signed(id) when id >= 1 <<< 63, do: id - (1 <<< 64)
  defp signed(id), do: id

  # The ledger keeps what a resent op must answer: its ACK. A refused op wrote
  # nothing, so a resend is judged again, against the state it now meets (a
  # lease taken since, a rev moved on). Entries are a key's own, for 24 h.
  defp ledgered(op_id, key_id, now) do
    since = DateTime.add(now, -@ledger_s)

    q =
      from(l in Hireme.Rows.OpLedger,
        where: l.writer == ^(key_id || 0) and l.op_id == ^signed(op_id) and l.inserted_at > ^since
      )

    case Repo.one(q) do
      nil -> nil
      l -> {:ack, %{op_id: op_id, rev: l.ack_rev || 0, id: l.row_id || 0}}
    end
  end

  # The ledger is bounded by its cap without refusing anyone: at the cap the
  # account's oldest entries (1% of it) make room, so a flood of keys costs
  # only its own oldest retries their memory, never the operator a write.
  defp record(op, sub, ack, now, state) do
    t = Schema.table("op_ledger")
    state = counted(state, t)

    evicted =
      if state.counts[t.id] + 1 > t.cap do
        oldest =
          from(l in Hireme.Rows.OpLedger,
            # A subquery is not scoped for us: the account's own oldest.
            where: l.account_id == ^state.account_id,
            order_by: l.id,
            limit: ^div(t.cap, 100),
            select: l.id
          )

        {n, _} = Repo.delete_all(from(l in Hireme.Rows.OpLedger, where: l.id in subquery(oldest)))
        n
      else
        0
      end

    Repo.insert_all(
      Hireme.Rows.OpLedger,
      [
        %{
          account_id: Repo.account_id!(),
          op_id: signed(op.op_id),
          key_id: sub.key_id,
          writer: sub.key_id || 0,
          verb: op.verb,
          subject: op.subject,
          target: op.target,
          row_id: ack.id,
          ack_rev: ack.rev,
          rev: 1,
          inserted_at: now,
          updated_at: now
        }
      ],
      # Only an entry past its 24 h (not yet purged) can be in the way.
      on_conflict: {:replace_all_except, [:id]},
      conflict_target: [:account_id, :writer, :op_id]
    )

    update_in(state.counts[t.id], &(&1 - evicted + 1))
  end

  # Expired entries go in chunks, each its own short write, the ids picked
  # outside the writer lock: a ledger that expired whole (a million rows)
  # never holds other accounts' writes for seconds. `true` while more remain.
  @purge_chunk 5_000
  defp purge_ledger(now) do
    since = DateTime.add(now, -@ledger_s)

    ids =
      Repo.all(
        from(l in Hireme.Rows.OpLedger,
          where: l.inserted_at <= ^since,
          limit: @purge_chunk,
          select: l.id
        )
      )

    if ids != [],
      do:
        Store.write(fn ->
          Repo.delete_all(from(l in Hireme.Rows.OpLedger, where: l.id in ^ids))
        end)

    length(ids) == @purge_chunk
  end

  # ------------------------------------------------------- the checks

  defp judge(op, sub, state, turn) do
    with {:ok, plan} <- resolve(op),
         :ok <- Grants.check(sub.grants, op.verb, plan.command, plan.table, plan.known),
         :ok <- keyed_read(op, plan, sub),
         :ok <- Lease.check(state.lease, sub.id, nil),
         {:ok, plan} <- locate(plan, op),
         :ok <- held_by_none_other(state.lease, sub.id, applications_of(plan, op)),
         {:ok, plan} <- shape(plan, op, sub),
         :ok <- too_large(op),
         {:ok, effects, state} <- domain(plan, op, sub, state, turn),
         {:ok, prov} <- provenance(plan, op, effects, turn),
         {:ok, state, turn, ack} <- write(plan, op, sub, effects, prov, state, turn) do
      {:ok, state, turn, ack}
    else
      {:refused, refusal, data} -> {:refused, refusal, data, state}
      {:refused, refusal, data, state} -> {:refused, refusal, data, state}
    end
  end

  # Check 3 begins here (the table or command exists), ahead of check 1,
  # which needs the table's domain.
  defp resolve(%{verb: :command} = op) do
    case Schema.command(op.subject) do
      nil ->
        {:refused, :not_found, %{command: op.subject}}

      command ->
        table = Schema.table(command.table)
        params = Map.new(command.params, &{&1.id, &1})
        known = for {id, _, _} <- op.cells, p = params[id], p.column, do: col(table, id)

        {:ok,
         %{
           table: table,
           command: command,
           params: params,
           known: known,
           row: nil,
           target: op.target
         }}
    end
  end

  defp resolve(op) do
    case Schema.table(op.subject) do
      %{residency: r} = table when r in [:resident, :server] ->
        known = for {id, _, _} <- op.cells, c = col(table, id), do: c

        {:ok,
         %{table: table, command: nil, params: nil, known: known, row: nil, target: op.target}}

      _ ->
        {:refused, :not_found, %{table: op.subject}}
    end
  end

  # Finds the op's target row: by id, by natural key for a keyed op, or the
  # account's one row of a singleton table.
  defp locate(%{table: table} = plan, op) do
    cond do
      op.keyed ->
        natural(plan, op)

      plan.target > 0 ->
        case fetch(table, plan.target) do
          nil -> {:refused, :not_found, %{table: table.name, id: plan.target}}
          row -> {:ok, %{plan | row: row}}
        end

      table.singleton and op.verb == :put ->
        row = Repo.one(from(r in Schema.row(table.name), limit: 1))
        {:ok, %{plan | row: row, target: (row && row.id) || 0}}

      true ->
        {:ok, plan}
    end
  end

  # The text a row of `table` holds, in bytes, as SQLite stores it: every
  # str, text and json column (deferred ones included). The per-account
  # text budget counts exactly this, before and after each write.
  defp text_bytes(table, ids) when is_list(ids) do
    case for(
           c <- table.cols,
           c.type in [:str, :text, :json],
           do: ~s{coalesce(length(CAST("#{c.name}" AS BLOB)),0)}
         ) do
      [] ->
        0

      parts ->
        marks = Enum.map_join(ids, ",", fn _ -> "?" end)

        sql =
          ~s{SELECT coalesce(sum(#{Enum.join(parts, "+")}),0) FROM "#{table.name}" WHERE id IN (#{marks})}

        %{rows: [[n]]} = Repo.query!(sql, ids, skip_account: true)
        n
    end
  end

  defp text_bytes(table, id), do: text_bytes(table, [id])

  defp col(table, id) when is_integer(id), do: Enum.find(table.cols, &(&1.id == id))
  defp col(table, name), do: Enum.find(table.cols, &(&1.name == name))

  defp fetch(table, id) do
    q = from(r in Schema.row(table.name), where: r.id == ^id)
    q = if table.soft_delete, do: where(q, [r], is_nil(r.deleted_at)), else: q
    Repo.one(q)
  end

  defp natural(%{table: table} = plan, op) do
    typed =
      for {id, _, _} = cell <- op.cells,
          c = col(table, id),
          do: {c.name, Codec.cell_to_value(c, cell)}

    case Enum.find(typed, &match?({_, {:error, _}}, &1)) do
      {name, _} -> {:refused, :type, %{table: table.name, column: name}}
      nil -> natural(plan, op, Map.new(typed, fn {k, {:ok, v}} -> {k, v} end))
    end
  end

  defp natural(%{table: table} = plan, op, values) do
    case Enum.find(table.naturals, fn n ->
           Enum.all?(n.cols, &(values[&1] != nil)) and holds?(table, n.where_term, values)
         end) do
      nil ->
        # Each key with its condition; a key whose columns were all given
        # but whose condition failed is unmet, naming the condition's
        # columns the cells left out ([] when one was given another value).
        unmet =
          for n <- table.naturals, Enum.all?(n.cols, &(values[&1] != nil)) do
            doc = Schema.key_doc(n)
            Map.put(doc, :missing, Enum.reject(doc.reads, &Map.has_key?(values, &1)))
          end

        {:refused, :natural_key,
         %{
           table: table.name,
           reason: "no natural key among the cells",
           keys: Enum.map(table.naturals, &Schema.key_doc/1),
           unmet: unmet
         }}

      %{cols: cols, where_term: term} ->
        q =
          Enum.reduce(cols, from(r in Schema.row(table.name)), fn c, q ->
            where(q, [r], field(r, ^String.to_atom(c)) == ^values[c])
          end)
          |> restrict(table, term)

        q = if table.soft_delete, do: where(q, [r], is_nil(r.deleted_at)), else: q

        case Repo.one(q) do
          nil when op.verb == :drop ->
            {:refused, :not_found, %{table: table.name, key: Map.take(values, cols)}}

          nil ->
            {:ok, plan}

          _row when op.create_only ->
            {:refused, :natural_key, %{table: table.name, key: Map.take(values, cols)}}

          row ->
            {:ok, %{plan | row: row, target: row.id}}
        end
    end
  end

  # A key's partial `where` (the schema's where_term) decides which key the
  # cells name, and bounds its lookup: a country's iso2 never finds a city.
  defp holds?(_table, nil, _values), do: true
  defp holds?(_table, {:not_null, c}, values), do: values[c] != nil
  defp holds?(_table, {:null, c}, values), do: Map.has_key?(values, c) and values[c] == nil

  defp holds?(table, {:eq, c, v}, values),
    do: Map.has_key?(values, c) and values[c] == term_value(table, c, v)

  defp restrict(q, _table, nil), do: q

  defp restrict(q, _table, {:not_null, c}),
    do: where(q, [r], not is_nil(field(r, ^String.to_atom(c))))

  defp restrict(q, _table, {:null, c}), do: where(q, [r], is_nil(field(r, ^String.to_atom(c))))

  defp restrict(q, table, {:eq, c, v}),
    do: where(q, [r], field(r, ^String.to_atom(c)) == ^term_value(table, c, v))

  defp term_value(table, c, v) do
    {:ok, value} = Ecto.Type.cast(Schema.cast_type(col(table, c)), v)
    value
  end

  # A keyed op finds a row by its natural key and answers with its id (or
  # refuses natural_key): a lookup the key must be allowed to make, so it
  # needs the table's read bit as well as its write bit.
  defp keyed_read(%{keyed: true}, %{table: table}, sub) do
    if Grants.read?(sub.grants, table),
      do: :ok,
      else: {:refused, :scope, %{table: table.name, reason: "a keyed op reads the table"}}
  end

  defp keyed_read(_op, _plan, _sub), do: :ok

  defp applications_of(%{table: %{name: "applications"}, target: t}, _op) when t > 0, do: [t]

  # Another table's row belongs to the application its application_id names:
  # the one stored and, when the op moves it, the one its cell names.
  defp applications_of(%{table: table, row: row}, op) do
    case col(table, "application_id") do
      nil ->
        []

      c ->
        cell =
          Enum.find_value(op.cells, fn
            {id, 1, v} when id == c.id -> v
            _ -> nil
          end)

        Enum.uniq(Enum.reject([row && row.application_id, cell], &is_nil/1))
    end
  end

  defp held_by_none_other(lease, sid, apps) do
    Enum.find_value(apps, :ok, fn app ->
      case Lease.check(lease, sid, app) do
        :ok -> nil
        refused -> refused
      end
    end)
  end

  # Check 3: every cell names a writable column (or a param) of its type.
  defp shape(%{table: table} = plan, %{verb: :drop} = op, _sub) do
    cond do
      plan.row == nil ->
        {:refused, :not_found, %{table: table.name, id: op.target}}

      op.expect_rev != nil and op.expect_rev != plan.row.rev ->
        {:refused, :rev, %{table: table.name, rev: plan.row.rev}}

      table.append_only ->
        {:refused, :column, %{table: table.name, reason: "append_only"}}

      true ->
        {:ok, Map.put(plan, :changes, %{})}
    end
  end

  defp shape(%{command: command, params: params} = plan, %{verb: :command} = op, _sub) do
    with {:ok, values} <-
           reduce_cells(op.cells, fn {id, _, _} = cell ->
             case params[id] do
               nil ->
                 {:refused, :column, %{command: command.name, param: id}}

               # An empty required param is a missing one, as the kernel's judge says it.
               p ->
                 case typed(p, cell, command.name) do
                   {:refused, :column, %{reason: "required"}} ->
                     {:refused, :column, %{command: command.name, missing: [p.name]}}

                   other ->
                     other
                 end
             end
           end),
         [] <- for(p <- command.params, p.required, not Map.has_key?(values, p.name), do: p.name),
         :ok <- refs(command.params, values) do
      cond do
        op.target > 0 and plan.row == nil ->
          {:refused, :not_found, %{table: plan.table.name, id: op.target}}

        op.expect_rev != nil and plan.row != nil and op.expect_rev != plan.row.rev ->
          {:refused, :rev, %{table: plan.table.name, rev: plan.row.rev}}

        true ->
          {:ok, Map.put(plan, :changes, values)}
      end
    else
      missing when is_list(missing) ->
        {:refused, :column, %{command: command.name, missing: missing}}

      refused ->
        refused
    end
  end

  defp shape(%{table: table} = plan, op, sub) do
    insert = plan.row == nil
    rev = if insert, do: 0, else: plan.row.rev

    with :ok <- server_written(table),
         :ok <-
           if(table.append_only and not insert,
             do: {:refused, :column, %{table: table.name, reason: "append_only"}},
             else: :ok
           ),
         # expect_rev, when given, is a compare-and-set on the row (0 for a new one).
         :ok <-
           if(op.expect_rev != nil and op.expect_rev != rev,
             do: {:refused, :rev, %{table: table.name, rev: rev}},
             else: :ok
           ),
         {:ok, values} <-
           reduce_cells(op.cells, fn
             {@as_of, _, _} -> :skip
             {@source, _, _} -> :skip
             {id, _, _} = cell -> writable(table, col(table, id), id, cell, sub)
           end),
         :ok <- special_cells(op.cells),
         :ok <- required(table, values, insert),
         :ok <- refs(table.cols, values),
         :ok <-
           if(table.name == "sources", do: Provenance.source_change(plan.row, values), else: :ok) do
      {:ok, Map.put(plan, :changes, values)}
    end
  end

  # A ref names a row of this account (Repo scopes the lookup), or it is
  # refused as if no such row existed: another account's ids say nothing.
  defp refs(cols, values) do
    Enum.find_value(cols, :ok, fn c ->
      id = c.type == :ref and not Map.get(c, :implied, false) and values[c.name]

      if is_integer(id) and not Repo.exists?(from(r in Schema.row(c.ref), where: r.id == ^id)),
        do: {:refused, :not_found, %{column: c.name, id: id}}
    end)
  end

  defp reduce_cells(cells, fun) do
    Enum.reduce_while(cells, {:ok, %{}}, fn cell, {:ok, acc} ->
      case fun.(cell) do
        :skip -> {:cont, {:ok, acc}}
        {:ok, name, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        refused -> {:halt, refused}
      end
    end)
  end

  # A table every declared column of which is readonly (citations) is the
  # server's to write: replicated for reading, never put by an op.
  defp server_written(table) do
    if Enum.all?(table.cols, &(&1.implied or &1.readonly)),
      do: {:refused, :column, %{table: table.name, reason: "the server writes this table"}},
      else: :ok
  end

  defp writable(table, nil, id, _cell, _sub),
    do: {:refused, :column, %{table: table.name, column: id}}

  defp writable(table, col, _id, cell, sub) do
    cond do
      col.implied or col.readonly or col.server_only ->
        {:refused, :column, %{table: table.name, column: col.name, reason: "readonly"}}

      col.private and sub.grants.actor != :operator ->
        {:refused, :column, %{table: table.name, column: col.name, reason: "private"}}

      true ->
        typed(col, cell, table.name)
    end
  end

  defp typed(col, cell, owner) do
    case Codec.cell_to_value(col, cell) do
      {:ok, nil} when col.required ->
        {:refused, :column, %{in: owner, column: col.name, reason: "required"}}

      {:ok, v} ->
        {:ok, col.name, v}

      {:error, :type} ->
        {:refused, :type, %{in: owner, column: col.name, want: col.type}}
    end
  end

  defp special_cells(cells) do
    Enum.reduce_while(cells, :ok, fn
      {@as_of, ty, v}, :ok ->
        if ty == 1 and Codec.day_from_wire(v) != nil,
          do: {:cont, :ok},
          else: {:halt, {:refused, :type, %{column: "as_of", want: :day}}}

      {@source, ty, _}, :ok when ty in [1, 2] ->
        {:cont, :ok}

      {@source, _, _}, :ok ->
        {:halt, {:refused, :type, %{column: "source", want: "source id or URL"}}}

      _, :ok ->
        {:cont, :ok}
    end)
  end

  defp required(_table, _values, false), do: :ok

  defp required(table, values, true) do
    case for(
           c <- table.cols,
           c.required,
           not c.implied,
           not c.readonly,
           c.default == nil,
           values[c.name] == nil,
           do: c.name
         ) do
      [] -> :ok
      missing -> {:refused, :column, %{table: table.name, missing: missing}}
    end
  end

  # Check 4: the kernel judges the op as a plain op on its located row.
  defp domain(plan, op, sub, state, turn) do
    raw = retarget(op.raw, plan.target)

    ctx = %{
      actor: if(sub.grants.actor == :operator, do: :human, else: :key),
      key_id: sub.key_id,
      now_day: Codec.day_to_wire(turn.today),
      now_s: DateTime.to_unix(turn.now),
      session_label: sub.label,
      held_ids: Enum.to_list(Lease.held(state.lease, sub.id)),
      target: plan.target
    }

    case judge_once(state, raw, ctx) do
      {{:ok, effects}, state} ->
        {:ok, effects, state}

      {{:refused, code, data}, state} ->
        {:refused, Schema.refusal_name(code), {:json, data}, state}

      {{:error, :panic}, state} ->
        {:refused, :internal, %{reason: "kernel"}, state}
    end
  end

  defp judge_once(state, raw, ctx) do
    case Kernel.judge(state.kernel, raw, ctx) do
      {{:error, :panic}, _} ->
        state = rebuild(state)
        {result, k} = Kernel.judge(state.kernel, raw, ctx)
        {result, %{state | kernel: k}}

      {result, k} ->
        {result, %{state | kernel: k}}
    end
  end

  # The kernel sees a keyed op as a plain op on the row it named.
  defp retarget(
         <<head::binary-8, verb, flags, subject::binary-2, _target::little-32, rest::binary>>,
         target
       ) do
    flags = Bitwise.band(flags, Bitwise.bnot(0x03))
    <<head::binary, verb, flags, subject::binary, target::little-32, rest::binary>>
  end

  # Check 5, on the cells the effects put on the op's own row.
  defp provenance(%{table: table} = plan, op, effects, turn) do
    own = own_cells(plan, effects)
    names = for {id, _} <- own, c = col(table, id), do: c.name

    if Enum.any?(names, &cited?(table, &1)) do
      as_of =
        Enum.find_value(op.cells, fn
          {@as_of, _, d} -> Codec.day_from_wire(d)
          _ -> nil
        end)

      source_cell =
        Enum.find_value(op.cells, fn
          {@source, _, v} -> v
          _ -> nil
        end)

      with :ok <-
             if(as_of && Date.compare(as_of, Date.add(turn.today, 1)) == :gt,
               do: {:refused, :freshness, %{column: "as_of", reason: "in the future"}},
               else: :ok
             ),
           # Today in UTC, plus the day a writer east of it may already be in.
           new_source =
             is_binary(source_cell) and
               not Repo.exists?(
                 from(x in Hireme.Rows.Source,
                   where: x.url == ^source_cell and is_nil(x.deleted_at)
                 )
               ),
           {:ok, source} <- Provenance.source(source_cell, turn.now),
           ctx = %{as_of: as_of, source: source, expect_rev: op.expect_rev},
           changes = Map.new(names, &{&1, true}),
           {:ok, changes} <- Provenance.check(table, plan.row, changes, ctx) do
        ons = for {k, %Date{} = d} <- changes, String.ends_with?(k, "_on"), do: {k, d}

        {:ok,
         %{
           as_of: as_of,
           source: source,
           ons: Map.new(ons),
           new_source: new_source and source != nil
         }}
      end
    else
      {:ok, nil}
    end
  end

  defp cited?(table, name) do
    c = col(table, name)
    c.metric or c.prose
  end

  defp own_cells(plan, effects) do
    Enum.find_value(effects, [], fn {t, row_id, cells} ->
      if t == plan.table.id and (row_id == plan.target or (row_id == 0 and plan.target == 0)),
        do: cells
    end)
  end

  # Check 6 (`too_large` is taken right after shape, before the kernel spends
  # time on a text it would refuse; `rate` as ops arrive).
  defp too_large(op) do
    text =
      Enum.reduce(op.cells, 0, fn
        {_, 2, v}, n -> n + byte_size(v)
        _, n -> n
      end)

    if text > @max_op_text,
      do: {:refused, :too_large, %{bytes: text, max: @max_op_text}},
      else: :ok
  end

  defp limits(plan, effects, prov, state) do
    citations = Schema.table(:citations)
    sources = Schema.table(:sources)
    # Only the cells the write will cite: a restated one is not (fresh/3).
    cited =
      plan
      |> own_cells(effects)
      |> Enum.reject(&(plan.row != nil and restated?(plan.table, plan.row, &1, prov)))
      |> Enum.count(fn {id, _} -> (c = col(plan.table, id)) && (c.metric or c.prose) end)

    new_source = if prov && prov.new_source, do: [{sources, 1}], else: []

    inserts =
      effects
      |> Enum.filter(fn {_, row_id, _} -> row_id == 0 end)
      |> Enum.frequencies_by(&elem(&1, 0))
      |> Enum.map(fn {id, n} -> {Schema.table(id), n} end)
      |> Enum.filter(fn {t, _} -> t.cap end)

    checks = if cited > 0, do: [{citations, cited} | inserts], else: inserts

    # A source the op's citation created (provenance) is already in SQLite:
    # a count read now holds it, a cached one does not yet.
    state =
      if new_source != [] and not is_map_key(state.counts, sources.id),
        do: update_in(counted(state, sources).counts[sources.id], &(&1 - 1)),
        else: state

    checks =
      (new_source ++ checks)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {t, ns} -> {t, Enum.sum(ns)} end)

    state = Enum.reduce(checks, state, fn {t, _}, st -> counted(st, t) end)

    case Enum.find(checks, fn {t, n} -> state.counts[t.id] + n > t.cap end) do
      nil -> {:ok, state}
      {t, _} -> {:refused, :cap, %{table: t.name, cap: t.cap}, state}
    end
  end

  # A capped table's row count, read from SQLite once and then moved with
  # every insert and delete (count_deltas). A tombstone is gone (its drop
  # moves the count), so a soft-delete table counts its live rows.
  defp counted(%{counts: counts} = state, table) when is_map_key(counts, table.id), do: state

  defp counted(state, table) do
    q = Schema.row(table.name)
    q = if table.soft_delete, do: where(q, [r], is_nil(r.deleted_at)), else: q
    put_in(state.counts[table.id], Repo.aggregate(q, :count))
  end

  # ----------------------------------------------------------- the write

  defp write(plan, %{verb: :drop} = op, sub, _effects, _prov, state, turn) do
    with :ok <- provenance_kept(plan, sub),
         {deltas, rev} = delete(plan.table, plan.row, turn.now),
         :ok <- cascade_allowed(deltas, sub, state) do
      finish(state, turn, deltas, %{op_id: op.op_id, rev: rev, id: plan.row.id})
    end
  end

  defp write(plan, op, sub, effects, prov, state, turn) do
    # Check 6 (limits) follows the shortcut: a restatement writes nothing,
    # so a table at its cap does not refuse it.
    if unchanged?(plan, op, effects, prov) do
      finish(state, turn, [], %{op_id: op.op_id, rev: plan.row.rev, id: plan.row.id})
    else
      with {:ok, state} <- limits(plan, effects, prov, state),
           do: write_effects(plan, op, sub, effects, prov, state, turn)
    end
  end

  # A put that restates its row exactly (every cell as stored, and for a
  # cited cell the same as_of and the same source as its last citation)
  # writes nothing: no rev, no citation, no text. The same value from a
  # different source is a corroboration and is cited.
  defp unchanged?(%{row: row, table: table}, %{verb: :put}, [{tid, id, cells}], prov)
       when row != nil and tid == table.id and id == row.id do
    Enum.all?(cells, &restated?(table, row, &1, prov))
  end

  defp unchanged?(_plan, _op, _effects, _prov), do: false

  # One cell as `row` stores it, and if cited, the same citation again.
  defp restated?(table, row, {col_id, v}, prov) do
    c = col(table, col_id)
    key = c && String.to_atom(c.name)

    c != nil and Codec.from_wire(c, v) == {:ok, Map.get(row, key)} and
      (not (c.metric or c.prose) or same_citation?(table, row, c, prov))
  end

  defp same_citation?(_table, _row, _col, nil), do: false
  defp same_citation?(_table, _row, _col, %{new_source: true}), do: false

  defp same_citation?(table, row, col, prov) do
    on = col.metric && Map.get(row, String.to_atom(col.name <> "_on"))

    # The last citation's id too, so no citation is not taken for one with
    # no source: an unsourced metric restated is the same citation.
    last =
      Repo.one(
        from(x in Hireme.Rows.Citation,
          where: x.table == ^table.name and x.row_id == ^row.id and x.column == ^col.name,
          order_by: [desc: x.id],
          limit: 1,
          select: {x.id, x.source_id, x.as_of}
        )
      )

    # A metric's date is its `_on`; prose dates only an explicit as_of.
    source = prov.source && prov.source.id

    dated =
      cond do
        col.metric -> on == prov.as_of
        prov.as_of == nil -> true
        true -> match?({_, _, d} when d == prov.as_of, last)
      end

    dated and match?({_, ^source, _}, last)
  end

  # A put that changes some cells cites only those: a cited cell it restates
  # (same value, same citation) is not cited again.
  defp fresh(table, cells, %{plan: %{row: row}, prov: prov}) when row != nil,
    do: Enum.reject(cells, &restated?(table, row, &1, prov))

  defp fresh(_table, cells, _ctx), do: cells

  defp write_effects(plan, op, sub, effects, prov, state, turn) do
    ctx = %{sub: sub, op: op, turn: turn, plan: plan, prov: prov}

    {result, _} =
      Enum.reduce_while(effects, {{:ok, [], %{}, nil}, []}, fn {table_id, row_id, cells},
                                                               {{:ok, deltas, news, ack},
                                                                inserted} ->
        table = Schema.table(table_id)
        before = if row_id == 0, do: 0, else: text_bytes(table, row_id)

        case effect(table, row_id, cells, inserted, ctx) do
          {:ok, row, changed} ->
            moved = {:text, text_bytes(table, row.id) - before}

            own = own?(plan, op, table_id, row_id, ack)

            inserted = if row_id == 0, do: inserted ++ [row.id], else: inserted

            ack =
              if own and ack == nil, do: %{op_id: op.op_id, rev: row.rev, id: row.id}, else: ack

            cited =
              if own and prov, do: cite(table, row, fresh(table, cells, ctx), prov, ctx), else: []

            {:cont,
             {{:ok, deltas ++ [{:put, table, row, changed}, moved | cited], news, ack}, inserted}}

          refused ->
            {:halt, {refused, inserted}}
        end
      end)

    case result do
      {:ok, deltas, _news, ack} ->
        ack = ack || command_ack(plan, op)

        # Claims follow only a write that lands: a refusal in finish rolls
        # the insert back, and its id must not stay leased.
        with {:ok, state, turn, ack} <- finish(state, turn, deltas, ack),
             do: {:ok, adopt(state, sub, deltas), turn, ack}

      refused ->
        refused
    end
  end

  # Every row a delete takes or clears must be one the session could have
  # written itself: in its write mask, and no application another holds.
  defp cascade_allowed(deltas, sub, state) do
    Enum.find_value(deltas, :ok, fn
      {:gone, t, id} -> reach(t, id, sub, state)
      {:put, t, row, _changed} -> reach(t, row.id, sub, state)
      _ -> nil
    end)
  end

  defp reach(t, id, sub, state) do
    cond do
      not Grants.write?(sub.grants, t) ->
        {:refused, :scope, %{table: t.name, reason: "the delete reaches it"}}

      t.name == "applications" ->
        case Lease.check(state.lease, sub.id, id) do
          :ok -> nil
          refused -> refused
        end

      true ->
        nil
    end
  end

  # The op's own row: its target, its insert, or for a command with no target
  # (open_generation names a corporation) the first row it writes on its table.
  defp own?(plan, op, table_id, row_id, ack) do
    table_id == plan.table.id and
      (row_id == plan.target or (row_id == 0 and plan.target == 0) or
         (op.verb == :command and plan.target == 0 and ack == nil))
  end

  defp command_ack(plan, op),
    do: %{op_id: op.op_id, rev: (plan.row && plan.row.rev) || 0, id: plan.target}

  defp adopt(state, %{id: sid}, deltas) do
    lease =
      Enum.reduce(deltas, state.lease, fn
        {:put, %{name: "applications"}, row, :all}, l -> Lease.adopt(l, sid, row.id)
        _, l -> l
      end)

    %{state | lease: lease}
  end

  # A cached count moves with every insert and delete; one never read stays
  # unread (the next check counts from SQLite, which already has these rows).
  defp count_deltas(state, deltas) do
    counts =
      Enum.reduce(deltas, state.counts, fn
        {:put, %{cap: cap} = t, _, :all}, c when cap != nil -> bump(c, t.id, 1)
        {:gone, %{cap: cap} = t, _}, c when cap != nil -> bump(c, t.id, -1)
        {:cited, n}, c -> bump(c, Schema.table(:citations).id, n)
        :new_source, c -> bump(c, Schema.table(:sources).id, 1)
        _, c -> c
      end)

    %{state | counts: counts}
  end

  defp bump(counts, id, n) when is_map_key(counts, id), do: Map.update!(counts, id, &(&1 + n))
  defp bump(counts, _id, _n), do: counts

  # The op's rows go to the kernel now, so the next op is judged on them.
  defp finish(state, turn, deltas, ack) do
    text =
      Enum.reduce(deltas, 0, fn
        {:text, n}, acc -> acc + n
        _, acc -> acc
      end)

    # The account's text budget weighs what the op changed, after minus
    # before, so rewriting a long text shorter always lands; the refusal
    # comes inside the op's savepoint, before the kernel takes its rows.
    budget = Security.account_text_bytes()

    if text > 0 and state.text_bytes + turn.text + text > budget do
      {:refused, :cap, %{table: "account", reason: "text", cap: budget}, state}
    else
      kernel_takes(state, turn, deltas, ack, text)
    end
  end

  defp kernel_takes(state, turn, deltas, ack, text) do
    body = IO.iodata_to_binary(resident_patch(deltas))

    # The kernel refusing its own rows is a bug; it is rebuilt from what the
    # transaction now holds rather than left behind SQLite.
    state =
      case body != "" and Kernel.apply(state.kernel, body) do
        {:error, reason} ->
          Logger.error("sequencer #{state.account_id}: kernel apply: #{inspect(reason)}")
          rebuild(state)

        _ ->
          state
      end

    {:ok, count_deltas(state, deltas),
     %{turn | deltas: turn.deltas ++ deltas, text: turn.text + text}, ack}
  end

  defp effect(table, row_id, cells, inserted, ctx) do
    with {:ok, values} <- effect_values(table, cells, inserted, ctx) do
      if row_id == 0, do: insert(table, values, ctx), else: update(table, row_id, values, ctx)
    end
  end

  defp effect_values(table, cells, inserted, _ctx) do
    Enum.reduce_while(cells, {:ok, %{}}, fn {col_id, v}, {:ok, acc} ->
      col = col(table, col_id)
      v = new_ref(v, inserted, col)

      case col && Codec.from_wire(col, v) do
        nil ->
          {:halt,
           {:refused, :internal, %{reason: "kernel named column #{col_id} of #{table.name}"}}}

        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, String.to_atom(col.name), value)}}

        {:error, :type} ->
          {:halt, {:refused, :type, %{table: table.name, column: col.name}}}
      end
    end)
  end

  # Inside effects `{:new, k}` is the id the k-th insert got.
  defp new_ref({:new, k}, inserted, _col), do: Enum.at(inserted, k)
  defp new_ref(v, _inserted, _col), do: v

  defp insert(table, values, ctx) do
    now = ctx.turn.now

    values =
      derived(table, values, nil, ctx) |> Map.merge(%{rev: 1, inserted_at: now, updated_at: now})

    values = if table.global, do: values, else: Map.put(values, :account_id, Repo.account_id!())

    struct(Schema.row(table.name))
    |> Ecto.Changeset.change(values)
    |> Repo.insert()
    |> case do
      {:ok, row} -> {:ok, row, :all}
      {:error, cs} -> {:refused, :column, %{table: table.name, errors: errors(cs)}}
    end
  end

  defp update(table, id, values, ctx) do
    row =
      if ctx.plan.row && ctx.plan.row.id == id && ctx.plan.table.id == table.id,
        do: ctx.plan.row,
        else: fetch(table, id)

    if row == nil do
      {:refused, :not_found, %{table: table.name, id: id}}
    else
      values =
        derived(table, values, row, ctx)
        |> Map.merge(%{rev: row.rev + 1, updated_at: ctx.turn.now})

      row
      |> Ecto.Changeset.change(values)
      |> Repo.update(force: true)
      |> case do
        {:ok, row} -> {:ok, row, Map.keys(values)}
        {:error, cs} -> {:refused, :column, %{table: table.name, errors: errors(cs)}}
      end
    end
  end

  defp errors(cs), do: Map.new(cs.errors, fn {k, {msg, _}} -> {k, msg} end)

  # What the server writes and no writer may: a new application's number,
  # a source's host, an event's author, metric dates. (The listing's hash
  # and keywords are the kernel's effects.)
  defp derived(table, values, row, ctx) do
    values
    |> derive(table.name, row, ctx)
    |> hashes(table)
    |> Map.merge(
      if(ctx.prov && table.id == ctx.plan.table.id, do: atomize(ctx.prov.ons), else: %{})
    )
  end

  # Every deferred column written gets its hex SHA-256 twin in the same
  # write, so a BOOT or PATCH stub is read from the twin, never the text.
  defp hashes(values, table) do
    Enum.reduce(table.cols, values, fn c, acc ->
      key = String.to_atom(c.name)
      twin = c.deferred && sha_twin(table, c)

      case twin && Map.fetch(acc, key) do
        {:ok, text} when is_binary(text) ->
          Map.put(acc, twin, Base.encode16(:crypto.hash(:sha256, text), case: :lower))

        {:ok, nil} ->
          Map.put(acc, twin, nil)

        _ ->
          acc
      end
    end)
  end

  # A deferred column's twin is the column whose sha_of names it.
  defp sha_twin(table, col) do
    Enum.find_value(table.cols, fn c ->
      Map.get(c, :sha_of) == col.name and String.to_atom(c.name)
    end)
  end

  defp atomize(m), do: Map.new(m, fn {k, v} -> {String.to_atom(k), v} end)

  defp derive(values, "applications", nil, _ctx), do: Map.put(values, :no, next_no())

  defp derive(values, "sources", _row, _ctx) do
    case values do
      %{url: url} -> Map.put(values, :host, Provenance.host(url) || "")
      _ -> values
    end
  end

  defp derive(values, "events", nil, ctx) do
    values
    |> Map.put(:actor, if(ctx.sub.key_id, do: :agent, else: :operator))
    |> Map.put(:key_id, ctx.sub.key_id)
    |> Map.put(:op_id, signed(ctx.op.op_id))
  end

  defp derive(values, _table, _row, _ctx), do: values

  defp next_no do
    id = Repo.account_id!()

    {1, [no]} =
      from(a in Hireme.Rows.Account, where: a.id == ^id, select: a.next_no - 1)
      |> Repo.update_all([inc: [next_no: 1]], skip_account: true)

    no
  end

  defp cite(table, row, cells, prov, ctx) do
    {n, ids} = cite_rows(table, row, cells, prov, ctx)

    source =
      if prov.new_source,
        do: [{:text, text_bytes(Schema.table(:sources), prov.source.id)}, :new_source],
        else: []

    [
      {:cited, n},
      {:text, if(ids == [], do: 0, else: text_bytes(Schema.table(:citations), ids))} | source
    ]
  end

  defp cite_rows(table, row, cells, prov, ctx) do
    named =
      for {col_id, v} <- cells,
          c = col(table, col_id),
          c.metric or c.prose,
          do: {c.name, elem(Codec.from_wire(c, v), 1)}

    Provenance.cite(table, row.id, named, %{
      source: prov.source,
      as_of: prov.as_of,
      today: ctx.turn.today,
      actor: if(ctx.sub.key_id, do: :agent, else: :operator),
      key_id: ctx.sub.key_id,
      op_id: signed(ctx.op.op_id),
      now: ctx.turn.now
    })
  end

  # Provenance outlives what it names: only the operator drops a row a
  # loose ref names (a cited source), and that drop is a tombstone.
  defp provenance_kept(%{table: table, row: row}, sub) do
    if sub.grants.actor != :operator and loosely_named?(table, row.id),
      do: {:refused, :scope, %{table: table.name, reason: "cited; provenance outlives it"}},
      else: :ok
  end

  defp loose_refs(table) do
    for t <- Schema.tables(), c <- t.cols, c.loose and c.ref == table.name, do: {t, c}
  end

  defp loosely_named?(table, id) do
    Enum.any?(loose_refs(table), fn {t, c} ->
      field = String.to_atom(c.name)

      # Within the account: its (account_id, ref) index answers it, where
      # every account's rows would be a scan under the writer lock.
      Repo.exists?(from(r in Schema.row(t.name), where: field(r, ^field) == ^id))
    end)
  end

  # Deletes a row and, first, everything whose ref names it. A soft-delete
  # table tombstones the row; one that loose refs name (sources) tombstones
  # only a row they name, and deletes the rest.
  defp delete(table, row, now) do
    deltas = dependents(table, row.id, now)
    pid = row.id

    if table.soft_delete and (loose_refs(table) == [] or loosely_named?(table, pid)) do
      {:ok, row} =
        row
        |> Ecto.Changeset.change(deleted_at: now, rev: row.rev + 1, updated_at: now)
        |> Repo.update()

      {deltas ++ [{:gone, table, pid}], row.rev}
    else
      freed = text_bytes(table, pid)
      Repo.delete!(row)
      {deltas ++ [{:gone, table, pid}, {:text, -freed}], row.rev + 1}
    end
  end

  defp dependents(table, id, now) do
    for t <- Schema.tables(),
        t.residency in [:resident, :server],
        c <- t.cols,
        c.ref == table.name,
        # A loose ref records who or what wrote a row; it outlives its
        # target and is never cleared or cascaded.
        not c.implied and not c.loose do
      {t, c}
    end
    |> Enum.flat_map(fn {t, c} ->
      field = String.to_atom(c.name)
      q = from(r in Schema.row(t.name), where: field(r, ^field) == ^id)

      for r <- Repo.all(q) do
        if c.required or Map.get(c, :cascade, false) do
          {deltas, _} = delete(t, r, now)
          deltas
        else
          {:ok, r} =
            r
            |> Ecto.Changeset.change([{field, nil}, rev: r.rev + 1, updated_at: now])
            |> Repo.update()

          [{:put, t, r, [field, :rev, :updated_at]}]
        end
      end
      |> List.flatten()
    end)
  end

  # ----------------------------------------------------------- the reads

  @doc false
  def rebuild(state) do
    # Inside a batch the rows read are uncommitted, so they are not kept.
    {read, body} = snapshot(nil, %{state | rows: nil}, Store.now())
    rows = if Repo.in_transaction?(), do: nil, else: read.rows
    %{state | kernel: Kernel.new(body), counts: %{}, rows: rows}
  end

  # Every resident table and projection the grants read (all of them, for
  # the kernel when `grants` is nil), plus the wire tables.
  defp snapshot(grants, state, now) do
    {state, rows} = resident_rows(state)

    # A table the grants do not read goes as an empty block, so a BOOT clears
    # whatever a client kept of it from wider grants.
    tables =
      for t <- Schema.tables(), t.residency in [:resident, :projection] do
        if grants == nil or Grants.read?(grants, t),
          do: Codec.rows_block(t, wire_cols(t, grants), Map.fetch!(rows, t.id)),
          else: Codec.block(t.id, 0, [{1, 1, []}])
      end

    {state, [tables | if(grants, do: wire_tables(state, grants, now), else: [clock(now)])]}
  end

  # The resident rows as of the account's rev, read once per rev: the
  # kernel's snapshot and the BOOTs of sessions joining before the next
  # write share one read.
  defp resident_rows(%{rows: {rev, rows}, rev: rev} = state), do: {state, rows}

  defp resident_rows(state) do
    rows =
      for t <- Schema.tables(),
          t.residency in [:resident, :projection],
          into: %{},
          do: {t.id, rows(t)}

    {%{state | rows: {state.rev, rows}}, rows}
  end

  # The kernel's columns: never a server_only one (a deferred column's hash
  # twin stays server-side; the stub already carries its first 8 bytes).
  defp wire_cols(t, nil),
    do: Enum.reject(t.cols, &(&1.name == "account_id" or &1.wire == nil or &1.server_only))

  defp wire_cols(t, grants),
    do: Enum.reject(Grants.columns(grants, t), &(&1.name == "account_id" or &1.wire == nil))

  defp rows(%{residency: :projection, source: source, source_term: term}) do
    from(r in Schema.row(source), order_by: r.id)
    |> restrict(Schema.table(source), term)
    |> Repo.all()
  end

  # Rows as maps of their wire columns, texts whole.
  defp rows(t) do
    fields = for c <- t.cols, c.wire != nil, do: String.to_atom(c.name)
    q = from(r in Schema.row(t.name), order_by: r.id, select: map(r, ^fields))
    q = if t.soft_delete, do: where(q, [r], is_nil(r.deleted_at)), else: q
    Repo.all(q)
  end

  defp projected?(row, term) do
    holds?(
      Schema.table(:places),
      term,
      Map.new(Map.from_struct(row), fn {k, v} -> {Atom.to_string(k), v} end)
    )
  end

  defp wire_tables(state, grants, now) do
    [
      catalog(grants),
      clock(now)
      | if(Grants.read?(grants, Schema.table(:leases)), do: [leases_block(state)], else: [])
    ]
  end

  defp clock(now) do
    t = Schema.table(:clock)
    Codec.rows_block(t, t.cols, [%{today: DateTime.to_date(now), now: now}])
  end

  defp leases_block(state) do
    t = Schema.table(:leases)
    Codec.rows_block(t, t.cols, Lease.rows(state.lease))
  end

  # The resolved declaration as the grants see it: every table they read or
  # write, the wire tables, every enum and frame, the commands they may run.
  defp catalog(grants) do
    key = {__MODULE__, :catalog, grants.actor, grants.read_mask, grants.write_mask}

    case :persistent_term.get(key, nil) do
      nil ->
        block = IO.iodata_to_binary(build_catalog(grants))
        :persistent_term.put(key, block)
        block

      block ->
        block
    end
  end

  @residency %{resident: 1, server: 2, wire: 3, projection: 4}

  defp build_catalog(grants) do
    seen = fn t -> t.residency == :wire or Grants.read?(grants, t) or Grants.write?(grants, t) end
    tables = Enum.filter(Schema.tables(), seen)

    rows =
      Enum.flat_map(tables, fn t ->
        [
          %{
            kind: 1,
            owner: 0,
            id: t.id,
            name: t.name,
            type: @residency[t.residency],
            flags: Grants.bit(t),
            target: t.domain
          }
        ] ++
          for c <- Grants.columns(grants, t) do
            %{
              kind: 2,
              owner: t.id,
              id: c.id,
              name: c.name,
              type: c.type_code,
              flags: Parser.flags(c),
              target: c.target
            }
          end
      end) ++
        Enum.flat_map(Enum.with_index(Schema.model().enums, 1), fn {e, eid} ->
          for {v, code} <- Enum.with_index(e.values),
              do: %{kind: 3, owner: eid, id: code, name: v, type: nil, flags: nil, target: e.name}
        end) ++
        Enum.flat_map(Schema.commands(), fn c ->
          t = Schema.table(c.table)

          if Grants.write?(grants, t) and (not c.human_only or grants.actor == :operator) do
            [
              %{
                kind: 4,
                owner: t.id,
                id: c.id,
                name: c.name,
                type: nil,
                flags: if(c.human_only, do: 16, else: 0),
                target: c.table
              }
            ] ++
              for p <- c.params do
                %{
                  kind: 5,
                  owner: c.id,
                  id: p.id,
                  name: p.name,
                  type: p.type_code,
                  flags: if(p.required, do: 1, else: 0),
                  target: p.target
                }
              end
          else
            []
          end
        end) ++
        for f <- Schema.frames(),
            do: %{kind: 6, owner: 0, id: f.id, name: f.name, type: nil, flags: nil, target: nil}

    t = Schema.table(:catalog)
    Codec.rows_block(t, t.cols, rows)
  end

  # ------------------------------------------------------------- deltas

  # One PATCH body per distinct grants, for the batch's committed writes.
  defp publish([], state), do: state

  defp publish(deltas, state) do
    state.subs
    |> Map.values()
    |> Enum.filter(&is_pid(&1.pid))
    |> Enum.group_by(& &1.grants)
    |> Enum.each(fn {grants, subs} ->
      # Sent even empty: its rev tells a client that server-side rows (the
      # world, the mail) moved, which no table run carries.
      # One subscriber's bad entry must not cost the others their PATCH.
      try do
        body = IO.iodata_to_binary(patch(deltas, grants))
        Enum.each(subs, &send(&1.pid, {:sequencer, :patch, state.rev, body}))
      rescue
        e ->
          Logger.error("sequencer #{state.account_id}: publish: #{Exception.message(e)}")
          Enum.each(subs, &send(&1.pid, {:sequencer, :lost}))
      end
    end)

    state
  end

  defp resident_patch(deltas), do: patch(deltas, nil)

  # Rows of resident tables (and the atlas projection of places) that moved,
  # each block carrying the union of the moved columns, then the gone rows.
  defp patch(deltas, grants) do
    visible = fn t -> grants == nil or Grants.read?(grants, t) end

    puts =
      deltas
      |> Enum.flat_map(fn
        {:put, %{residency: :resident} = t, row, changed} -> [{t, row, changed}]
        {:put, %{name: "places"}, row, _changed} -> atlas_put(row)
        _ -> []
      end)
      |> Enum.filter(fn {t, _, _} -> visible.(t) end)
      |> Enum.group_by(fn {t, _, _} -> t.id end)
      |> Enum.map(fn {_, [{t, _, _} | _] = group} ->
        rows =
          group
          |> Enum.map(&elem(&1, 1))
          |> Enum.reverse()
          |> Enum.uniq_by(& &1.id)
          |> Enum.reverse()

        changed = Enum.map(group, &elem(&1, 2))

        cols =
          if Enum.member?(changed, :all),
            do: wire_cols(t, grants),
            else:
              (
                names = changed |> List.flatten() |> MapSet.new(&to_string/1) |> MapSet.put("id")
                Enum.filter(wire_cols(t, grants), &MapSet.member?(names, &1.name))
              )

        Codec.rows_block(t, cols, rows)
      end)

    gone =
      deltas
      |> Enum.flat_map(fn
        {:gone, %{residency: :resident} = t, id} -> [{t, id}]
        {:gone, %{name: "places"}, id} -> [{Schema.table(:atlas), id}]
        {:put, %{name: "places"}, row, changed} -> atlas_gone(row, changed)
        _ -> []
      end)
      |> Enum.filter(fn {t, _} -> visible.(t) end)
      |> Enum.map(fn {t, id} -> {t.id, id} end)

    [puts, Codec.gone_block(gone)]
  end

  # A place whose chart column was just cleared leaves the projection.
  defp atlas_gone(row, changed) do
    atlas = Schema.table(:atlas)
    moved = changed == :all or Enum.member?(changed, :atlas_position)
    if moved and not projected?(row, atlas.source_term), do: [{atlas, row.id}], else: []
  end

  defp atlas_put(row) do
    atlas = Schema.table(:atlas)
    if projected?(row, atlas.source_term), do: [{atlas, row, :all}], else: []
  end

  # ------------------------------------------------------------- leases

  # A key's lease requests spend its write budget; a claim needs a write bit,
  # and claiming applications the desk's (the session checks the same).
  # The subscription a request names by its session id (not the caller's pid).
  defp subscriber(state, {kind, sid, _}) when kind in [:claim, :release],
    do: Enum.find_value(state.subs, fn {_, s} -> s.id == sid && s end) || :unknown

  defp subscriber(_state, _request), do: :none

  defp lease_allowed({kind, _, _}, :unknown) when kind in [:claim, :release],
    do: {:refused, :lease_missing, %{}}

  defp lease_allowed({:claim, _, params}, %{key_id: key_id, grants: g}) when key_id != nil do
    claims = params["count"] not in [nil, 0] or params["ids"] not in [nil, []]

    cond do
      Security.hit(:agent_write, key_id, 1) != :ok ->
        {:refused, :rate, %{}}

      g.write_mask == 0 ->
        {:refused, :scope, %{reason: "the lease is for writing"}}

      claims and
          not (Grants.write?(g, Schema.table(:applications)) and
                   Grants.read?(g, Schema.table(:applications))) ->
        {:refused, :scope, %{table: "applications"}}

      true ->
        :ok
    end
  end

  defp lease_allowed({:release, _, _}, %{key_id: key_id}) when key_id != nil do
    if Security.hit(:agent_write, key_id, 1) == :ok, do: :ok, else: {:refused, :rate, %{}}
  end

  defp lease_allowed(_request, _sub), do: :ok

  defp lease_request(:list, _pid, state), do: {{:ok, Lease.list(state.lease)}, state}

  # Answers what was released (the session's label and how many claims;
  # nil when nothing was) and the key this revoke paused,
  # if it paused one now (nil when it was paused already, or a browser's).
  defp lease_request({:revoke, lease_id}, _pid, state) do
    target = state.lease.sessions[lease_id]
    {state, paused} = pause(state, target)

    case Lease.revoke(state.lease, lease_id) do
      {:ok, lease, released} ->
        released = %{label: target.label, count: length(released)}
        {{:ok, released, paused}, broadcast_leases(%{state | lease: lease}, [])}

      {:unchanged, lease} ->
        {{:ok, nil, paused}, %{state | lease: lease}}

      :error ->
        {{:error, :not_found}, state}
    end
  end

  defp lease_request({:claim, sid, params}, _pid, state) do
    stage = params["stage"] && Codec.enum_code("stage", params["stage"])

    if params["stage"] && stage == nil do
      {{:refused, :type, %{column: "stage"}}, state}
    else
      ranked = Kernel.board_ids(state.kernel, stage)

      all =
        if stage, do: MapSet.new(Kernel.board_ids(state.kernel, nil)), else: MapSet.new(ranked)

      case Lease.claim(state.lease, sid, params, ranked, all, Store.now()) do
        {:ok, lease, reply} -> {{:ok, reply}, broadcast_leases(%{state | lease: lease}, [])}
        refused -> {refused, state}
      end
    end
  end

  defp lease_request({:release, sid, ids}, _pid, state) do
    {lease, released} = Lease.free(state.lease, sid, ids)
    state = if released != [], do: rescan(state), else: state
    {{:ok, %{"released" => released}}, broadcast_leases(%{state | lease: lease}, [])}
  end

  # An operator revoke of a key's session pauses the key until the operator
  # resumes it (docs/rebuild.md, 'Lease and keys'). The hold is on the key
  # row, so it outlives the session, the carrier and this sequencer; the
  # lease state mirrors it, so a claim or a write never queries for it.
  defp pause(state, %{key_id: key_id}) when key_id != nil do
    now = Store.now()

    {n, _} =
      Store.write(fn ->
        Repo.update_all(
          from(k in Hireme.Rows.ApiKey,
            where: k.id == ^key_id and is_nil(k.paused_at) and is_nil(k.revoked_at)
          ),
          set: [paused_at: now, updated_at: now],
          inc: [rev: 1]
        )
      end)

    since = Repo.one(from(k in Hireme.Rows.ApiKey, where: k.id == ^key_id, select: k.paused_at))
    # A revoked key is never held (its row is not paused).
    lease = if since, do: Lease.hold(state.lease, key_id, since), else: state.lease
    {%{state | lease: lease}, if(n == 1, do: key_id)}
  end

  defp pause(state, _session), do: {state, nil}

  defp paused_keys(account_id) do
    from(k in Hireme.Rows.ApiKey,
      where: k.account_id == ^account_id and not is_nil(k.paused_at) and is_nil(k.revoked_at),
      select: {k.id, k.paused_at}
    )
    |> Repo.all(skip_account: true)
    |> Enum.reduce(%Lease{}, fn {id, since}, l -> Lease.hold(l, id, since) end)
  end

  # Applications that were held may have waited for the keywords backfill;
  # it scans again from the top once they are free.
  defp rescan(state) do
    send(self(), :backfill)
    %{state | backfill_after: 0}
  end

  # A key's session taking or giving up the channel is audited, which also
  # wakes the account lens's parked watch: the operator sees agents come and go.
  # `before` and `after_` are the leases around one request, captured then:
  # another session's change in between is its own request's to audit.
  defp audit_channels(before, after_, account_id) do
    for {sid, s} <- before.sessions,
        s.key_id != nil,
        s.channel != Lease.channel?(after_, sid) do
      kind = if s.channel, do: :lease_released, else: :lease_opened
      held = MapSet.size(Lease.held(if(s.channel, do: before, else: after_), sid))

      Hireme.Audit.record(kind, %{lease_id: sid, label: s.label, count: held}, %{
        account_id: account_id,
        ip: s[:ip],
        user_agent: s[:user_agent],
        key_id: s.key_id
      })
    end

    :ok
  end

  # Only when the rows moved: a browser joining changes nothing anyone sees.
  defp broadcast_leases(state, opts) do
    rows = Lease.rows(state.lease)

    if rows == state.lease_rows,
      do: state,
      else: send_leases(%{state | lease_rows: rows}, state.lease_rows, opts)
  end

  # The current rows, and a gone block for the leases that ended.
  defp send_leases(state, before, opts) do
    t = Schema.table(:leases)
    ended = MapSet.difference(MapSet.new(before, & &1.id), MapSet.new(state.lease_rows, & &1.id))

    body =
      IO.iodata_to_binary([
        leases_block(state),
        Codec.gone_block(for id <- ended, do: {t.id, id})
      ])

    for {pid, sub} <- state.subs,
        is_pid(pid),
        pid != opts[:except],
        Grants.read?(sub.grants, t) do
      send(pid, {:sequencer, :patch, state.rev, body})
    end

    state
  end
end

defmodule Hireme.Sequencer.Supervisor do
  @moduledoc "The registry and the dynamic supervisor every account's sequencer runs under."
  use Supervisor

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl Supervisor
  def init(_) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: Hireme.Sequencer.Registry},
        # Every open wire session under its peer, for the per-peer cap.
        {Registry, keys: :duplicate, name: HiremeWeb.Session.Peers},
        {DynamicSupervisor, name: Hireme.Sequencer.Dynamic, strategy: :one_for_one}
      ],
      strategy: :rest_for_one
    )
  end
end
