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

  The ledger answers a resent `op_id` with its first verdict and writes
  nothing. `rate` and `internal` refusals are not recorded, since the
  same op is expected to succeed when retried.

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
  @as_of 0xFFF0
  @source 0xFFF1
  @ledger_s 24 * 3600
  # 9999-12-31, the last day SQLite and Ecto read back.
  @last_day 2_932_896
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
    case Registry.lookup(Hireme.Sequencer.Registry, account_id) do
      [{pid, _}] ->
        pid

      [] ->
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
  end

  defp with_pid(account_id, fun) do
    case whereis(account_id) do
      nil -> {:error, :unavailable}
      pid -> fun.(pid)
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

    rev =
      Repo.one!(from(a in Hireme.Rows.Account, where: a.id == ^account_id, select: a.desk_rev),
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
      rows: nil
    }

    purge_ledger(Store.now())
    Process.send_after(self(), :purge, @purge_ms)
    send(self(), :backfill)
    {:ok, rebuild(state), @idle_ms}
  end

  @impl GenServer
  def handle_call({:subscribe, pid, session, snapshot_rev}, _from, state) do
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

  def handle_call({:lease, pid, request}, _from, state) do
    {reply, after_} =
      case lease_allowed(request, state.subs[pid]) do
        :ok -> lease_request(request, pid, state)
        refused -> {refused, state}
      end

    send(self(), {:audit_channels, state.lease})
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

  # Check 6's `rate` is taken as ops arrive, for every op a key sends,
  # refused ones too: a flood of cheap refusals still spends the budget.
  defp within_rate({pid, ops}, state) do
    with %{key_id: key_id} when key_id != nil <- state.subs[pid],
         {:error, retry_ms} <- Security.hit(:agent_write, key_id, max(length(ops), 1)) do
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
        send(self(), {:audit_channels, state.lease})
        {:noreply, broadcast_leases(after_, []), @idle_ms}

      _ ->
        {:noreply, state, @idle_ms}
    end
  end

  def handle_info(:backfill, state), do: {:noreply, backfill(state), @idle_ms}

  def handle_info({:audit_channels, before}, state) do
    audit_channels(before, state)
    {:noreply, state, @idle_ms}
  rescue
    e ->
      Logger.error("sequencer #{state.account_id}: lease audit: #{Exception.message(e)}")
      {:noreply, state, @idle_ms}
  end

  def handle_info(:purge, state) do
    purge_ledger(Store.now())
    Process.send_after(self(), :purge, @purge_ms)
    {:noreply, state, @idle_ms}
  end

  def handle_info(:timeout, %{subs: subs} = state) when map_size(subs) == 0,
    do: {:stop, :normal, state}

  def handle_info(:timeout, state), do: {:noreply, state, @idle_ms}
  def handle_info(_, state), do: {:noreply, state, @idle_ms}

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
    held = state.lease.holder |> Map.keys()

    # Held applications wait for their holder to let go; a text that is not
    # UTF-8 (only a hand-edited database has one) is left alone.
    stale =
      Repo.all(
        from(r in Hireme.Rows.Application,
          where:
            not is_nil(r.listing_raw) and r.id not in ^held and
              (is_nil(r.keywords_version) or r.keywords_version != ^version),
          select: {r.id, r.listing_raw},
          order_by: r.id,
          limit: @batch
        )
      )
      |> Enum.filter(fn {_, text} -> String.valid?(text) end)

    if stale == [] do
      state
    else
      t = Schema.table(:applications)
      listing = col(t, "listing_raw")

      ops =
        for {id, text} <- stale do
          raw =
            Codec.encode_op(
              {System.unique_integer([:positive]), :put, 0, t.id, id, nil,
               [{listing.id, 2, text}]}
            )

          {:ok, op, ""} = Codec.op(raw)
          op
        end

      {state, acks, nacks} =
        run_as(%{label: "keywords", grants: Grants.operator(), key_id: nil}, ops, state)

      # Stop when nothing moved, so a listing the kernel keeps refusing cannot loop.
      if acks != [], do: send(self(), :backfill)

      if nacks != [],
        do:
          Logger.warning(
            "sequencer #{state.account_id}: keywords backfill refused #{length(nacks)}"
          )

      state
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
    turn = %{now: now, today: DateTime.to_date(now), deltas: [], acked: 0}

    result =
      try do
        Store.transaction(fn ->
          {state, turn, verdicts} =
            Enum.reduce(chunk, {state, turn, []}, fn {pid, op}, {state, turn, vs} ->
              {state, turn, verdict} = one(pid, op, state, turn)
              {state, turn, [{pid, verdict} | vs]}
            end)

          rev = state.rev + turn.acked

          if turn.acked > 0 do
            from(a in Hireme.Rows.Account, where: a.id == ^state.account_id)
            |> Repo.update_all([set: [desk_rev: rev]], skip_account: true)
          end

          {%{state | rev: rev}, turn, Enum.reverse(verdicts)}
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
          {:ok, state, turn, ack} ->
            :ok = Store.savepoint(:keep)
            record(op, sub, ack, turn.now)
            {state, %{turn | acked: turn.acked + 1}, {:ack, ack}}

          {:refused, refusal, data, state} ->
            :ok = Store.savepoint(:undo)
            {state, turn, {:nack, nack(op, refusal, data)}}
        end
    end
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
    do: %{op_id: op.op_id, code: Schema.refusal(refusal), data: data}

  defp nack(op, refusal, data),
    do: %{
      op_id: op.op_id,
      code: Schema.refusal(refusal),
      data: JSON.encode!(Map.put(data, :refusal, refusal))
    }

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
        where:
          l.writer == ^(key_id || 0) and l.op_id == ^signed(op_id) and l.inserted_at > ^since and
            is_nil(l.refusal)
      )

    case Repo.one(q) do
      nil -> nil
      l -> {:ack, %{op_id: op_id, rev: l.ack_rev || 0, id: l.row_id || 0}}
    end
  end

  defp record(op, sub, ack, now) do
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
  end

  defp purge_ledger(now) do
    since = DateTime.add(now, -@ledger_s)

    Store.write(fn ->
      Repo.delete_all(from(l in Hireme.Rows.OpLedger, where: l.inserted_at <= ^since))
    end)
  end

  # ------------------------------------------------------- the checks

  defp judge(op, sub, state, turn) do
    with {:ok, plan} <- resolve(op),
         :ok <- Grants.check(sub.grants, op.verb, plan.command, plan.table, plan.known),
         :ok <- Lease.check(state.lease, sub.id, nil),
         {:ok, plan} <- locate(plan, op),
         :ok <- held_by_none_other(state.lease, sub.id, applications_of(plan, op)),
         {:ok, plan} <- shape(plan, op, sub),
         :ok <- too_large(op),
         {:ok, effects, state} <- domain(plan, op, sub, state, turn),
         {:ok, prov} <- provenance(plan, op, effects, turn),
         {:ok, state} <- limits(plan, effects, state),
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
        {:refused, :natural_key,
         %{
           table: table.name,
           reason: "no natural key among the cells",
           keys: Enum.map(table.naturals, & &1.cols)
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

    with :ok <-
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
         :ok <- refs(table.cols, values) do
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
        if ty == 1 and v <= @last_day,
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
      now_day: Date.diff(turn.today, ~D[1970-01-01]),
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

    if Enum.any?(names, fn n ->
         c = col(table, n)
         c.metric or c.prose
       end) do
      as_of =
        Enum.find_value(op.cells, fn
          {@as_of, _, d} -> Date.add(~D[1970-01-01], d)
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
           {:ok, source} <- Provenance.source(source_cell, turn.now),
           ctx = %{as_of: as_of, source: source, expect_rev: op.expect_rev},
           changes = Map.new(names, &{&1, true}),
           {:ok, changes} <- Provenance.check(table, plan.row, changes, ctx) do
        ons = for {k, %Date{} = d} <- changes, String.ends_with?(k, "_on"), do: {k, d}
        {:ok, %{as_of: as_of, source: source, ons: Map.new(ons)}}
      end
    else
      {:ok, nil}
    end
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

  defp limits(plan, effects, state) do
    citations = Schema.table(:citations)
    cited = length(cited_cells(plan, effects))

    inserts =
      effects
      |> Enum.filter(fn {_, row_id, _} -> row_id == 0 end)
      |> Enum.frequencies_by(&elem(&1, 0))
      |> Enum.map(fn {id, n} -> {Schema.table(id), n} end)
      |> Enum.filter(fn {t, _} -> t.cap end)

    checks = if cited > 0, do: [{citations, cited} | inserts], else: inserts
    state = Enum.reduce(checks, state, fn {t, _}, st -> counted(st, t) end)

    case Enum.find(checks, fn {t, n} -> state.counts[t.id] + n > t.cap end) do
      nil -> {:ok, state}
      {t, _} -> {:refused, :cap, %{table: t.name, cap: t.cap}, state}
    end
  end

  defp cited_cells(%{table: table} = plan, effects) do
    for {id, _} <- own_cells(plan, effects), c = col(table, id), c.metric or c.prose, do: c
  end

  # A capped table's row count, read from SQLite once and then moved with
  # every insert and delete (count_deltas).
  defp counted(%{counts: counts} = state, table) when is_map_key(counts, table.id), do: state

  defp counted(state, table),
    do: put_in(state.counts[table.id], Repo.aggregate(Schema.row(table.name), :count))

  # ----------------------------------------------------------- the write

  defp write(plan, %{verb: :drop} = op, sub, _effects, _prov, state, turn) do
    {deltas, rev} = delete(plan.table, plan.row, turn.now)

    with :ok <- cascade_allowed(deltas, sub, state) do
      finish(state, turn, deltas, %{op_id: op.op_id, rev: rev, id: plan.row.id})
    end
  end

  defp write(plan, op, sub, effects, prov, state, turn) do
    ctx = %{sub: sub, op: op, turn: turn, plan: plan, prov: prov}

    {result, _} =
      Enum.reduce_while(effects, {{:ok, [], %{}, nil}, []}, fn {table_id, row_id, cells},
                                                               {{:ok, deltas, news, ack},
                                                                inserted} ->
        table = Schema.table(table_id)

        case effect(table, row_id, cells, inserted, ctx) do
          {:ok, row, changed} ->
            own = own?(plan, op, table_id, row_id, ack)

            inserted = if row_id == 0, do: inserted ++ [row.id], else: inserted

            ack =
              if own and ack == nil, do: %{op_id: op.op_id, rev: row.rev, id: row.id}, else: ack

            cited = if own and prov, do: [{:cited, cite(table, row, cells, prov, ctx)}], else: []
            {:cont, {{:ok, deltas ++ [{:put, table, row, changed} | cited], news, ack}, inserted}}

          refused ->
            {:halt, {refused, inserted}}
        end
      end)

    case result do
      {:ok, deltas, _news, ack} ->
        ack = ack || command_ack(plan, op)
        state = adopt(state, sub, deltas)
        finish(state, turn, deltas, ack)

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
        _, c -> c
      end)

    %{state | counts: counts}
  end

  defp bump(counts, id, n) when is_map_key(counts, id), do: Map.update!(counts, id, &(&1 + n))
  defp bump(counts, _id, _n), do: counts

  # The op's rows go to the kernel now, so the next op is judged on them.
  defp finish(state, turn, deltas, ack) do
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

    {:ok, count_deltas(state, deltas), %{turn | deltas: turn.deltas ++ deltas}, ack}
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

  # A deferred column's twin: `<col>_sha`, or for listing_raw its listing_sha.
  defp sha_twin(table, col) do
    Enum.find_value(
      [col.name <> "_sha", String.replace_suffix(col.name, "_raw", "_sha")],
      fn name -> (name != col.name and col(table, name)) && String.to_atom(name) end
    )
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

  # Deletes a row and, first, everything whose ref names it.
  defp delete(table, row, now) do
    deltas = dependents(table, row.id, now)
    pid = row.id

    if table.soft_delete do
      {:ok, row} =
        row
        |> Ecto.Changeset.change(deleted_at: now, rev: row.rev + 1, updated_at: now)
        |> Repo.update()

      {deltas ++ [{:gone, table, pid}], row.rev}
    else
      Repo.delete!(row)
      {deltas ++ [{:gone, table, pid}], row.rev + 1}
    end
  end

  defp dependents(table, id, now) do
    for t <- Schema.tables(),
        t.residency in [:resident, :server],
        c <- t.cols,
        c.ref == table.name,
        not c.implied do
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

  defp wire_cols(t, nil), do: Enum.reject(t.cols, &(&1.name == "account_id" or &1.wire == nil))

  defp wire_cols(t, grants),
    do: Enum.reject(Grants.columns(grants, t), &(&1.name == "account_id" or &1.wire == nil))

  defp rows(%{residency: :projection, source: source, source_term: term}) do
    from(r in Schema.row(source), order_by: r.id)
    |> restrict(Schema.table(source), term)
    |> Repo.all()
  end

  # Rows as maps of their wire columns. A deferred text is never loaded: its
  # length comes from SQLite and its hash from the hex SHA-256 the table
  # keeps beside it (`listing_raw` beside `listing_sha`).
  defp rows(t) do
    deferred = for c <- t.cols, c.deferred, do: c
    fields = for c <- t.cols, not c.deferred, c.wire != nil, do: String.to_atom(c.name)
    q = from(r in Schema.row(t.name), order_by: r.id, select: map(r, ^fields))
    q = if t.soft_delete, do: where(q, [r], is_nil(r.deleted_at)), else: q
    Enum.reduce(deferred, Repo.all(q), &stubs(t, &1, &2))
  end

  defp stubs(t, col, rows) do
    name = String.to_atom(col.name)
    sha = sha_twin(t, col)

    lens =
      from(r in Schema.row(t.name),
        where: not is_nil(field(r, ^name)),
        select: {r.id, fragment("length(CAST(? AS BLOB))", field(r, ^name))}
      )
      |> Repo.all()
      |> Map.new()

    # A listing without its stored hash (written before it, or by hand) is
    # hashed from the text, which only those rows load.
    missing = for r <- rows, lens[r.id] != nil, sha == nil or Map.get(r, sha) == nil, do: r.id

    texts =
      if missing == [],
        do: %{},
        else:
          Map.new(
            Repo.all(
              from(r in Schema.row(t.name),
                where: r.id in ^missing,
                select: {r.id, field(r, ^name)}
              )
            )
          )

    Enum.map(rows, fn row ->
      stub =
        case {lens[row.id], texts[row.id]} do
          {nil, _} ->
            nil

          {_, text} when is_binary(text) ->
            Codec.deferred_stub(text)

          {len, nil} ->
            {len, row |> Map.fetch!(sha) |> Base.decode16!(case: :lower) |> binary_part(0, 8)}
        end

      Map.put(row, name, stub)
    end)
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
              flags: Hireme.Schema.Parser.flags(c),
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
  defp lease_allowed({:claim, _, params}, %{key_id: key_id, grants: g}) when key_id != nil do
    claims = params["count"] not in [nil, 0] or params["ids"] not in [nil, []]

    cond do
      Security.hit(:agent_write, key_id, 1) != :ok ->
        {:refused, :rate, %{}}

      g.write_mask == 0 ->
        {:refused, :scope, %{reason: "the lease is for writing"}}

      claims and not Grants.write?(g, Schema.table(:applications)) ->
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

  defp lease_request({:revoke, lease_id}, _pid, state) do
    case Lease.revoke(state.lease, lease_id) do
      {:ok, lease, _released} -> {:ok, broadcast_leases(%{state | lease: lease}, [])}
      :error -> {{:error, :not_found}, state}
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
    {{:ok, %{"released" => released}}, broadcast_leases(%{state | lease: lease}, [])}
  end

  # A key's session taking or giving up the channel is audited, which also
  # wakes the account lens's parked watch: the operator sees agents come and go.
  defp audit_channels(before, after_) do
    for {sid, s} <- before.sessions,
        s.key_id != nil,
        s.channel != Lease.channel?(after_.lease, sid) do
      kind = if s.channel, do: :lease_released, else: :lease_opened
      held = MapSet.size(Lease.held(if(s.channel, do: before, else: after_.lease), sid))

      Hireme.Audit.record(kind, %{lease_id: sid, label: s.label, count: held}, %{
        account_id: after_.account_id,
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
        {DynamicSupervisor, name: Hireme.Sequencer.Dynamic, strategy: :one_for_one}
      ],
      strategy: :rest_for_one
    )
  end
end
