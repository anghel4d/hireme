defmodule Hireme.Ops do
  @moduledoc """
  The desk's write path: one sequencer process per account.

  Every write on an account runs here, one at a time, whoever asked (a
  browser tab's op, an agent's letterbox command, an import), so the
  account's changes have one total order. A write is one transaction:
  the ledger entry when the write is a client op, the domain write
  (`Hireme.Desk.execute/1` and the lane writes), and the account's
  revision bump. After commit the sequencer works out what changed and
  broadcasts it on `Hireme.Desk.topic/1`:

      {:ops_delta, rev, %{cards: [Card.t()], deleted: [id], focus: [job_id],
                          roots: [profile_id], scoreboard: bool, lanes: bool,
                          batches: bool, narrative: bool}}

  then the held `{:desk_event, Signal}` messages, then the reply. Local
  PubSub sends from this process and Erlang keeps the order of messages
  between two processes, so a caller always has the delta for its rev in
  its mailbox before the reply lands.

  `cards` holds only the rows whose value changed. The sequencer keeps
  the account's painted card table and its heat snapshot; a write
  recomputes the rows it reaches (the job; its CV lineage for a CV
  change; the batch for open fire) and, when a job's standing in the
  heat snapshot moved, rebuilds the snapshot and repaints every card at
  the same company or on the same ATS vendor, before and after. A day
  rollover repaints all cards (heat decays by date) as its own revision.

  Client ops (`run/2`) are fixed-shape: a kind and a target id with string
  fields in a fixed order per kind. Their outcome is kept 24 hours under
  the client's op id, so a resend gets the first answer and never writes
  twice. A revision bump that is not the one this process expected (a
  write from another VM, such as a release task) repaints everything.
  """

  use GenServer
  import Ecto.Query
  require Logger

  alias Hireme.Accounts.Account
  alias Hireme.Corpus
  alias Hireme.Desk
  alias Hireme.Desk.Card
  alias Hireme.Desk.Overlay
  alias Hireme.Gym
  alias Hireme.Heat
  alias Hireme.Net
  alias Hireme.Ops.Entry
  alias Hireme.Pipeline
  alias Hireme.Repo

  @registry __MODULE__.Registry
  @supervisor __MODULE__.Supervisor
  @inside {__MODULE__, :inside}
  @holder {__MODULE__, :holder}
  @held {__MODULE__, :held}
  @ledger_ttl 24 * 3600
  @sweep_ms 3_600_000

  @kinds ~w(stage next note score overlay heat_override open_fire narrative gym_log gym_target net_log net_lane)a

  @typedoc "One client op, as the wire decodes it. `op_id` is the client's u64."
  @type op :: %{
          op_id: non_neg_integer(),
          kind: atom(),
          target: non_neg_integer(),
          fields: [binary()]
        }

  @type refusal :: atom() | {:argument, String.t()}

  @type delta :: %{
          cards: [Card.t()],
          deleted: [pos_integer()],
          focus: [pos_integer()],
          roots: [pos_integer()],
          scoreboard: boolean(),
          lanes: boolean(),
          batches: boolean(),
          narrative: boolean()
        }

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
  Subscribe the caller to the account's deltas and return a consistent
  snapshot: the revision, every card in board order, the batches, and
  the profiles. A delta whose rev is at or below the snapshot's is
  already in it.
  """
  @spec attach(pos_integer()) ::
          {:ok, non_neg_integer(),
           %{cards: [Card.t()], batches: [Hireme.Desk.Batch.t()], profiles: [Corpus.Profile.t()]}}
  def attach(account_id) when is_integer(account_id) do
    :ok = Phoenix.PubSub.subscribe(Hireme.PubSub, Desk.topic(account_id))
    call(account_id, :attach)
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
  Start the account's sequencer and build its card table now, without
  waiting, so the session that follows a page load attaches warm.
  """
  @spec prewarm(pos_integer()) :: :ok
  def prewarm(account_id) when is_integer(account_id) do
    GenServer.cast(server(account_id), :prewarm)
  end

  @doc """
  The account's prepared heat snapshot as of its latest revision, for
  judging many applications at once (`Hireme.Desk.focuses/2`).
  """
  @spec heat(pos_integer()) :: map()
  def heat(account_id) when is_integer(account_id), do: call(account_id, :heat)

  @doc "Repaint these cards (a lease taken or released) and send what changed."
  @spec touch(pos_integer(), [pos_integer()]) :: :ok
  def touch(account_id, job_ids) when is_integer(account_id) and is_list(job_ids) do
    # With no sequencer running there is no table to repaint; the next
    # one paints from the database.
    case Registry.lookup(@registry, account_id) do
      [{pid, _}] -> GenServer.cast(pid, {:touch, job_ids})
      [] -> :ok
    end
  end

  @doc "Stop the account's sequencer, if one runs. Its table is rebuilt on next use."
  @spec stop(pos_integer()) :: :ok
  def stop(account_id) do
    case Registry.lookup(@registry, account_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(@supervisor, pid)
      [] -> :ok
    end

    :ok
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

  @doc "The op kinds `run/2` accepts, in wire order (kind 1 is the head)."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

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
    schedule_tick()

    {:ok, %{account: account_id, rev: nil, day: nil, heat: nil, cards: nil}}
  end

  @impl true
  def handle_call(:attach, _from, state) do
    guard(state, fn ->
      state = warm(state)
      cards = state.cards |> Map.values() |> Enum.sort_by(&Card.order/1)

      snapshot = %{
        cards: cards,
        batches: Desk.list_batches(),
        profiles: Corpus.list_profiles()
      }

      {{:ok, state.rev, snapshot}, state}
    end)
  end

  def handle_call(:heat, _from, state) do
    guard(state, fn ->
      state = warm(state)
      {state.heat, state}
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
    guard(state, fn ->
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
    {:noreply, state |> warm() |> settle(ids)}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule_tick()
    {:noreply, if(state.cards, do: warm(state), else: state)}
  end

  def handle_info(:sweep, state) do
    cutoff = DateTime.add(DateTime.utc_now(), -@ledger_ttl)
    Repo.delete_all(from e in Entry, where: e.inserted_at < ^cutoff)
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  def handle_info({:owner_down, _ref, :process, _pid, _reason}, state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  # A raise inside a write is the caller's, re-raised there; the write
  # rolled back. A raise after commit leaves the table suspect, so the
  # next write repaints everything.
  defp guard(state, fun) do
    {reply, state} = fun.()
    {:reply, reply, state}
  rescue
    exception ->
      {:reply, {:raise, exception, __STACKTRACE__}, %{state | rev: nil, cards: state.cards}}
  end

  # -- one write --------------------------------------------------------------

  defp commit(state, command, holder, ledger) do
    Process.put(@holder, holder)
    Process.put(@held, [])

    result =
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

    held = Process.get(@held, []) |> Enum.reverse()
    Process.delete(@holder)
    Process.delete(@held)

    case result do
      {:ok, {value, rev}} ->
        state = publish(state, rev, reach(command, value), held)
        {{:ok, value, rev}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  # A write from another VM moved the counter: this table is behind it.
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

  defp publish(state, rev, reach, held) do
    {state, rows, lanes?} =
      if Process.delete({__MODULE__, :gap}),
        do: repaint_all(state),
        else: repaint(state, reach.rows)

    delta = %{
      cards: rows,
      deleted: [],
      focus: if(reach.rows == :all, do: Enum.map(rows, & &1.id), else: reach.focus),
      roots: reach.roots,
      scoreboard: reach.scoreboard,
      lanes: reach.lanes or lanes?,
      batches: reach.batches,
      narrative: reach.narrative
    }

    broadcast(state, {:ops_delta, rev, delta})
    Enum.each(held, &broadcast(state, &1))
    %{state | rev: rev}
  end

  defp broadcast(state, message),
    do: Phoenix.PubSub.broadcast(Hireme.PubSub, Desk.topic(state.account), message)

  # Lease changes and the like: repaint, and spend a revision only on a change.
  defp settle(state, ids) do
    {next, rows, lanes?} = repaint(state, ids)

    if rows == [] do
      next
    else
      rev = Repo.transaction(fn -> bump!(state) end) |> elem(1)

      {next, rows, lanes?} =
        if Process.delete({__MODULE__, :gap}), do: repaint_all(state), else: {next, rows, lanes?}

      broadcast(
        next,
        {:ops_delta, rev, %{empty_delta() | cards: rows, lanes: lanes?}}
      )

      %{next | rev: rev}
    end
  end

  defp empty_delta do
    %{
      cards: [],
      deleted: [],
      focus: [],
      roots: [],
      scoreboard: false,
      lanes: false,
      batches: false,
      narrative: false
    }
  end

  # -- the card table ---------------------------------------------------------

  # The table is built on first use and kept warm. A new UTC day, or a
  # revision this process did not make, repaints every card and sends
  # the difference as its own revision. A write skips the read of the
  # revision (`look?` false): its own bump finds any gap.
  defp warm(state, look? \\ true)

  defp warm(%{cards: nil} = state, _look?) do
    today = Date.utc_today()
    heat = fresh_heat(today)
    cards = Desk.cards(:all, heat, today) |> Map.new(&{&1.id, &1})
    %{state | rev: db_rev(state), day: today, heat: heat, cards: cards}
  end

  defp warm(state, look?) do
    cond do
      state.day != Date.utc_today() or state.rev == nil or (look? and state.rev != db_rev(state)) ->
        {next, rows, _lanes?} = repaint_all(state)
        rev = Repo.transaction(fn -> bump!(%{state | rev: db_rev(state)}) end) |> elem(1)
        Process.delete({__MODULE__, :gap})

        broadcast(
          next,
          {:ops_delta, rev, %{empty_delta() | cards: rows, lanes: true, scoreboard: true}}
        )

        %{next | rev: rev}

      true ->
        state
    end
  end

  defp db_rev(state) do
    Repo.one!(from(a in Account, where: a.id == ^state.account, select: a.desk_rev),
      skip_account: true
    )
  end

  defp repaint_all(state) do
    today = Date.utc_today()
    heat = fresh_heat(today)
    fresh = Desk.cards(:all, heat, today) |> Map.new(&{&1.id, &1})
    rows = for {id, card} <- fresh, Map.get(state.cards, id) != card, do: card
    {%{state | day: today, heat: heat, cards: fresh}, rows, true}
  end

  # Repaint `ids` against the snapshot; if any of them moved in the heat
  # snapshot, rebuild it and repaint their company and ATS kin too.
  defp repaint(state, :all), do: repaint_all(state)
  defp repaint(state, []), do: {state, [], false}

  defp repaint(state, ids) do
    first = Desk.cards(ids, state.heat, state.day)
    moved = Enum.filter(first, &(heat_key(&1) != heat_key(Map.get(state.cards, &1.id))))

    {state, painted, lanes?} =
      if moved == [] do
        {state, first, false}
      else
        # The table with the fresh rows is the database as committed, so
        # the snapshot and the kin's rows come from memory.
        table = Enum.reduce(first, state.cards, &Map.put(&2, &1.id, &1))
        cfg = Heat.config()

        heat =
          table
          |> Map.values()
          |> Heat.snapshot_of(state.day, cfg)
          |> Heat.prepare(cfg, state.day, state.heat)

        old = Enum.map(moved, &Map.get(state.cards, &1.id)) |> Enum.reject(&is_nil/1)
        peers = Map.values(state.cards)

        kin =
          (moved ++ old)
          |> Enum.flat_map(&Heat.kin(peers, &1))
          |> Enum.concat(ids)
          |> Enum.uniq()
          |> Enum.map(&Map.fetch!(table, &1))

        {%{state | heat: heat}, Heat.decorate_all(kin, heat, cfg, state.day), true}
      end

    rows = Enum.filter(painted, &(Map.get(state.cards, &1.id) != &1))
    cards = Enum.reduce(rows, state.cards, &Map.put(&2, &1.id, &1))
    {%{state | cards: cards}, rows, lanes?}
  end

  # What a card contributes to the heat snapshot as a peer; nil when it
  # is not in it.
  defp heat_key(nil), do: nil

  defp heat_key(%Card{} = card) do
    if Heat.hot_stage?(card.stage),
      do:
        {card.company, card.role, card.listing_url, card.canonical_url, card.department,
         card.squad, card.fit, card.stage_on},
      else: nil
  end

  defp fresh_heat(today) do
    cfg = Heat.config()
    today |> Heat.snapshot(cfg) |> Heat.prepare(cfg, today)
  end

  defp schedule_tick do
    now = DateTime.utc_now()
    midnight = DateTime.new!(Date.add(DateTime.to_date(now), 1), ~T[00:00:01], "Etc/UTC")
    Process.send_after(self(), :tick, DateTime.diff(midnight, now, :millisecond))
  end

  # -- what a write reaches ---------------------------------------------------

  defp reach(command, value) do
    base = %{
      rows: [],
      focus: [],
      roots: [],
      scoreboard: false,
      lanes: false,
      batches: false,
      narrative: false
    }

    case command do
      {:create, _} ->
        ids = Desk.lineage_jobs(value.id)
        %{base | rows: ids, focus: ids, scoreboard: true, batches: true}

      {kind, id, _} when kind in [:stage, :score] ->
        %{base | rows: [id], focus: [id], scoreboard: true}

      {:heat_override, id, _} ->
        %{base | rows: [id], focus: [id]}

      {kind, id, _, _} when kind in [:next, :note] ->
        %{base | rows: [id], focus: [id]}

      {:overlay, id, _, _} ->
        ids = Desk.lineage_jobs(id)
        %{base | rows: ids, focus: ids}

      {:glance, id} ->
        %{base | rows: [id], focus: [id]}

      {:open_fire, code} ->
        ids = Desk.batch_jobs(code)
        %{base | rows: ids, focus: ids, scoreboard: true, batches: true}

      {:govern, _} ->
        %{base | rows: :all, scoreboard: true, batches: true, lanes: true}

      {:perform, pair, command} ->
        job_id = Hireme.CvPair.job_id(pair)

        case command do
          {:set_stage, stage} -> reach({:stage, job_id, stage}, value)
          {:set_score, score} -> reach({:score, job_id, score}, value)
          {:set_next, action} -> reach({:next, job_id, action, nil}, value)
          {:tailor, item_id, attrs} -> reach({:overlay, job_id, item_id, attrs}, value)
          :open_generation -> %{base | focus: Desk.lineage_jobs(job_id)}
          _ -> base
        end

      {:narrative, _, _} ->
        %{base | narrative: true, roots: Enum.map(Corpus.list_profiles(), & &1.id)}

      {kind, _} when kind in [:gym_log, :gym_target, :net_log, :net_lane] ->
        %{base | lanes: true}
    end
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
