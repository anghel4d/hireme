defmodule Hireme.Ops do
  @moduledoc """
  The desk's write path: one sequencer process per account.

  Every write on an account runs here, one at a time, whoever asked (a
  browser tab's op, an agent's letterbox command, an import), so the
  account's changes have one total order. A write is one transaction:
  the ledger entry when the write is a client op, the domain write
  (`Hireme.Desk.execute/1` and the lane writes), and the account's
  revision bump. After commit the sequencer re-reads the rows the write
  reached and broadcasts what changed on `Hireme.Desk.topic/1`:

      {:ops_delta, rev, %{rows: %{table => [row]}, gone: %{table => [id]}}}

  then the reply. Local
  PubSub sends from this process and Erlang keeps the order of messages
  between two processes, so a caller always has the delta for its rev in
  its mailbox before the reply lands.

  The sequencer keeps the account's raw tables (`@tables`). A row in
  `rows` is new (every column) or changed (`id` and only the columns
  whose value moved); `gone` names rows removed. Every view is derived
  from these tables by the client; Elixir keeps its own derivations
  (`Hireme.Desk`, `Hireme.Heat`) for write authority and for agents.

  Client ops (`run/2`) are fixed-shape: a kind and a target id with string
  fields in a fixed order per kind. Their outcome is kept 24 hours under
  the client's op id, so a resend gets the first answer and never writes
  twice. A revision bump that is not the one this process expected (a
  write from another VM, such as a release task) re-reads every table.
  """

  use GenServer
  import Ecto.Query
  require Logger

  alias Hireme.Desk
  alias Hireme.Desk.Overlay
  alias Hireme.Gym
  alias Hireme.Heat
  alias Hireme.Net
  alias Hireme.Pipeline
  alias Hireme.Repo

  @registry __MODULE__.Registry
  @supervisor __MODULE__.Supervisor
  @inside {__MODULE__, :inside}
  @holder {__MODULE__, :holder}
  @ledger_ttl 24 * 3600
  @sweep_ms 3_600_000
  @batch 64
  @checkpoint_ms 1_000
  @store Application.compile_env(:hireme, :store, Hireme.Store)

  @kinds ~w(stage next note score overlay heat_override open_fire narrative gym_log gym_target net_log net_lane generation)a

  # The raw tables a client derives every view from: name, row module,
  # and the columns shipped, in schema order. `leases` is not stored: it
  # is the jobs an agent holds right now, one row (`id`, the job's) each.
  @tables [
    job_apps:
      {Hireme.Desk.Job,
       ~w(id profile_id employer_id batch_id company role location listing_url canonical_url
          listing heat status next_action next_due source stage_on current_stage pips
          stage_notes freshness gate fit squad department score_100 heat_override
          heat_override_reason no)a},
    profiles: {Hireme.Corpus.Profile, ~w(id user_id slug name headline summary)a},
    items:
      {Hireme.Corpus.Item, ~w(id profile_id kind key title body org span position keywords)a},
    cv_variants: {Hireme.Desk.Variant, ~w(id job_app_id profile_id lineage_id label theme note)a},
    cv_lineages:
      {Hireme.Cv.Lineage, ~w(id employer_id generation opened_on rewrites_allowed theme)a},
    overlays:
      {Hireme.Desk.Overlay,
       ~w(id job_app_id item_id lineage_id mode title body reason generation)a},
    batches:
      {Hireme.Desk.Batch, ~w(id code ordinal kind status fire target_size queued_on squad note)a},
    events: {Hireme.Desk.Event, ~w(id job_app_id kind body inserted_at)a},
    kv_pairs: {Hireme.Kv.Pair, ~w(id namespace key value)a},
    narratives: {Hireme.Corpus.Narrative, ~w(id user_id body version private)a},
    scoreboard_snapshots:
      {Hireme.Desk.Snapshot,
       ~w(id noted_on leftover_unique target_total target_on daily_batches daily_apps note)a},
    gym_problems: {Hireme.Gym.Problem, ~w(id platform slug title topic difficulty url)a},
    gym_reps: {Hireme.Gym.Rep, ~w(id problem_id done_on minutes outcome note)a},
    net_entries: {Hireme.Net.Entry, ~w(id kind channel title url body shipped_on)a}
  ]
  @table_names Keyword.keys(@tables) ++ [:leases]

  # Recent raw deltas kept for a session that resumes behind: bytes per account.
  @ring_bytes 4 * 1024 * 1024

  @typedoc "One client op, as the wire decodes it. `op_id` is the client's u64."
  @type op :: %{
          op_id: non_neg_integer(),
          kind: atom(),
          target: non_neg_integer(),
          fields: [binary()]
        }

  @type refusal :: atom() | {:argument, String.t()}

  @typedoc "Rows changed (new in full, else `id` and the changed columns) and ids removed, per table."
  @type delta :: %{rows: %{atom() => [map()]}, gone: %{atom() => [pos_integer()]}}

  @typedoc "A write as the sequencer runs it: a desk write, or a lane write."
  @type command ::
          Desk.write()
          | {:heat_override, pos_integer(), String.t()}
          | {:narrative, pos_integer(), String.t()}
          | {:gym_log, map()}
          | {:gym_target, term()}
          | {:net_log, map()}
          | {:net_lane, term()}

  # -- the supervision tree ---------------------------------------------------

  @doc "The registry and the supervisor the account sequencers run under."
  def child_spec(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @supervisor}
    ]

    # With SQLite's own checkpoint off, the WAL is folded into the
    # database here, beside the writes, never inside one's commit.
    repo = Application.get_env(:hireme, Repo)

    children =
      if repo[:wal_auto_check_point] == 0 and repo[:pool] != Ecto.Adapters.SQL.Sandbox,
        do: children ++ [Supervisor.child_spec({Task, &checkpoints/0}, id: :checkpoints)],
        else: children

    %{
      id: __MODULE__,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_all]]}
    }
  end

  @doc false
  # Every second, the store's upkeep (`c:Hireme.Store.checkpoint/0`). A
  # log left behind is folded by a running sequencer between two batches.
  def checkpoints do
    Process.sleep(@checkpoint_ms)

    with :behind <- @store.checkpoint(),
         [_ | _] = running <- Registry.select(@registry, [{{:_, :"$1", :_}, [], [:"$1"]}]),
         do: send(Enum.random(running), :fold)

    checkpoints()
  end

  @doc false
  def start_link({account_id, callers}) do
    GenServer.start_link(__MODULE__, {account_id, callers},
      name: {:via, Registry, {@registry, account_id}}
    )
  end

  # -- the API ----------------------------------------------------------------

  @doc """
  Run one client op. `{:ok, rev}` once it has committed and its delta has
  been sent to the account's topic (so it is already in the caller's
  mailbox when the caller subscribes); `{:error, refusal}` when it was
  refused. A resent `op_id` gets its first answer and no new delta.

  Fields per kind, all strings, in this order:

    * `:stage` `[stage]` · `:next` `[next_action, next_due_iso_or_empty]`
    * `:note` `[stage, note]` · `:score` `[0..100]`
    * `:overlay` `[item_id, hidden|emphasized|altered|inherit, body, reason, title?]`
    * `:heat_override` `[reason]` · `:open_fire` `[batch_code]` (target 0)
    * `:narrative` `[body]` (target is the narrative id)
    * `:gym_log` and `:net_log` `[key, value, key, value, …]` (target 0)
    * `:gym_target` `[n]` · `:net_lane` `[url]`
    * `:generation` `[]`: open the job's employer CV's next generation

  The target is the job id unless noted.
  """
  @spec run(pos_integer(), op()) :: {:ok, non_neg_integer()} | {:error, refusal()}
  def run(account_id, op), do: account_id |> submit(prepare(op)) |> await()

  @doc """
  `run/2` without waiting: stage the op here (parse and validate it, this
  process the lease holder), hand it to the sequencer, and answer with a
  reference. The result arrives as `{:ops_reply, ref, {:ok, rev} |
  {:error, refusal}}`, after the `{:ops_delta, rev, _}` it settles, and in
  the order the ops were sent. A refusal found while staging arrives the
  same way.
  """
  @spec send_run(pos_integer(), op()) :: reference()
  def send_run(account_id, op), do: elem(submit(account_id, prepare(op)), 1)

  # A malformed op still goes to the ledger: its id's first answer is the
  # one a resend gets, whatever the resend carries.
  defp prepare(%{op_id: op_id, kind: kind, target: target, fields: fields} = op)
       when is_integer(op_id) and op_id >= 0 and is_atom(kind) and is_integer(target) and
              is_list(fields) do
    write = %{op_id: signed(op_id), kind: Atom.to_string(kind), command: nil, refused: nil}

    case parse(op) do
      {:ok, command} -> %{write | command: command}
      {:error, reason} -> %{write | refused: reason}
    end
  end

  # Every write reaches the sequencer as one shape: a client op carries
  # its `op_id` (ledgered, answered with its revision), a domain write
  # `op_id: nil` (answered with its own value, a raise re-raised here).
  defp submit(account_id, write) when is_integer(account_id) do
    pid = server(account_id)
    ref = make_ref()
    send(pid, {:write, Map.merge(write, %{holder: self(), ref: ref})})
    {pid, ref}
  end

  defp await({pid, ref}) do
    monitor = Process.monitor(pid)

    receive do
      {:ops_reply, ^ref, reply} ->
        Process.demonitor(monitor, [:flush])

        case reply do
          {:raise, exception, stacktrace} -> reraise exception, stacktrace
          reply -> reply
        end

      {:DOWN, ^monitor, :process, _, _} ->
        {:error, :internal}
    end
  end

  @doc "The account's sequencer, if one runs."
  @spec whereis(pos_integer()) :: pid() | nil
  def whereis(account_id) do
    case Registry.lookup(@registry, account_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Subscribe the caller to the account's deltas and answer from where it
  stands. A session that holds the account at `since` and is still within
  the ring of recent deltas gets `{:replay, [{rev, delta}]}`: apply them in
  order. Otherwise, or with `since` nil, `{:boot, %{tables: %{table => [row]}}}`:
  every raw table at `rev`. Either way a later delta whose
  rev is at or below `rev` is already included.
  """
  @spec attach(pos_integer(), non_neg_integer() | nil) ::
          {:ok, non_neg_integer(),
           {:replay, [{non_neg_integer(), map()}]} | {:boot, %{tables: map()}}}
  def attach(account_id, since) when is_integer(account_id) do
    :ok = Phoenix.PubSub.subscribe(Hireme.PubSub, Desk.topic(account_id))

    call(account_id, {:attach, since})
  end

  @doc """
  Run one write as the account on this process, through its sequencer.
  The answer is the write's own `{:ok, value} | {:error, reason}`. On the
  sequencer itself (a write that calls another write) it runs in place.
  """
  @spec exec(command()) :: {:ok, term()} | {:error, term()}
  def exec(command) do
    case {Process.get(@inside), Repo.account_id()} do
      # With no account the write refuses itself (`Hireme.Schema.tenant/1`).
      {inside, account} when inside == true or account == nil -> apply_command(command)
      {_, account} -> account |> submit(%{op_id: nil, command: command, refused: nil}) |> await()
    end
  end

  @doc "Re-read the lease rows of these jobs (a lease taken or released) and send what changed."
  @spec touch(pos_integer(), [pos_integer()]) :: :ok
  def touch(account_id, job_ids) when is_integer(account_id) and is_list(job_ids) do
    # With no sequencer running there is no table to bring level; the
    # next one reads the database.
    case Registry.lookup(@registry, account_id) do
      [{pid, _}] -> GenServer.cast(pid, {:touch, job_ids})
      [] -> :ok
    end
  end

  @doc "Stop the account's sequencer, if one runs. Its table is rebuilt on next use."
  @spec stop(pos_integer()) :: :ok
  def stop(account_id) do
    # A stop, not a kill: a call or cast already in hand finishes its
    # query first, so no connection is dropped mid-statement.
    with [{pid, _}] <- Registry.lookup(@registry, account_id) do
      GenServer.stop(pid, :normal)
    end

    :ok
  catch
    :exit, _gone -> :ok
  end

  @doc "The process a write runs for, for lease checks; the caller itself outside the sequencer."
  @spec holder() :: pid()
  def holder, do: Process.get(@holder) || self()

  defp call(account_id, message) do
    case GenServer.call(server(account_id), message, :infinity) do
      {:raise, exception, stacktrace} -> reraise exception, stacktrace
      reply -> reply
    end
  end

  defp server(account_id) do
    case Registry.lookup(@registry, account_id) do
      [{pid, _}] ->
        pid

      [] ->
        callers = [self() | Process.get(:"$callers", [])]

        spec = %{
          id: account_id,
          start: {__MODULE__, :start_link, [{account_id, callers}]},
          restart: :temporary
        }

        case DynamicSupervisor.start_child(@supervisor, spec) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  # -- the sequencer ----------------------------------------------------------

  @impl true
  def init({account_id, callers}) do
    # A test's sandbox follows `$callers`, and a sequencer lives no longer
    # than the test that started it: the sandbox reuses account ids.
    Process.put(:"$callers", callers)

    if Application.get_env(:hireme, Repo)[:pool] == Ecto.Adapters.SQL.Sandbox,
      do: Process.monitor(hd(callers), tag: :owner_down)

    Process.put(@inside, true)
    Repo.put_account(account_id)
    Process.send_after(self(), :sweep, 0)

    {:ok,
     %{account: account_id, rev: nil, raw: nil, ledger: nil, ring: :queue.new(), ring_bytes: 0}}
  end

  @impl true
  # The tables are level at the sequencer's revision, so a boot is a copy
  # of them: every desk write runs here, and one made in another VM moves
  # the revision `warm/1` reads first. A listing is a shared binary, so
  # the copy is the row maps, not their text.
  def handle_call({:attach, since}, _from, state) do
    guard(state, fn ->
      state = warm(state)

      case replay(state, since) do
        {:ok, deltas} ->
          {{:ok, state.rev, {:replay, deltas}}, state}

        :boot ->
          tables = Map.new(state.raw, fn {t, rows} -> {t, Map.values(rows)} end)
          {{:ok, state.rev, {:boot, %{tables: tables}}}, state}
      end
    end)
  end

  @impl true
  def handle_cast({:touch, ids}, state) do
    {:noreply, state |> warm() |> settle([{:leases, :id, ids}])}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = DateTime.add(DateTime.utc_now(), -@ledger_ttl)
    @store.sweep(state.account, cutoff)
    Process.send_after(self(), :sweep, @sweep_ms)
    since = DateTime.to_unix(cutoff)

    ledger =
      state.ledger && Map.filter(state.ledger, fn {_op_id, {_reply, at}} -> at >= since end)

    {:noreply, %{state | ledger: ledger}}
  end

  def handle_info({:write, write}, state), do: {:noreply, seal(state, drain([write], 1))}

  def handle_info(:fold, state) do
    @store.checkpoint()
    {:noreply, state}
  end

  def handle_info({:owner_down, _ref, :process, _pid, _reason}, state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  # Staged ops still queued when the sequencer stops get an answer.
  @impl true
  def terminate(_reason, _state) do
    receive do
      {:write, write} ->
        answer(write, {:error, :internal})
        terminate(:drained, nil)
    after
      0 -> :ok
    end
  end

  # A raise is re-raised in the caller; the sequencer lives on, and since
  # the tables are suspect, the next call re-reads them all.
  defp guard(state, fun) do
    {reply, state} = fun.()
    {:reply, reply, state}
  rescue
    exception -> {:reply, {:raise, exception, __STACKTRACE__}, %{state | rev: nil}}
  end

  # -- the batch --------------------------------------------------------------

  # Take every write already waiting behind the first, up to @batch, in
  # mailbox order: an idle desk commits one at once, a busy one many.
  defp drain(batch, n) when n >= @batch, do: Enum.reverse(batch)

  defp drain(batch, n) do
    receive do
      {:write, write} -> drain([write | batch], n + 1)
    after
      0 -> Enum.reverse(batch)
    end
  end

  # Seal a batch: answer resends from the ledger, run the rest in order
  # in one transaction (each in a savepoint when there are several, so one
  # refusal leaves the others), number them, log them, commit once, then
  # send each revision's delta and each answer.
  defp seal(state, batch) do
    state = warm(state, false)
    state = if state.ledger, do: state, else: %{state | ledger: read_ledger(state.account)}

    {todo, answered} =
      Enum.split_with(batch, &(&1.op_id == nil or not Map.has_key?(state.ledger, &1.op_id)))

    Enum.each(answered, &answer(&1, elem(Map.fetch!(state.ledger, &1.op_id), 0)))

    {results, state} = commit(state, todo)
    finish(state, todo, results)
  rescue
    exception ->
      Logger.error(Exception.format(:error, exception, __STACKTRACE__))
      Enum.each(batch, &answer(&1, failed(&1, exception, __STACKTRACE__)))
      %{state | rev: nil}
  end

  defp commit(state, []), do: {[], state}

  defp commit(state, todo) do
    several? = match?([_, _ | _], todo)

    {:ok, results} =
      @store.transaction(fn ->
        results = Enum.map(todo, &apply_one(&1, state, several?))
        done = Enum.count(results, &match?({:ok, _, _}, &1))

        if done == 0 and not several? do
          [{:error, reason}] = results
          @store.rollback({:refused, reason})
        end

        last = if done > 0, do: bump!(state, done), else: state.rev
        numbered = number(results, last - done + 1)
        log!(state.account, todo, numbered)
        numbered
      end)
      |> case do
        # Alone and refused: nothing written, so its log line is its own.
        {:error, {:refused, reason}} ->
          log!(state.account, todo, [{:error, reason}])
          {:ok, [{:error, reason}]}

        ok ->
          ok
      end

    {results, state}
  end

  # One write of the batch. Alone, a refusal rolls back the transaction;
  # among several, its savepoint. A write of one statement needs none: a
  # statement that fails is undone by the database itself.
  defp apply_one(%{refused: reason}, _state, _several?) when reason != nil, do: {:error, reason}

  defp apply_one(%{command: command, holder: holder}, state, several?) do
    Process.put(@holder, holder)
    saved? = several? and not one_statement?(command)
    if saved?, do: @store.savepoint(:open)

    result =
      try do
        apply_command(command)
      rescue
        Ecto.NoResultsError -> {:error, :not_found}
        exception -> {:raise, exception, __STACKTRACE__}
      end

    Process.delete(@holder)

    case result do
      {:ok, value} ->
        if saved?, do: @store.savepoint(:keep)
        # Read what the write reached on the connection it holds: the
        # rows as they will commit, without a second checkout.
        {:ok, value, prefetch(groups(command, value), state.raw)}

      refused ->
        if saved?, do: @store.savepoint(:undo)

        case refused do
          {:error, reason} -> {:error, reason}
          {:raise, _, _} = raised -> raised
          other -> {:error, {:shape, other}}
        end
    end
  end

  # `Hireme.Desk`'s plain-column writes: a lease check, then one UPDATE.
  defp one_statement?({:score, _, _}), do: true
  defp one_statement?({kind, _, _, _}), do: kind in [:next, :note]
  defp one_statement?(_command), do: false

  defp number(results, first) do
    {numbered, _} =
      Enum.map_reduce(results, first, fn
        {:ok, value, fetched}, rev -> {{:ok, value, fetched, rev}, rev + 1}
        other, rev -> {other, rev}
      end)

    numbered
  end

  # Every client op's outcome, in one statement.
  defp log!(account, todo, results) do
    @store.log(
      account,
      for {%{op_id: op_id} = write, result} <- Enum.zip(todo, results),
          op_id != nil and not match?({:raise, _, _}, result) do
        case result do
          {:ok, _, _, rev} -> [op_id, write.kind, rev, nil]
          {:error, reason} -> [op_id, write.kind, 0, refusal_name(normalize(reason))]
        end
      end
    )
  end

  # After commit: each revision's delta in order, then each answer, so a
  # caller holds the delta before the answer that settles it.
  defp finish(state, todo, results) do
    state =
      Enum.reduce(results, state, fn
        {:ok, _value, fetched, rev}, state ->
          publish(state, rev, fetched)

        _, state ->
          state
      end)

    now = System.system_time(:second)

    # A raise is not ledgered (nor logged): a resend tries again.
    Enum.zip(todo, results)
    |> Enum.reduce(state, fn {write, result}, state ->
      reply = reply(write, result)
      answer(write, reply)

      if write.op_id && not match?({:raise, _, _}, result),
        do: %{state | ledger: Map.put(state.ledger, write.op_id, {reply, now})},
        else: state
    end)
  end

  # A client op is answered with its revision and a named refusal; a
  # domain write with its own value and reason.
  defp reply(write, {:ok, value, _fetched, rev}),
    do: {:ok, if(write.op_id, do: rev, else: value)}

  defp reply(write, {:error, reason}),
    do: {:error, if(write.op_id, do: normalize(reason), else: reason)}

  defp reply(write, {:raise, exception, stacktrace}), do: failed(write, exception, stacktrace)

  # A domain caller's raise is re-raised in its own process; a client op's
  # is answered `:internal` (its target and fields are the client's, and a
  # frame must never take down the session).
  defp failed(%{op_id: nil}, exception, stacktrace), do: {:raise, exception, stacktrace}

  defp failed(_write, exception, stacktrace) do
    Logger.error(Exception.format(:error, exception, stacktrace))
    {:error, :internal}
  end

  defp answer(write, reply), do: send(write.holder, {:ops_reply, write.ref, reply})

  # A write from another VM moved the counter: these tables are behind it.
  defp bump!(state, n \\ 1) do
    rev = @store.bump(state.account, n)
    if rev != state.rev + n, do: Process.put({__MODULE__, :gap}, true)
    rev
  end

  # Send revision `rev`'s delta: the groups the write reached, or every
  # table after a gap (revisions made elsewhere are not in the ring, so a
  # session behind the gap boots).
  defp publish(state, rev, groups) do
    gap? = Process.delete({__MODULE__, :gap})
    {state, delta} = rediff(state, if(gap?, do: :all, else: groups))
    broadcast(state, {:ops_delta, rev, delta})
    state = %{state | rev: rev}

    if gap?,
      do: remember(%{state | ring: :queue.new(), ring_bytes: 0}, rev, delta, true),
      else: remember(state, rev, delta)
  end

  # A change found outside a write (a lease, a row written around the
  # sequencer): a revision only when something differs.
  defp settle(state, source) do
    case rediff(state, source) do
      {next, %{rows: rows, gone: gone}} when rows == %{} and gone == %{} ->
        next

      {next, delta} ->
        rev = @store.transaction(fn -> bump!(state) end) |> elem(1)

        if Process.delete({__MODULE__, :gap}) do
          {next, rest} = rediff(next, :all)
          delta = join(delta, rest)
          broadcast(next, {:ops_delta, rev, delta})
          remember(%{next | rev: rev, ring: :queue.new(), ring_bytes: 0}, rev, delta, true)
        else
          broadcast(next, {:ops_delta, rev, delta})
          remember(%{next | rev: rev}, rev, delta)
        end
    end
  end

  # Two deltas as one: a row in both goes once, its columns merged.
  defp join(a, b) do
    rows =
      Map.merge(a.rows, b.rows, fn _t, x, y ->
        (x ++ y)
        |> Enum.group_by(& &1.id)
        |> Enum.map(fn {_id, parts} -> Enum.reduce(parts, &Map.merge(&2, &1)) end)
      end)

    %{rows: rows, gone: Map.merge(a.gone, b.gone, fn _t, x, y -> Enum.uniq(x ++ y) end)}
  end

  defp broadcast(state, message),
    do: Phoenix.PubSub.broadcast(Hireme.PubSub, Desk.topic(state.account), message)

  # The tables are read on first use and kept. A revision this process
  # did not make re-reads them all and sends the difference as its own
  # revision. A write skips the read of the revision (`look?` false): its
  # own bump finds any gap.
  defp warm(state, look? \\ true)

  defp warm(%{raw: nil} = state, _look?) do
    # The revision first: a write from another VM landing mid-read leaves
    # it behind the database, so the next attach re-reads.
    rev = @store.rev(state.account)
    raw = Map.new(read_tables(), fn {t, rows} -> {t, Map.new(rows, &{&1.id, &1})} end)

    %{
      state
      | rev: rev,
        raw: raw,
        ledger: nil,
        ring: :queue.new(),
        ring_bytes: 0
    }
  end

  defp warm(state, look?) do
    if state.rev == nil or (look? and state.rev != @store.rev(state.account)) do
      {next, delta} = rediff(state, :all)

      rev =
        @store.transaction(fn -> bump!(%{state | rev: @store.rev(state.account)}) end) |> elem(1)

      Process.delete({__MODULE__, :gap})
      broadcast(next, {:ops_delta, rev, delta})
      %{next | rev: rev, ring: :queue.new(), ring_bytes: 0} |> remember(rev, delta, true)
    else
      state
    end
  end

  # -- the raw tables ---------------------------------------------------------

  @doc """
  Every raw table a client view reads, for the account on this process,
  as `%{table => [row]}` with rows as plain maps of the shipped columns.
  The sequencer ships the same rows in `attach/2` and its deltas.
  """
  @spec read_tables() :: %{atom() => [map()]}
  def read_tables do
    tables = Map.new(@tables, fn {name, {schema, cols}} -> {name, read(schema, cols, nil)} end)
    Map.put(tables, :leases, leases(Map.get(tables, :job_apps) |> Enum.map(& &1.id)))
  end

  # Rows as SQLite holds them: text, integers, JSON text, ISO dates. They
  # go to the wire as they are (`HiremeWeb.Packet.raw/2`), so a boot is
  # one pass from the database to the frame with nothing decoded between.
  defp read(schema, cols, filter),
    do: @store.read(schema.__schema__(:source), cols, Repo.account_id!(), filter)

  defp leases(job_ids) do
    held = Hireme.Letterbox.leased_jobs()
    for id <- job_ids, MapSet.member?(held, id), do: %{id: id}
  end

  # Re-read the row groups a write reached and keep what differs from the
  # table: `{:rows, %{table => [row]}, :gone, %{table => [id]}}`. A group
  # is every row of a table whose `field` is one of `values`, so a row
  # that left it (an overlay dropped) is found gone. `:all` re-reads all.
  defp rediff(%{raw: nil} = state, _groups), do: {state, %{rows: %{}, gone: %{}}}

  defp rediff(state, :all) do
    groups = Enum.map(@table_names, &{&1, :all, nil})
    rediff(state, groups)
  end

  defp rediff(state, groups) do
    {raw, rows, gone} =
      Enum.reduce(groups, {state.raw, %{}, %{}}, fn group, {raw, rows, gone} ->
        {table, field, values, fresh} =
          case group do
            # Columns a write set, laid over the row as it stood.
            {:patch, table, moved} ->
              old = Map.fetch!(raw, table)
              rows = Enum.map(moved, &Map.merge(Map.get(old, &1.id, %{}), &1))
              {table, :id, Enum.map(moved, & &1.id), rows}

            {table, field, values} ->
              {table, field, values, fetch_group(table, field, values, raw)}

            {_, _, _, _} = fetched ->
              fetched
          end

        old = Map.fetch!(raw, table)
        fresh_ids = MapSet.new(fresh, & &1.id)

        changed = for row <- fresh, Map.get(old, row.id) != row, do: row
        sent = Enum.map(changed, &columns_moved(Map.get(old, &1.id), &1))

        left = left(old, fresh_ids, field, values)

        table_rows = Enum.reduce(changed, Map.drop(old, left), &Map.put(&2, &1.id, &1))

        {Map.put(raw, table, table_rows), merge(rows, table, sent), merge(gone, table, left)}
      end)

    # Committed by now: a hot job that moved retires the kept snapshot.
    {%{state | raw: raw}, %{rows: rows, gone: gone}}
  end

  # The group's rows that are no longer in it. A group by id names its
  # rows, so they are looked up rather than the table walked.
  defp left(old, fresh_ids, :id, ids),
    do: for(id <- Enum.uniq(ids), is_map_key(old, id), not MapSet.member?(fresh_ids, id), do: id)

  defp left(old, fresh_ids, field, values) do
    for {id, row} <- old,
        not MapSet.member?(fresh_ids, id),
        field == :all or Map.fetch!(row, field) in values,
        do: id
  end

  # A new row goes in full; a changed one as its id and the columns that
  # moved, so a next action does not resend a listing.
  defp columns_moved(nil, row), do: row

  defp columns_moved(old, row) do
    for {k, v} <- row, k == :id or Map.get(old, k) != v, into: %{}, do: {k, v}
  end

  defp prefetch(:all, _raw), do: :all
  defp prefetch(_groups, nil), do: []

  defp prefetch(groups, raw) do
    for group <- groups do
      case group do
        {:patch, _, _} = patch -> patch
        {table, field, values} -> {table, field, values, fetch_group(table, field, values, raw)}
        {_, _, _, _} = fetched -> fetched
      end
    end
  end

  defp fetch_group(:leases, :all, _values, raw), do: leases(Map.keys(raw.job_apps))

  defp fetch_group(:leases, :id, ids, raw),
    do: leases(Enum.filter(ids, &Map.has_key?(raw.job_apps, &1)))

  defp fetch_group(table, :all, _values, _raw) do
    {schema, cols} = Keyword.fetch!(@tables, table)
    read(schema, cols, nil)
  end

  defp fetch_group(table, field, values, _raw) do
    {schema, cols} = Keyword.fetch!(@tables, table)
    read(schema, cols, {field, values})
  end

  defp merge(acc, _table, []), do: acc

  defp merge(acc, table, list),
    do:
      Map.update(
        acc,
        table,
        list,
        &Enum.uniq_by(&1 ++ list, fn
          %{id: id} -> id
          id -> id
        end)
      )

  # The ring: each revision's raw delta, newest last, within @ring_bytes.
  # `from` is the revision it applies to.
  defp remember(state, rev, raw, fresh? \\ false) do
    from = if fresh?, do: rev, else: rev - 1
    bytes = :erlang.external_size(raw)
    ring = :queue.in({from, rev, raw, bytes}, state.ring)
    trim(%{state | ring: ring, ring_bytes: state.ring_bytes + bytes})
  end

  defp trim(%{ring_bytes: bytes} = state) when bytes <= @ring_bytes, do: state

  defp trim(state) do
    {{:value, {_, _, _, bytes}}, ring} = :queue.out(state.ring)
    trim(%{state | ring: ring, ring_bytes: state.ring_bytes - bytes})
  end

  # The deltas after `since`, if the ring still reaches back to it.
  defp replay(_state, nil), do: :boot
  defp replay(%{rev: rev}, rev), do: {:ok, []}

  defp replay(state, since) do
    entries = :queue.to_list(state.ring)

    case Enum.drop_while(entries, fn {from, _, _, _} -> from != since end) do
      [] -> :boot
      tail -> {:ok, Enum.map(tail, fn {_, rev, raw, _} -> {rev, raw} end)}
    end
  end

  @doc false
  # Set plain columns of one row of the account's in one statement and
  # answer with what moved, as shipped: the id and the columns set (a
  # JSON column's new text, `{:json_put, key, value}`, read back from it).
  @spec write_row(atom(), pos_integer(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def write_row(table, id, changes) do
    {schema, _cols} = Keyword.fetch!(@tables, table)
    @store.write(schema.__schema__(:source), id, Repo.account_id!(), changes)
  end

  @doc false
  # The account's next application number, taken in the write that opens
  # the application so it is never handed out twice.
  @spec number!() :: pos_integer()
  def number!, do: @store.number(Repo.account_id!())

  # The row groups a committed write can have touched.
  defp groups(command, value) do
    case command do
      {:create, _} ->
        lineage = lineage_of(value.id)

        [
          {:job_apps, :id, Desk.lineage_jobs(value.id)},
          {:cv_variants, :lineage_id, [lineage]},
          {:cv_variants, :job_app_id, [value.id]},
          {:cv_lineages, :id, [lineage]},
          {:overlays, :lineage_id, [lineage]},
          {:events, :job_app_id, [value.id]},
          {:leases, :id, [value.id]}
        ]

      {kind, id, _} when kind in [:stage, :heat_override] ->
        job_groups(id)

      # The write answered with what it moved: no re-read.
      {:score, _, _} ->
        [{:patch, :job_apps, [value]}]

      {kind, _, _, _} when kind in [:next, :note] ->
        [{:patch, :job_apps, [value]}]

      {:generation, id} ->
        [{:cv_lineages, :id, [lineage_of(id)]}]

      {:overlay, id, _, _} ->
        lineage_groups(id)

      {:open_fire, code} ->
        [{:batches, :code, [code]}]

      {:govern, _} ->
        :all

      {:bulk, _} ->
        :all

      {:insert, table, _} ->
        [{table, :id, [inserted_id(value)]}]

      {:narrative, id, _} ->
        [{:narratives, :id, [id]}]

      {:gym_log, _} ->
        [{:gym_reps, :id, [value.id]}, {:gym_problems, :id, [value.problem_id]}]

      {:gym_target, _} ->
        [{:kv_pairs, :namespace, ["gym"]}]

      {:net_log, _} ->
        [{:net_entries, :id, [value.id]}]

      {:net_lane, _} ->
        [{:kv_pairs, :namespace, ["net"]}]
    end
  end

  defp inserted_id({_result, %{id: id}}), do: id
  defp inserted_id(%{id: id}), do: id

  defp job_groups(id), do: [{:job_apps, :id, [id]}, {:events, :job_app_id, [id]}]

  defp lineage_groups(job_id) do
    lineage = lineage_of(job_id)

    [
      {:job_apps, :id, Desk.lineage_jobs(job_id)},
      {:overlays, :lineage_id, [lineage]},
      {:cv_lineages, :id, [lineage]}
    ]
  end

  defp lineage_of(job_id) do
    Repo.one(from v in Hireme.Desk.Variant, where: v.job_app_id == ^job_id, select: v.lineage_id)
  end

  # -- the commands -----------------------------------------------------------

  defp apply_command({:heat_override, job_id, reason}), do: Heat.write_override(job_id, reason)
  defp apply_command({:bulk, fun}), do: {:ok, fun.()}
  defp apply_command({:insert, _table, fun}), do: {:ok, fun.()}

  defp apply_command({:narrative, id, body}) do
    case Repo.get(Hireme.Corpus.Narrative, id) do
      nil -> {:error, :not_found}
      row -> {:ok, Hireme.Narrative.update!(row, body)}
    end
  end

  defp apply_command({:gym_log, attrs}), do: Gym.log(attrs)
  defp apply_command({:gym_target, target}), do: Gym.set_target(target)
  defp apply_command({:net_log, attrs}), do: Net.log(attrs)
  defp apply_command({:net_lane, url}), do: Net.set_lane(url)
  defp apply_command(command), do: Desk.execute(command)

  # -- parsing a client op ----------------------------------------------------

  defp parse(%{kind: :stage, target: id, fields: [stage]}) do
    with {:ok, stage} <- stage(stage), do: {:ok, {:stage, id, stage}}
  end

  defp parse(%{kind: :next, target: id, fields: [action, due]}) do
    due =
      case Date.from_iso8601(due) do
        {:ok, date} -> date
        _ -> nil
      end

    {:ok, {:next, id, String.trim(action), due}}
  end

  defp parse(%{kind: :note, target: id, fields: [stage, note]}) do
    with {:ok, stage} <- stage(stage), do: {:ok, {:note, id, stage, note}}
  end

  defp parse(%{kind: :score, target: id, fields: [score]}) do
    case Integer.parse(score) do
      {n, ""} when n in 0..100 -> {:ok, {:score, id, n}}
      _ -> {:error, {:argument, "score"}}
    end
  end

  defp parse(%{kind: :overlay, fields: [_, _, _, _]} = op),
    do: parse(%{op | fields: op.fields ++ [""]})

  defp parse(%{kind: :overlay, target: id, fields: [item_id, mode, body, reason, title]}) do
    with {:ok, item_id} <- int(item_id, "item_id"),
         {:ok, change} <- overlay_change(mode, body, reason, title) do
      {:ok, {:overlay, id, item_id, change}}
    end
  end

  defp parse(%{kind: :heat_override, target: id, fields: [reason]}),
    do: {:ok, {:heat_override, id, reason}}

  defp parse(%{kind: :open_fire, fields: [code]}), do: {:ok, {:open_fire, code}}
  defp parse(%{kind: :narrative, target: id, fields: [body]}), do: {:ok, {:narrative, id, body}}

  defp parse(%{kind: :gym_log, fields: fields}) do
    with {:ok, attrs} <- pairs(fields), do: {:ok, {:gym_log, attrs}}
  end

  defp parse(%{kind: :gym_target, fields: [target]}), do: {:ok, {:gym_target, target}}

  defp parse(%{kind: :net_log, fields: fields}) do
    with {:ok, attrs} <- pairs(fields), do: {:ok, {:net_log, attrs}}
  end

  defp parse(%{kind: :net_lane, fields: [url]}), do: {:ok, {:net_lane, url}}
  defp parse(%{kind: :generation, target: id, fields: []}), do: {:ok, {:generation, id}}
  defp parse(%{kind: kind}) when kind in @kinds, do: {:error, {:argument, "fields"}}
  defp parse(_op), do: {:error, :kind}

  defp stage(name) do
    case Pipeline.parse(name) do
      {:ok, stage} -> {:ok, stage}
      _ -> {:error, {:argument, "stage"}}
    end
  end

  defp int(text, name) do
    case Integer.parse(text) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, {:argument, name}}
    end
  end

  defp pairs(fields) when rem(length(fields), 2) == 0 do
    {:ok, fields |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)}
  end

  defp pairs(_fields), do: {:error, {:argument, "fields"}}

  defp overlay_change("inherit", _body, _reason, _title), do: {:ok, :inherit}

  defp overlay_change(mode, body, reason, title) do
    case Overlay.parse_mode(mode) do
      {:ok, :altered} ->
        case String.trim(body) do
          "" -> {:error, {:argument, "body"}}
          body -> {:ok, %{mode: :altered, body: body, reason: blank(reason), title: blank(title)}}
        end

      {:ok, :hidden} ->
        {:ok, %{mode: :hidden, reason: blank(reason) || "Hidden from this CV"}}

      {:ok, :emphasized} ->
        {:ok, %{mode: :emphasized, reason: blank(reason) || "Emphasized for this CV"}}

      :error ->
        {:error, {:argument, "mode"}}
    end
  end

  defp blank(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  # -- the ledger -------------------------------------------------------------

  defp read_ledger(account) do
    since = DateTime.add(DateTime.utc_now(), -@ledger_ttl)

    Map.new(@store.ledger(account, since), fn {op_id, rev, refusal, at} ->
      {op_id, {if(refusal, do: {:error, refusal(refusal)}, else: {:ok, rev}), at}}
    end)
  end

  defp normalize(%Ecto.Changeset{}), do: :invalid
  defp normalize({:argument, name}) when is_binary(name), do: {:argument, name}
  defp normalize(reason) when is_atom(reason), do: reason
  defp normalize(_), do: :invalid

  defp refusal_name({:argument, name}), do: "argument:" <> name
  defp refusal_name(reason), do: Atom.to_string(reason)

  defp refusal("argument:" <> name), do: {:argument, name}
  defp refusal(name), do: String.to_existing_atom(name)

  # The client's u64 in SQLite's signed 64-bit integer.
  defp signed(op_id) do
    <<n::signed-64>> = <<op_id::unsigned-64>>
    n
  end
end
