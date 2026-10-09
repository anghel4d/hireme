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

  then the held `{:desk_event, Signal}` messages, then the reply. Local
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

  alias Hireme.Accounts.Account
  alias Hireme.Desk
  alias Hireme.Desk.Overlay
  alias Hireme.Gym
  alias Hireme.Heat
  alias Hireme.Net
  alias Hireme.Ops.Entry
  alias Hireme.Pipeline
  alias Hireme.Repo

  @registry __MODULE__.Registry
  @heat __MODULE__.Heat
  @supervisor __MODULE__.Supervisor
  @inside {__MODULE__, :inside}
  @holder {__MODULE__, :holder}
  @held {__MODULE__, :held}
  @ledger_ttl 24 * 3600
  @sweep_ms 3_600_000

  @kinds ~w(stage next note score overlay heat_override open_fire narrative gym_log gym_target net_log net_lane)a

  # The raw tables a client derives every view from: name, row module,
  # and the columns shipped, in schema order. `leases` is not stored: it
  # is the jobs an agent holds right now, one row (`id`, the job's) each.
  @tables [
    job_apps:
      {Hireme.Desk.Job,
       ~w(id profile_id employer_id batch_id company role location listing_url canonical_url
          listing heat status next_action next_due source stage_on current_stage pips
          stage_notes freshness gate fit squad department score_100 heat_override
          heat_override_reason keyword_hits keyword_total mask_hidden mask_altered
          mask_emphasized)a},
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
      {Hireme.Desk.Batch,
       ~w(id code ordinal kind status fire target_size queued_on squad variety note)a},
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
      # Each account's prepared heat snapshot and its generation, read
      # without a call into the sequencer.
      Supervisor.child_spec(
        {Agent, fn -> :ets.new(@heat, [:named_table, :public, read_concurrency: true]) end},
        id: @heat
      ),
      {DynamicSupervisor, strategy: :one_for_one, name: @supervisor}
    ]

    %{
      id: __MODULE__,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_all]]}
    }
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
    * `:overlay` `[item_id, hidden|emphasized|altered|inherit, body, reason]`
    * `:heat_override` `[reason]` · `:open_fire` `[batch_code]` (target 0)
    * `:narrative` `[body]` (target is the narrative id)
    * `:gym_log` and `:net_log` `[key, value, key, value, …]` (target 0)
    * `:gym_target` `[n]` · `:net_lane` `[url]`

  The target is the job id unless noted.
  """
  @spec run(pos_integer(), op()) :: {:ok, non_neg_integer()} | {:error, refusal()}
  def run(account_id, %{op_id: op_id, kind: kind, target: target, fields: fields} = op)
      when is_integer(account_id) and is_integer(op_id) and op_id >= 0 and is_atom(kind) and
             is_integer(target) and is_list(fields) do
    call(account_id, {:run, op, self()})
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

    case call(account_id, {:attach, since}) do
      {:ok, _rev, {:replay, _}} = replay -> replay
      :boot -> boot(account_id, 3)
    end
  end

  # A boot reads every table here, in the attaching process, so writes
  # on the account never wait behind it: one read transaction, stamped
  # with the revision it saw. The sequencer then only compares. At the
  # same revision, what differs is a row written around it, sent to
  # everyone as a revision of its own; behind it, the ring's deltas
  # since the read bring the tables level.
  defp boot(account_id, tries) do
    {:ok, {read_rev, tables}} =
      Repo.with_account(account_id, fn ->
        Repo.transaction(fn ->
          rev =
            Repo.one!(from(a in Account, where: a.id == ^account_id, select: a.desk_rev),
              skip_account: true
            )

          {rev, read_tables()}
        end)
      end)

    case call(account_id, {:boot, read_rev, tables}) do
      {:ok, rev, :as_read} -> {:ok, rev, {:boot, %{tables: tables}}}
      {:ok, rev, {:after, deltas}} -> {:ok, rev, {:boot, %{tables: patch(tables, deltas)}}}
      :retry when tries > 1 -> boot(account_id, tries - 1)
      :retry -> call(account_id, :boot_inside)
    end
  end

  defp patch(tables, deltas) do
    deltas
    |> Enum.reduce(Map.new(tables, fn {t, rows} -> {t, Map.new(rows, &{&1.id, &1})} end), fn
      {_rev, %{rows: rows, gone: gone}}, acc ->
        acc =
          Enum.reduce(gone, acc, fn {t, ids}, acc -> Map.update!(acc, t, &Map.drop(&1, ids)) end)

        Enum.reduce(rows, acc, fn {t, list}, acc ->
          Map.update!(acc, t, fn table ->
            Enum.reduce(list, table, fn row, t ->
              Map.update(t, row.id, row, &Map.merge(&1, row))
            end)
          end)
        end)
    end)
    |> Map.new(fn {t, rows} -> {t, Map.values(rows)} end)
  end

  @doc """
  Run one write as the account on this process, through its sequencer.
  The answer is the write's own `{:ok, value} | {:error, reason}`. On the
  sequencer itself (a write that calls another write) it runs in place.
  """
  @spec exec(command()) :: {:ok, term()} | {:error, term()}
  def exec(command) do
    if Process.get(@inside) do
      apply_command(command)
    else
      call(Repo.account_id!(), {:exec, command, self()})
    end
  end

  @doc """
  Start the account's sequencer and load its tables now, without
  waiting, so the session that follows a page load attaches warm.
  """
  @spec prewarm(pos_integer()) :: :ok
  def prewarm(account_id) when is_integer(account_id) do
    GenServer.cast(server(account_id), :prewarm)
  end

  @doc """
  The account's prepared heat snapshot for today, for judging many
  applications at once (`Hireme.Desk.focuses/2`). Read here, in the
  caller, so an agent's read never waits behind the account's writes.

  The sequencer bumps the account's heat generation after any commit
  that moves a hot job's standing; a snapshot is kept under the
  generation read before it was built, so one built across a write is
  never served after it. A miss reads the hot jobs, lending the
  previous snapshot's traits to the next.
  """
  @spec heat(pos_integer()) :: map()
  def heat(account_id) when is_integer(account_id) do
    today = Date.utc_today()
    generation = heat_generation(account_id)

    case :ets.lookup(@heat, account_id) do
      [{_, ^generation, ^today, heat}] ->
        heat

      found ->
        previous = with [{_, _, _, heat}] <- found, do: heat
        cfg = Heat.config()

        previous = if previous == [], do: nil, else: previous

        heat =
          Repo.with_account(account_id, fn -> Heat.snapshot(today, cfg, previous) end)
          |> Heat.prepare(cfg, today, previous)

        :ets.insert(@heat, {account_id, generation, today, heat})
        heat
    end
  end

  defp heat_generation(account_id) do
    case :ets.lookup(@heat, {:generation, account_id}) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  # What a peer contributes to the heat snapshot (`Heat.snapshot/2`).
  @heat_fields ~w(current_stage stage_on company role listing_url canonical_url department
                  squad fit score_100 heat_override heat_override_reason)a

  defp moved_heat(account_id, rows, gone) do
    moved? =
      Map.has_key?(gone, :job_apps) or
        Enum.any?(Map.get(rows, :job_apps, []), fn row ->
          Enum.any?(@heat_fields, &Map.has_key?(row, &1))
        end)

    if moved?,
      do: :ets.update_counter(@heat, {:generation, account_id}, 1, {{:generation, account_id}, 0})
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

    :ets.delete(@heat, account_id)
    :ets.delete(@heat, {:generation, account_id})
    :ok
  catch
    :exit, _gone -> :ok
  end

  @doc "The process a write runs for, for lease checks; the caller itself outside the sequencer."
  @spec holder() :: pid()
  def holder, do: Process.get(@holder) || self()

  @doc false
  # A message to broadcast on the account's topic once the write commits.
  @spec after_commit(term()) :: :ok
  def after_commit(message) do
    if Process.get(@inside) do
      Process.put(@held, [message | Process.get(@held, [])])
    else
      Phoenix.PubSub.broadcast(Hireme.PubSub, Desk.topic(), message)
    end

    :ok
  end

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

    {:ok, %{account: account_id, rev: nil, raw: nil, ring: :queue.new(), ring_bytes: 0}}
  end

  @impl true
  def handle_call({:attach, since}, _from, state) do
    guard(state, fn ->
      state = warm(state)

      case replay(state, since) do
        {:ok, deltas} -> {{:ok, state.rev, {:replay, deltas}}, state}
        :boot -> {:boot, state}
      end
    end)
  end

  def handle_call({:boot, read_rev, tables}, _from, state) do
    guard(state, fn ->
      state = warm(state)

      cond do
        read_rev == state.rev ->
          state = settle(state, {:given, tables})
          {{:ok, state.rev, :as_read}, state}

        read_rev < state.rev ->
          case replay(state, read_rev) do
            {:ok, deltas} -> {{:ok, state.rev, {:after, deltas}}, state}
            :boot -> {:retry, state}
          end

        true ->
          {:retry, state}
      end
    end)
  end

  # The fallback when reads keep losing the race: read in here.
  def handle_call(:boot_inside, _from, state) do
    guard(state, fn ->
      state = settle(warm(state), :all)
      tables = Map.new(state.raw, fn {t, rows} -> {t, Map.values(rows)} end)
      {{:ok, state.rev, {:boot, %{tables: tables}}}, state}
    end)
  end

  def handle_call({:exec, command, holder}, _from, state) do
    guard(state, fn ->
      case commit(warm(state, false), command, holder, nil) do
        {{:ok, value, _rev}, state} -> {{:ok, value}, state}
        {{:error, reason}, state} -> {{:error, reason}, state}
      end
    end)
  end

  def handle_call({:run, op, holder}, _from, state) do
    guard(state, :wire, fn ->
      state = warm(state, false)
      op_id = signed(op.op_id)

      case Repo.one(from e in Entry, where: e.op_id == ^op_id) do
        %Entry{refusal: nil, rev: rev} ->
          {{:ok, rev}, state}

        %Entry{refusal: refusal} ->
          {{:error, refusal(refusal)}, state}

        nil ->
          ledger = {op_id, Atom.to_string(op.kind)}

          with {:ok, command} <- parse(op),
               {{:ok, _value, rev}, state} <- commit(state, command, holder, ledger) do
            {{:ok, rev}, state}
          else
            {{:error, reason}, state} -> {{:error, record_refusal(ledger, reason, state)}, state}
            {:error, reason} -> {{:error, record_refusal(ledger, reason, state)}, state}
          end
      end
    end)
  end

  @impl true
  def handle_cast(:prewarm, state), do: {:noreply, warm(state)}

  def handle_cast({:touch, ids}, state) do
    {:noreply, state |> warm() |> settle([{:leases, :id, ids}])}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = DateTime.add(DateTime.utc_now(), -@ledger_ttl)
    Repo.delete_all(from e in Entry, where: e.inserted_at < ^cutoff)
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  def handle_info({:owner_down, _ref, :process, _pid, _reason}, state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  # A raise inside a write rolled it back. A domain caller gets it
  # re-raised in its own process; a client op is answered `:internal`,
  # since its target and fields are the client's and a frame must never
  # take down the session that carried it. Either way the sequencer
  # lives on, and because a raise after commit leaves the tables
  # suspect, the next call re-reads them all.
  defp guard(state, mode \\ :domain, fun) do
    {reply, state} = fun.()
    {:reply, reply, state}
  rescue
    exception ->
      state = %{state | rev: nil}

      case mode do
        :domain ->
          {:reply, {:raise, exception, __STACKTRACE__}, state}

        :wire ->
          Logger.error(Exception.format(:error, exception, __STACKTRACE__))
          {:reply, {:error, :internal}, state}
      end
  end

  # -- one write --------------------------------------------------------------

  defp commit(state, command, holder, ledger) do
    Process.put(@holder, holder)
    Process.put(@held, [])

    # A row the account cannot see (another account's, or none) is a
    # refusal, whichever lookup in the write found it missing.
    result =
      try do
        Repo.transaction(fn ->
          case apply_command(command) do
            {:ok, value} ->
              rev = bump!(state)
              if ledger, do: insert_entry!(ledger, rev, nil)
              {value, rev}

            {:error, reason} ->
              Repo.rollback(reason)

            other ->
              Repo.rollback({:shape, other})
          end
        end)
      rescue
        Ecto.NoResultsError -> {:error, :not_found}
      after
        Process.delete(@holder)
      end

    held = (Process.delete(@held) || []) |> Enum.reverse()

    case result do
      {:ok, {value, rev}} ->
        state = publish(state, rev, groups(command, value))
        Enum.each(held, &broadcast(state, &1))
        {{:ok, value, rev}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  # A write from another VM moved the counter: these tables are behind it.
  defp bump!(state) do
    {1, [rev]} =
      Repo.update_all(
        from(a in Account, where: a.id == ^state.account, select: a.desk_rev),
        [inc: [desk_rev: 1]],
        skip_account: true
      )

    if rev != state.rev + 1, do: Process.put({__MODULE__, :gap}, true)
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
        rev = Repo.transaction(fn -> bump!(state) end) |> elem(1)

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
    raw = Map.new(read_tables(), fn {t, rows} -> {t, Map.new(rows, &{&1.id, &1})} end)
    %{state | rev: db_rev(state), raw: raw, ring: :queue.new(), ring_bytes: 0}
  end

  defp warm(state, look?) do
    if state.rev == nil or (look? and state.rev != db_rev(state)) do
      {next, delta} = rediff(state, :all)
      rev = Repo.transaction(fn -> bump!(%{state | rev: db_rev(state)}) end) |> elem(1)
      Process.delete({__MODULE__, :gap})
      broadcast(next, {:ops_delta, rev, delta})
      %{next | rev: rev, ring: :queue.new(), ring_bytes: 0} |> remember(rev, delta, true)
    else
      state
    end
  end

  defp db_rev(state) do
    Repo.one!(from(a in Account, where: a.id == ^state.account, select: a.desk_rev),
      skip_account: true
    )
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

  defp read(schema, cols, nil), do: Repo.all(from(r in schema, select: map(r, ^cols)))

  defp read(schema, cols, {field, values}),
    do: Repo.all(from(r in schema, where: field(r, ^field) in ^values, select: map(r, ^cols)))

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

  defp rediff(state, {:given, tables}) do
    groups = Enum.map(@table_names, &{&1, :all, {:given, Map.fetch!(tables, &1)}})
    rediff(state, groups)
  end

  defp rediff(state, groups) do
    {raw, rows, gone} =
      Enum.reduce(groups, {state.raw, %{}, %{}}, fn {table, field, values}, {raw, rows, gone} ->
        old = Map.fetch!(raw, table)
        fresh = fetch_group(table, field, values, raw)
        fresh_ids = MapSet.new(fresh, & &1.id)

        changed = for row <- fresh, Map.get(old, row.id) != row, do: row
        sent = Enum.map(changed, &columns_moved(Map.get(old, &1.id), &1))

        left =
          for {id, row} <- old,
              not MapSet.member?(fresh_ids, id),
              field == :all or Map.fetch!(row, field) in values,
              do: id

        table_rows = Enum.reduce(changed, Map.drop(old, left), &Map.put(&2, &1.id, &1))

        {Map.put(raw, table, table_rows), merge(rows, table, sent), merge(gone, table, left)}
      end)

    # Committed by now: a hot job that moved retires the kept snapshot.
    moved_heat(state.account, rows, gone)
    {%{state | raw: raw}, %{rows: rows, gone: gone}}
  end

  # A new row goes in full; a changed one as its id and the columns that
  # moved, so a next action does not resend a listing.
  defp columns_moved(nil, row), do: row

  defp columns_moved(old, row) do
    for {k, v} <- row, k == :id or Map.get(old, k) != v, into: %{}, do: {k, v}
  end

  defp fetch_group(_table, :all, {:given, rows}, _raw), do: rows
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

      {kind, id, _} when kind in [:stage, :score, :heat_override] ->
        job_groups(id)

      {kind, id, _, _} when kind in [:next, :note] ->
        job_groups(id)

      {:glance, id} ->
        job_groups(id)

      {:overlay, id, _, _} ->
        lineage_groups(id)

      {:open_fire, code} ->
        [{:batches, :code, [code]}]

      {:govern, _} ->
        :all

      {:perform, pair, command} ->
        job_id = Hireme.CvPair.job_id(pair)

        case command do
          {:set_stage, stage} -> groups({:stage, job_id, stage}, value)
          {:set_score, score} -> groups({:score, job_id, score}, value)
          {:set_next, action} -> groups({:next, job_id, action, nil}, value)
          {:tailor, item_id, attrs} -> groups({:overlay, job_id, item_id, attrs}, value)
          :open_generation -> [{:cv_lineages, :id, [lineage_of(job_id)]}]
          _ -> []
        end

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

  defp parse(%{kind: :overlay, target: id, fields: [item_id, mode, body, reason]}) do
    with {:ok, item_id} <- int(item_id, "item_id"),
         {:ok, change} <- overlay_change(mode, body, reason) do
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

  defp overlay_change("inherit", _body, _reason), do: {:ok, :inherit}

  defp overlay_change(mode, body, reason) do
    case Overlay.parse_mode(mode) do
      {:ok, :altered} ->
        case String.trim(body) do
          "" -> {:error, {:argument, "body"}}
          body -> {:ok, %{mode: :altered, body: body, reason: blank(reason)}}
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

  defp insert_entry!({op_id, kind}, rev, refusal) do
    %Entry{}
    |> Entry.changeset(%{op_id: op_id, kind: kind, rev: rev, refusal: refusal})
    |> Repo.insert!()
  end

  defp record_refusal(ledger, reason, state) do
    reason = normalize(reason)
    insert_entry!(ledger, state.rev, refusal_name(reason))
    reason
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
