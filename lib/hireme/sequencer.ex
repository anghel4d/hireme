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
  alias HiremeWeb.Wire.Codec

  @batch 64
  @max_op_text 1 <<< 20
  @idle_ms :timer.minutes(10)
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
      account: nil,
      subs: %{},
      counts: %{},
      kernel: nil,
      rows: nil,
      blocks: nil,
      backfill_after: 0,
      text_bytes: text_bytes
    }

    # A revoked or changed key, a revoked browser session or a suspension is
    # heard here too: its sessions stop writing the moment the sequencer
    # knows, not when their carrier closes.
    Hireme.PubSub.subscribe(Hireme.Audit.topic(account_id))
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
    with %{key_id: key_id} when key_id != nil <- state.subs[pid],
         {:error, retry_ms} <- spend(key_id, length(ops), Enum.sum_by(ops, &text_of/1)) do
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
      %{^pid => %{ref: ^ref} = sub} -> {:noreply, ended([{pid, sub}], state), @idle_ms}
      _ -> {:noreply, state, @idle_ms}
    end
  end

  def handle_info({:bye, who, _reason}, state) do
    gone = for {pid, sub} <- state.subs, ends?(who, sub), do: {pid, sub}
    {:noreply, ended(gone, state), @idle_ms}
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

  # The account's trail moved (a key, a session, a factor, a host): the
  # operator's account views follow, at most every 100 ms.
  def handle_info({Hireme.Audit, kind}, state) when kind in [:changed, :factors],
    do: {:noreply, refresh_views(state), @idle_ms}

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

    {kind, {state, body}} =
      if resume,
        do: {:PATCH, resumed(session.grants, state, now)},
        else: {:BOOT, snapshot(session.grants, state, now)}

    frames = [Codec.frame(kind, state.rev, body, end: true, compress: true)]
    state = broadcast_leases(state, except: pid)

    reply = %{
      rev: state.rev,
      lease: Lease.channel?(state.lease, session.id),
      frames: frames,
      pid: self()
    }

    {:reply, {:ok, reply}, state, @idle_ms}
  end

  defp ends?({:key, id}, %{key_id: id}) when id != nil, do: true
  defp ends?({:session, id}, %{session_id: id}) when id != nil, do: true
  defp ends?(:account, _sub), do: true
  defp ends?(_who, _sub), do: false

  # Sessions that ended: their claims go, the channels they held are
  # audited, and applications they held (which may have waited for the
  # keywords backfill) are scanned again.
  defp ended(gone, state) do
    after_ =
      Enum.reduce(gone, state, fn {pid, sub}, st ->
        if sub.ref, do: Process.demonitor(sub.ref, [:flush])
        %{st | subs: Map.delete(st.subs, pid), lease: Lease.leave(st.lease, sub.id)}
      end)

    if gone != [], do: send(self(), {:audit_channels, state.lease, after_.lease})
    held = Enum.any?(gone, fn {_, sub} -> MapSet.size(Lease.held(state.lease, sub.id)) > 0 end)
    broadcast_leases(if(held, do: rescan(after_), else: after_), [])
  end

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
          raw = Codec.encode_op({Codec.op_id(), :put, 0, t.id, id, nil, [{listing.id, 2, text}]})
          {:ok, op, ""} = Codec.op(raw)
          op
        end

      {state, _acks, nacks} =
        run_as(%{label: "keywords", grants: Grants.operator(), key_id: nil}, ops, state)

      # The cursor walks past refused rows, so they cannot stall the scan.
      send(self(), :backfill)

      if nacks != [],
        do:
          Logger.warning(
            "sequencer #{state.account_id}: keywords backfill refused #{length(nacks)}"
          )

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
        state = if turn.acked > 0, do: %{state | rows: nil, blocks: nil}, else: state
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
         {:ok, state, turn, ack} <- write(plan, op, sub, effects, state, turn) do
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
        {:ok, plan(table, op, command: command, params: params, known: known)}
    end
  end

  defp resolve(op) do
    case Schema.table(op.subject) do
      %{residency: r} = table when r in [:resident, :server] ->
        {:ok, plan(table, op, known: for({id, _, _} <- op.cells, c = col(table, id), do: c))}

      _ ->
        {:refused, :not_found, %{table: op.subject}}
    end
  end

  defp plan(table, op, more),
    do:
      Map.merge(
        %{table: table, command: nil, params: nil, known: [], row: nil, target: op.target},
        Map.new(more)
      )

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
  # str, text and json column (0 for a row that is not there). The
  # per-account text budget counts exactly this, before and after each write.
  defp text_bytes(table, id) do
    case for(
           c <- table.cols,
           c.type in [:str, :text, :json],
           do: ~s{coalesce(length(CAST("#{c.name}" AS BLOB)),0)}
         ) do
      [] ->
        0

      parts ->
        q = ~s{SELECT coalesce(sum(#{Enum.join(parts, "+")}),0) FROM "#{table.name}" WHERE id = ?}
        %{rows: [[n]]} = Repo.query!(q, [id], skip_account: true)
        n
    end
  end

  defp col(table, id) when is_integer(id), do: Enum.find(table.cols, &(&1.id == id))
  defp col(table, name), do: Enum.find(table.cols, &(&1.name == name))

  defp fetch(table, id),
    do: from(r in Schema.row(table.name), where: r.id == ^id) |> alive(table) |> Repo.one()

  # A soft-delete table's tombstones are not rows.
  defp alive(q, %{soft_delete: true}), do: where(q, [r], is_nil(r.deleted_at))
  defp alive(q, _table), do: q

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
          |> alive(table)

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

  defp held_by_none_other(lease, sid, apps),
    do: Enum.find_value(apps, :ok, &lease_refusal(lease, sid, &1))

  defp lease_refusal(lease, sid, app) do
    case Lease.check(lease, sid, app) do
      :ok -> nil
      refused -> refused
    end
  end

  # Check 3: every cell names a writable column (or a param) of its type.
  defp shape(%{table: table} = plan, %{verb: :drop} = op, _sub) do
    with :ok <- targeted(plan, op) do
      if table.append_only,
        do: {:refused, :column, %{table: table.name, reason: "append_only"}},
        else: {:ok, plan}
    end
  end

  defp shape(%{command: command, params: params} = plan, %{verb: :command} = op, _sub) do
    with {:ok, values} <-
           reduce_cells(op.cells, fn {id, _, _} = cell ->
             case params[id] do
               nil -> {:refused, :column, %{command: command.name, param: id}}
               p -> typed(p, cell, command.name)
             end
           end),
         [] <- for(p <- command.params, p.required, not Map.has_key?(values, p.name), do: p.name),
         :ok <- refs(command.params, values),
         :ok <- targeted(plan, op) do
      {:ok, plan}
    else
      missing when is_list(missing) ->
        {:refused, :column, %{command: command.name, missing: missing}}

      refused ->
        refused
    end
  end

  # A put's shape is the kernel's to judge (check 4, the one judge).
  defp shape(plan, _op, _sub), do: {:ok, plan}

  # The row an op names must exist, and stand at expect_rev when one is given.
  defp targeted(%{row: nil, table: t}, %{target: target} = op)
       when target > 0 or op.verb == :drop,
       do: {:refused, :not_found, %{table: t.name, id: target}}

  defp targeted(%{row: %{rev: rev}, table: t}, %{expect_rev: e}) when e != nil and e != rev,
    do: {:refused, :rev, %{table: t.name, rev: rev}}

  defp targeted(_plan, _op), do: :ok

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
        {:ok, name, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        refused -> {:halt, refused}
      end
    end)
  end

  # An empty required param is a missing one, as the kernel's judge says it.
  defp typed(col, cell, owner) do
    case Codec.cell_to_value(col, cell) do
      {:ok, nil} when col.required -> {:refused, :column, %{command: owner, missing: [col.name]}}
      {:ok, v} -> {:ok, col.name, v}
      {:error, :type} -> {:refused, :type, %{in: owner, column: col.name, want: col.type}}
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

  # Check 6 (`too_large` is taken right after shape, before the kernel spends
  # time on a text it would refuse; `rate` as ops arrive).
  defp too_large(op) do
    text = text_of(op)

    if text > @max_op_text,
      do: {:refused, :too_large, %{bytes: text, max: @max_op_text}},
      else: :ok
  end

  # The text bytes an op carries: its str cells.
  defp text_of(op),
    do: Enum.sum_by(op.cells, fn {_, ty, v} -> if(ty == 2, do: byte_size(v), else: 0) end)

  # A capped table's row count, read from SQLite once and then moved with
  # every insert and delete (count_deltas). A tombstone is gone (its drop
  # moves the count), so a soft-delete table counts its live rows.
  defp counted(%{counts: counts} = state, table) when is_map_key(counts, table.id), do: state

  defp counted(state, table),
    do:
      put_in(
        state.counts[table.id],
        table.name |> Schema.row() |> alive(table) |> Repo.aggregate(:count)
      )

  # ----------------------------------------------------------- the write

  defp write(plan, %{verb: :drop} = op, sub, _effects, state, turn) do
    {deltas, rev} = delete(plan.table, plan.row, turn.now)

    with :ok <- cascade_allowed(deltas, sub, state),
         do: finish(state, turn, deltas, %{op_id: op.op_id, rev: rev, id: plan.row.id})
  end

  # The kernel judged the op (check 4, the one judge: shape, provenance,
  # restatement, caps) and returned what to write: a new source first, the
  # op's row with its metrics' dates, one citation per changed cited cell.
  # No effects for a put of an existing row is a restatement: nothing written.
  defp write(%{row: row}, %{verb: :put} = op, _sub, [], state, turn) when row != nil,
    do: finish(state, turn, [], %{op_id: op.op_id, rev: row.rev, id: row.id})

  defp write(plan, op, sub, effects, state, turn) do
    ctx = %{sub: sub, op: op, turn: turn, plan: plan}

    effects
    |> Enum.reduce_while({:ok, [], [], nil}, fn {table_id, row_id, cells},
                                                {:ok, deltas, inserted, ack} ->
      table = Schema.table(table_id)
      before = if row_id == 0, do: 0, else: text_bytes(table, row_id)

      case effect(table, row_id, cells, inserted, ctx) do
        {:ok, row, changed} ->
          moved = {:text, text_bytes(table, row.id) - before}
          own = own?(plan, op, table_id, row_id, ack)
          inserted = if row_id == 0, do: inserted ++ [row.id], else: inserted
          ack = if own and ack == nil, do: %{op_id: op.op_id, rev: row.rev, id: row.id}, else: ack
          {:cont, {:ok, deltas ++ [{:put, table, row, changed}, moved], inserted, ack}}

        refused ->
          {:halt, refused}
      end
    end)
    |> case do
      {:ok, deltas, _inserted, ack} ->
        # Claims follow only a write that lands: a refusal in finish rolls
        # the insert back, and its id must not stay leased.
        with {:ok, state, turn, ack} <- finish(state, turn, deltas, ack || command_ack(plan, op)),
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
        lease_refusal(state.lease, sub.id, id)

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
    body = IO.iodata_to_binary(patch(deltas, nil))

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
    with {:ok, values} <- effect_values(table, cells, inserted) do
      if row_id == 0, do: insert(table, values, ctx), else: update(table, row_id, values, ctx)
    end
  end

  defp effect_values(table, cells, inserted) do
    Enum.reduce_while(cells, {:ok, %{}}, fn {col_id, v}, {:ok, acc} ->
      col = col(table, col_id)
      v = new_ref(v, inserted)

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
  defp new_ref({:new, k}, inserted), do: Enum.at(inserted, k)
  defp new_ref(v, _inserted), do: v

  defp insert(table, values, ctx) do
    now = ctx.turn.now

    values =
      values
      |> derive(table.name, nil, ctx)
      |> Map.merge(%{rev: 1, inserted_at: now, updated_at: now})

    values = if table.global, do: values, else: Map.put(values, :account_id, Repo.account_id!())

    struct(Schema.row(table.name))
    |> Ecto.Changeset.change(values)
    |> Repo.insert()
    |> landed(table, :all)
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
        values
        |> derive(table.name, row, ctx)
        |> Map.merge(%{rev: row.rev + 1, updated_at: ctx.turn.now})

      row
      |> Ecto.Changeset.change(values)
      |> Repo.update(force: true)
      |> landed(table, Map.keys(values))
    end
  end

  defp landed({:ok, row}, _table, changed), do: {:ok, row, changed}

  defp landed({:error, cs}, table, _changed),
    do:
      {:refused, :column,
       %{table: table.name, errors: Map.new(cs.errors, fn {k, {msg, _}} -> {k, msg} end)}}

  # What the server writes and no writer may: a new application's number,
  # a source's host, an event's author. (Metric dates and keywords are the
  # kernel's effects.)
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

  # A loose ref records who or what wrote a row; it outlives its target
  # and is never cleared or cascaded.
  defp dependents(table, id, now) do
    for t <- Schema.tables(),
        t.residency in [:resident, :server],
        c <- t.cols,
        c.ref == table.name and not c.implied and not c.loose,
        field = String.to_atom(c.name),
        row <- Repo.all(from(r in Schema.row(t.name), where: field(r, ^field) == ^id)),
        delta <- dependent(t, c, field, row, now),
        do: delta
  end

  # A required (or cascading) ref takes its row with the target; a nullable one is cleared.
  defp dependent(t, c, field, row, now) do
    if c.required or Map.get(c, :cascade, false) do
      elem(delete(t, row, now), 0)
    else
      {:ok, row} =
        row
        |> Ecto.Changeset.change([{field, nil}, rev: row.rev + 1, updated_at: now])
        |> Repo.update()

      [{:put, t, row, [field, :rev, :updated_at]}]
    end
  end

  # ----------------------------------------------------------- the reads

  defp rebuild(state) do
    # Inside a batch the rows read are uncommitted, so they are not kept.
    {read, body} = snapshot(nil, %{state | rows: nil, blocks: nil}, Store.now())
    rows = if Repo.in_transaction?(), do: nil, else: read.rows
    %{state | kernel: Kernel.new(body), counts: %{}, rows: rows, account: read.account}
  end

  # Every resident table and projection the grants read (all of them, for
  # the kernel when `grants` is nil), plus the wire tables.
  defp snapshot(grants, state, now) do
    {state, blocks} = resident_blocks(state, grants)

    # A table the grants do not read goes as an empty block, so a BOOT clears
    # whatever a client kept of it from wider grants.
    {state, views} = live_views(state)

    tables =
      for t <- Schema.tables(), t.residency in [:resident, :projection] do
        cond do
          grants != nil and not Grants.read?(grants, t) -> Codec.block(t.id, 0, [{1, 1, []}])
          account?(t) and grants == nil -> Codec.block(t.id, 0, [{1, 1, []}])
          live?(t) -> Codec.rows_block(t, wire_cols(t, grants), Map.fetch!(views, t.id))
          true -> Map.fetch!(blocks, t.id)
        end
      end

    {state, [tables | if(grants, do: wire_tables(state, grants, now), else: [Codec.clock(now)])]}
  end

  # A resumed session's snapshot holds the account's tables; the session's
  # own (the live views and the wire tables) come fresh, whole. A page that
  # resumes without a reload still holds its views, so each goes empty first
  # (a block with no rows and no columns) and then whole; live changes after
  # that are deltas.
  defp resumed(grants, state, now) do
    {state, views} = live_views(state)

    blocks =
      for t <- Schema.tables(),
          live?(t),
          Grants.read?(grants, t),
          do: [
            Codec.block(t.id, 0, []),
            Codec.rows_block(t, wire_cols(t, grants), Map.fetch!(views, t.id))
          ]

    {state, [blocks | wire_tables(state, grants, now)]}
  end

  # The resident tables' encoded blocks as of the account's rev, per grants:
  # sessions joining between two writes (a reload, a second tab, an agent
  # reconnecting) share one encoding instead of re-encoding the desk each.
  defp resident_blocks(%{blocks: {rev, grants, blocks}, rev: rev} = state, grants),
    do: {state, blocks}

  defp resident_blocks(state, grants) do
    {state, rows} = resident_rows(state)

    blocks =
      for {id, rs} <- rows, t = Schema.table(id), into: %{} do
        {id, Codec.rows_block(t, wire_cols(t, grants), rs)}
      end

    {%{state | blocks: {state.rev, grants, blocks}}, blocks}
  end

  # The resident rows as of the account's rev, read once per rev: the
  # kernel's snapshot and the BOOTs of sessions joining before the next
  # write share one read.
  defp resident_rows(%{rows: {rev, rows}, rev: rev} = state), do: {state, rows}

  defp resident_rows(state) do
    rows =
      for t <- Schema.tables(),
          t.residency in [:resident, :projection],
          not live?(t),
          into: %{},
          do: {t.id, rows(t)}

    {%{state | rows: {state.rev, rows}}, rows}
  end

  # The kernel's columns: never a server_only one.
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

    from(r in Schema.row(t.name), order_by: r.id, select: map(r, ^fields))
    |> alive(t)
    |> Repo.all()
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
      Codec.clock(now)
      | if(Grants.read?(grants, Schema.table(:leases)), do: [leases_block(state)], else: [])
    ] ++
      if(Grants.read?(grants, Schema.table(:acct_info)), do: [acct_info_block(state)], else: [])
  end

  # ------------------------------------------------------- account views

  # Views of tables the sequencer does not write (the account page's acct_*,
  # the operator's alone, and the trusted hosts) are read when a BOOT is
  # built and again when the account's trail moves, never cached by rev.
  # `state.account` keeps the last read, so a change patches only what moved.
  defp account?(%{name: name}), do: String.starts_with?(name, "acct_")

  defp live?(%{residency: :projection, source: source}),
    do: Schema.table(source).residency == :server

  defp live?(_t), do: false

  @audit_rows 1_000

  defp live_views(state) do
    views = for t <- Schema.tables(), live?(t), into: %{}, do: {t.id, view_rows(t)}
    {%{state | account: views}, views}
  end

  # The newest security events and, apart, the newest activity, so a burst
  # of agent ops never pushes a security event out; meta as the lens shows it.
  defp view_rows(%{name: "acct_audit"}) do
    for security <- [true, false],
        e <-
          Repo.all(
            from(e in Hireme.Rows.Audit,
              where: e.security == ^security,
              order_by: [desc: e.id],
              limit: @audit_rows
            )
          ),
        do: %{e | meta: Hireme.Audit.visible(e.meta || %{}, e.kind)}
  end

  defp view_rows(t), do: rows(t)

  defp acct_info_block(state) do
    t = Schema.table(:acct_info)

    a =
      Repo.one!(from(x in Hireme.Rows.Account, where: x.id == ^state.account_id),
        skip_account: true
      )

    row = %{name: a.name, status: a.status, recovery_codes_left: Hireme.Mfa.recovery_codes_left()}
    Codec.rows_block(t, t.cols, [row])
  end

  # The trail moved (a key, a session, a factor, a trusted host): re-read the
  # views, give the kernel the trusted hosts at once (the next op is judged
  # against them), and patch each session with what moved of what it reads.
  defp refresh_views(%{account: nil} = state), do: state

  defp refresh_views(state) do
    before = state.account
    {state, views} = live_views(state)

    moved =
      for {id, rows} <- views do
        t = Schema.table(id)
        old = Map.new(before[id] || [], &{&1.id, &1})
        changed = Enum.reject(rows, &(old[&1.id] == &1))
        gone = Map.keys(old) -- Enum.map(rows, & &1.id)
        put = if changed == [], do: [], else: [Codec.rows_block(t, t.cols, changed)]
        {t, [put, Codec.gone_block(for i <- gone, do: {t.id, i})]}
      end

    trusted = for {%{name: "trusted"}, body} <- moved, do: body
    _ = Kernel.apply(state.kernel, IO.iodata_to_binary(trusted))

    for %{grants: g, pid: pid} <- live_subs(state) do
      info = if Grants.read?(g, Schema.table(:acct_info)), do: [acct_info_block(state)], else: []
      body = for {t, b} <- moved, Grants.read?(g, t), do: b
      send(pid, {:sequencer, :patch, state.rev, IO.iodata_to_binary([body, info])})
    end

    state
  end

  # The wire sessions subscribed (not a passing caller of `call/3`).
  defp live_subs(state), do: for({pid, sub} <- state.subs, is_pid(pid), do: sub)

  defp leases_block(state) do
    t = Schema.table(:leases)
    Codec.rows_block(t, t.cols, Lease.rows(state.lease))
  end

  # The resolved declaration as the grants see it: every table they read or
  # write, the wire tables, every enum and frame, the commands they may run.
  defp catalog(grants) do
    key = {__MODULE__, :catalog, grants.actor, grants.read_mask, grants.write_mask}

    :persistent_term.get(key, nil) ||
      tap(IO.iodata_to_binary(build_catalog(grants)), &:persistent_term.put(key, &1))
  end

  @residency %{resident: 1, server: 2, wire: 3, projection: 4}
  @entry ~w(kind owner id name type flags target)a

  # One catalog row: a table (1) and its columns (2), an enum's values (3),
  # a command (4) and its params (5), a frame (6).
  defp entry(values), do: Map.new(Enum.zip(@entry, values))

  defp build_catalog(grants) do
    seen = fn t ->
      (t.residency == :wire and not account?(t)) or Grants.read?(grants, t) or
        Grants.write?(grants, t)
    end

    rows =
      Enum.flat_map(Enum.filter(Schema.tables(), seen), fn t ->
        [entry([1, 0, t.id, t.name, @residency[t.residency], Grants.bit(t), t.domain])] ++
          for c <- Grants.columns(grants, t),
              do: entry([2, t.id, c.id, c.name, c.type_code, c.flags, c.target])
      end) ++
        Enum.flat_map(Enum.with_index(Schema.model().enums, 1), fn {e, eid} ->
          for {v, code} <- Enum.with_index(e.values),
              do: entry([3, eid, code, v, nil, nil, e.name])
        end) ++
        Enum.flat_map(Schema.commands(), fn c ->
          t = Schema.table(c.table)

          if Grants.write?(grants, t) and (not c.human_only or grants.actor == :operator) do
            [entry([4, t.id, c.id, c.name, nil, if(c.human_only, do: 16, else: 0), c.table])] ++
              for p <- c.params,
                  required = if(p.required, do: 1, else: 0),
                  do: entry([5, c.id, p.id, p.name, p.type_code, required, p.target])
          else
            []
          end
        end) ++
        for f <- Schema.frames(), do: entry([6, 0, f.id, f.name, nil, nil, nil])

    t = Schema.table(:catalog)
    Codec.rows_block(t, t.cols, rows)
  end

  # ------------------------------------------------------------- deltas

  # One PATCH body per distinct grants, for the batch's committed writes.
  defp publish([], state), do: state

  defp publish(deltas, state) do
    state
    |> live_subs()
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

  # Rows of resident tables (and the atlas projection of places) that moved,
  # each block carrying the union of the moved columns, then the gone rows.
  defp patch(deltas, grants) do
    visible = fn t -> grants == nil or Grants.read?(grants, t) end

    puts =
      deltas
      |> Enum.flat_map(fn
        {:put, %{name: "places"} = t, row, changed} -> [{t, row, changed} | atlas_put(row)]
        {:put, %{residency: :resident} = t, row, changed} -> [{t, row, changed}]
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
          if :all in changed do
            wire_cols(t, grants)
          else
            names = changed |> List.flatten() |> MapSet.new(&to_string/1) |> MapSet.put("id")
            Enum.filter(wire_cols(t, grants), &MapSet.member?(names, &1.name))
          end

        Codec.rows_block(t, cols, rows)
      end)

    gone =
      deltas
      |> Enum.flat_map(fn
        {:gone, %{name: "places"} = t, id} -> [{t, id}, {Schema.table(:atlas), id}]
        {:gone, %{residency: :resident} = t, id} -> [{t, id}]
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

  # The channel is for writing: a key with no write bit may not take it, and
  # only one that writes and reads the desk may claim applications (a claim
  # ranks and names them). A key's requests then spend its write budget.
  # The subscription a request names by its session id (not the caller's pid).
  defp subscriber(state, {kind, sid, _}) when kind in [:claim, :release],
    do: Enum.find_value(state.subs, fn {_, s} -> s.id == sid && s end) || :unknown

  defp subscriber(_state, _request), do: :none

  defp lease_allowed({kind, _, _}, :unknown) when kind in [:claim, :release],
    do: {:refused, :lease_missing, %{}}

  defp lease_allowed({:claim, _, params}, %{key_id: key_id, grants: g}) when key_id != nil do
    claims = params["count"] not in [nil, 0] or params["ids"] not in [nil, []]
    desk = Schema.table(:applications)

    cond do
      g.write_mask == 0 ->
        {:refused, :scope, %{reason: "the lease is for writing"}}

      claims and not (Grants.write?(g, desk) and Grants.read?(g, desk)) ->
        {:refused, :scope, %{table: "applications"}}

      Security.hit(:agent_write, key_id, 1) != :ok ->
        {:refused, :rate, %{}}

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

    for %{pid: pid, grants: g} <- live_subs(state),
        pid != opts[:except],
        Grants.read?(g, t),
        do: send(pid, {:sequencer, :patch, state.rev, body})

    state
  end
end

defmodule Hireme.Sequencer.Supervisor do
  @moduledoc "The registry and the dynamic supervisor every account's sequencer runs under."
  use Supervisor
  alias HiremeWeb.Wire.Codec

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl Supervisor
  def init(_) do
    # The packed text cells every sequencer's BOOT and PATCH reuse.
    Codec.ztext_table()

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
