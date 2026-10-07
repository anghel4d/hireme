defmodule HiremeWeb.DeskComponents do
  @moduledoc """
  Card, focus pane, and battleplan for the desk.
  """
  use HiremeWeb, :html

  alias Hireme.Desk.Job
  alias Hireme.Gym
  alias Hireme.Heat
  alias Hireme.Keywords.Coverage
  alias Hireme.LifeEv
  alias Hireme.Net
  alias Hireme.Pipeline
  alias Hireme.Desk.Filters

  attr :filters, Filters, required: true
  attr :profiles, :list, required: true
  attr :batches, :list, required: true
  attr :count, :integer, required: true

  def topbar(assigns) do
    ~H"""
    <header class="topbar">
      <div class="brand">
        <h1>HIREME</h1>
        <p class="lede">
          <kbd>hjkl</kbd>
          cards · <kbd>enter</kbd>
          battleplan · <kbd>esc</kbd>
          back · <kbd>/</kbd>
          search
          <.link :if={batch?(@batches, "Batch-001")} patch={~p"/?batch=Batch-001"} class="showcase">
            Batch-001
          </.link>
        </p>
      </div>
      <form id="filters" class="filters" phx-change="filter" phx-submit="filter">
        <input
          id="q"
          type="search"
          name="q"
          value={@filters.q}
          placeholder="Company, role, JobApp, CV"
          phx-debounce="150"
          autocomplete="off"
          aria-label="Search the desk"
        />
        <select name="stage" aria-label="Stage">
          <option value="all" selected={@filters.stage == :all}>All stages</option>
          <option
            :for={stage <- Pipeline.stages()}
            value={Pipeline.name(stage.key)}
            selected={@filters.stage == stage.key}
          >
            {stage.label}
          </option>
        </select>
        <select name="profile" aria-label="Profile">
          <option value="all" selected={@filters.profile == :all}>All profiles</option>
          <option
            :for={profile <- @profiles}
            value={profile.slug}
            selected={@filters.profile == profile.slug}
          >
            {profile.name}
          </option>
        </select>
        <select name="batch" aria-label="Batch">
          <option value="all" selected={@filters.batch == :all}>All batches</option>
          <option value="leftover" selected={@filters.batch == :leftover}>Leftover</option>
          <option :for={batch <- @batches} value={batch.code} selected={@filters.batch == batch.code}>
            {batch.code}
          </option>
        </select>
        <select name="status" aria-label="Status">
          <option
            :for={status <- Job.statuses() ++ [:all]}
            value={status}
            selected={@filters.status == status}
          >
            {status}
          </option>
        </select>
        <select name="band" aria-label="Life-EV band">
          <option value="all" selected={@filters.band == :all}>All bands</option>
          <option
            :for={band <- LifeEv.bands()}
            value={LifeEv.name(band.key)}
            selected={@filters.band == band.key}
          >
            {band.label} · {band.min}–{band.max}
          </option>
        </select>
        <label class="min-score">
          min
          <input
            type="number"
            name="min_score"
            min="0"
            max="100"
            value={@filters.min_score}
            aria-label="Minimum score_100"
          />
        </label>
        <select name="heat" aria-label="Heat">
          <option value="all" selected={@filters.heat == :all}>All heat</option>
          <option
            :for={state <- [:cool, :warm, :hot, :blocked]}
            value={Heat.state_name(state)}
            selected={@filters.heat == state}
          >
            {Heat.state_name(state)}
          </option>
        </select>
        <span class="count">{@count} showing</span>
      </form>
      <button type="button" id="open-gym" class="ghost" phx-click="gym">Gym</button>
      <button type="button" id="open-net" class="ghost" phx-click="net">Net</button>
      <button type="button" id="root-cv" class="ghost" phx-click="root">Root CV</button>
    </header>
    """
  end

  attr :board, Hireme.Campaign.Scoreboard, required: true
  attr :gym, Gym.Progress, required: true
  attr :net, Net.Progress, required: true

  def scoreboard(assigns) do
    ~H"""
    <div id="scoreboard" class="scoreboard">
      <span class={["pill", @board.fire == :hold && "is-hold", @board.fire == :open_fire && "is-open"]}>
        {if @board.fire == :hold, do: "FIRE HOLD", else: "OPEN FIRE"}
      </span>
      <span>leftover {@board.leftover_unique}{snapshot_date(@board.leftover_noted_on)}</span>
      <span>batches {@board.batches_today}/{@board.batches_target}</span>
      <span>queued {@board.apps_today}/{@board.apps_target}</span>
      <span>submitted today {@board.submitted_today}</span>
      <span>cumulative {@board.cumulative}</span>
      <span>pace {@board.submitted_today}/{@board.apps_target}</span>
      <button type="button" id="score-gym" class="lane-pill" phx-click="gym">
        gym {@gym.solved_today}/{@gym.target} · {@gym.streak}d · pace {@gym.score}
      </button>
      <button type="button" id="score-net" class="lane-pill" phx-click="net">
        net {@net.shipped_week} shipped · {@net.drafts} drafts · obs {@net.observer_runs}
      </button>
      <span :for={row <- @board.varieties} class="variety">
        {row.code} {row.label}
      </span>
    </div>
    """
  end

  attr :chart, Hireme.LifeEv.Chart, required: true
  attr :filters, Filters, required: true

  def ev_chart(assigns) do
    peak = assigns.chart.bins |> Enum.map(& &1.count) |> Enum.max(fn -> 1 end)
    assigns = assign(assigns, :peak, peak)

    ~H"""
    <div id="ev-chart" class="ev-chart">
      <div class="ev-meta">
        <span class="pill">score_100</span>
        <span>n {@chart.n}</span>
        <span :if={@chart.mean}>mean {@chart.mean}</span>
        <span :if={@chart.max}>max {@chart.max}</span>
        <span :if={@chart.min}>min {@chart.min}</span>
      </div>
      <div class="ev-bands" aria-label="Life-EV band breakdown">
        <button
          :for={row <- @chart.bands}
          type="button"
          id={"band-#{row.key}"}
          class={["ev-band", @filters.band == row.key && "is-on"]}
          phx-click="filter"
          phx-value-q={@filters.q}
          phx-value-stage={Filters.stage_value(@filters)}
          phx-value-profile={Filters.profile_value(@filters)}
          phx-value-status={Filters.status_value(@filters)}
          phx-value-batch={Filters.batch_value(@filters)}
          phx-value-band={LifeEv.name(row.key)}
          phx-value-min_score={Filters.min_score_value(@filters)}
          phx-value-heat={Filters.heat_value(@filters)}
          title={"#{row.label} #{row.min}–#{row.max}"}
        >
          <span class="ev-band-label">{row.label}</span>
          <span class="ev-band-bar" style={"width: #{band_pct(row.share)}%"}></span>
          <span class="ev-band-n">{row.count}</span>
        </button>
      </div>
      <div class="ev-hist" aria-label="score_100 histogram">
        <div
          :for={bin <- @chart.bins}
          class="ev-bin"
          title={"#{bin.lo}–#{bin.hi}: #{bin.count}"}
        >
          <span class="ev-bin-bar" style={"height: #{bin_pct(bin.count, @peak)}%"}></span>
          <span class="ev-bin-lo">{bin.lo}</span>
        </div>
      </div>
    </div>
    """
  end

  attr :chart, Heat.Chart, required: true
  attr :filters, Filters, required: true

  def heat_chart(assigns) do
    ~H"""
    <div id="heat-chart" class="heat-chart">
      <div class="ev-meta">
        <span class="pill">HEAT</span>
        <span>{length(@chart.companies)} companies</span>
        <span>{length(@chart.vendors)} ATS</span>
      </div>
      <div class="heat-cols">
        <div class="ev-bands" aria-label="Company heat">
          <button
            :for={row <- Enum.take(@chart.companies, 8)}
            type="button"
            id={"heat-co-#{row.key}"}
            class={[
              "ev-band",
              @filters.q != "" and
                String.contains?(String.downcase(row.label), String.downcase(@filters.q)) && "is-on"
            ]}
            phx-click="filter"
            phx-value-q={row.label}
            phx-value-stage={Filters.stage_value(@filters)}
            phx-value-profile={Filters.profile_value(@filters)}
            phx-value-status={Filters.status_value(@filters)}
            phx-value-batch={Filters.batch_value(@filters)}
            phx-value-band={Filters.band_value(@filters)}
            phx-value-min_score={Filters.min_score_value(@filters)}
            phx-value-heat={Filters.heat_value(@filters)}
            title={"#{row.label} #{row.load}/#{row.cap} cooldown #{row.cooldown_days || 0}d"}
          >
            <span class="ev-band-label">{row.label}</span>
            <span class="ev-band-bar" style={"width: #{band_pct(row.ratio)}%"}></span>
            <span class="ev-band-n">{Float.round(row.load, 1)}/{Float.round(row.cap, 1)}</span>
          </button>
          <p :if={@chart.companies == []} class="sub">No queued company heat.</p>
        </div>
        <div class="ev-bands" aria-label="ATS heat">
          <button
            :for={row <- Enum.take(@chart.vendors, 8)}
            type="button"
            id={"heat-ats-#{row.key}"}
            class="ev-band"
            phx-click="filter"
            phx-value-q={row.label}
            phx-value-stage={Filters.stage_value(@filters)}
            phx-value-profile={Filters.profile_value(@filters)}
            phx-value-status={Filters.status_value(@filters)}
            phx-value-batch={Filters.batch_value(@filters)}
            phx-value-band={Filters.band_value(@filters)}
            phx-value-min_score={Filters.min_score_value(@filters)}
            phx-value-heat={Filters.heat_value(@filters)}
            title={"#{row.label} #{row.load}/#{row.cap}"}
          >
            <span class="ev-band-label">{row.label}</span>
            <span class="ev-band-bar" style={"width: #{band_pct(row.ratio)}%"}></span>
            <span class="ev-band-n">{Float.round(row.load, 1)}/{Float.round(row.cap, 1)}</span>
          </button>
          <p :if={@chart.vendors == []} class="sub">No ATS heat.</p>
        </div>
      </div>
    </div>
    """
  end

  attr :card, Hireme.Desk.Card, required: true
  attr :x, :integer, required: true
  attr :y, :integer, required: true
  attr :active, :boolean, required: true

  def card(assigns) do
    ~H"""
    <button
      type="button"
      id={"card-#{@card.id}"}
      class={["card", @active && "is-active"]}
      style={"left: #{@x}px; top: #{@y}px"}
      phx-click="select"
      phx-value-id={@card.id}
      aria-current={@active && "true"}
      title={"#{@card.company} — #{@card.role}"}
    >
      <div class="card-kicker">
        <span class="code">{card_code(@card)}</span>
        <span class="ev-score" title={"Life-EV #{LifeEv.label(@card.band)}"}>
          {@card.score_100}
        </span>
        <span
          class={[
            "heat-load",
            @card.heat_state == :blocked && "is-blocked",
            @card.heat_state == :hot && "is-hot"
          ]}
          title={"company heat #{@card.load}/#{@card.cap}"}
        >
          {Float.round(@card.load, 1)}/{Float.round(@card.cap, 1)}
        </span>
        <span class="stage-name">{@card.stage_label}{hold_mark(@card)}</span>
      </div>
      <h2>{@card.company}</h2>
      <p class="role">{@card.role}</p>
      <div class="meta">
        <span class="pips" aria-label={"Battleplan #{@card.stage_label}"}>
          <i :for={pip <- String.graphemes(@card.pips)} class={"pip pip-#{pip}"}></i>
        </span>
        <span class="heat" aria-label={"Heat #{@card.heat} of 5"}>
          <span :for={n <- 1..5} class={n <= @card.heat && "on"}></span>
        </span>
      </div>
      <p class="glance">
        <span>{@card.cv_label} · {@card.profile_name}</span>
        <span>{@card.keyword_hits}/{@card.keyword_total}</span>
      </p>
      <p class="next">
        <span>{next_line(@card)}</span>
        <span :if={age_label(@card.age)}>{age_label(@card.age)}</span>
      </p>
    </button>
    """
  end

  attr :focus, Hireme.Desk.Focus, required: true
  attr :in_filter, :boolean, required: true
  attr :sheet, :boolean, required: true
  attr :hold_error, :string, default: nil

  def focus_panel(assigns) do
    ~H"""
    <aside id="focus" class={["focus", @sheet && "is-sheet"]}>
      <header>
        <p class="kicker">
          <span>{Hireme.Desk.code(@focus.job.id)}</span>
          <span>{@focus.variant.label}</span>
          <span>{@focus.profile.name}</span>
        </p>
        <h2>{@focus.job.company}</h2>
        <p class="sub">{@focus.job.role}</p>
        <p class="sub">{@focus.job.location}</p>
        <p class="sub">
          score_100 {@focus.job.score_100} · {LifeEv.label(LifeEv.band(@focus.job.score_100))}
        </p>
        <p class="sub">{fire_line(@focus.job)}</p>
        <p class="sub" id="heat-line">{heat_line(@focus.job)}</p>
      </header>
      <p :if={!@in_filter} class="banner">This application is outside the current filter.</p>
      <p :if={@hold_error} id="hold-error" class="banner hold-error">{@hold_error}</p>
      <form
        :if={!@focus.job.heat_override}
        id="heat-override"
        class="field"
        phx-submit="heat_override"
      >
        <label for="heat-reason">HEAT override reason</label>
        <div class="row">
          <input
            id="heat-reason"
            type="text"
            name="reason"
            placeholder="Why this role may exceed cap"
          />
          <button type="submit" class="ghost">Override</button>
        </div>
      </form>
      <p :if={@focus.job.heat_override} class="sub">
        HEAT override · {@focus.job.heat_override_reason}
      </p>
      <div>
        <div class="meta">
          <span class="pips">
            <i :for={pip <- String.graphemes(@focus.job.pips)} class={"pip pip-#{pip}"}></i>
          </span>
          <span class="stage-name">{Pipeline.label(@focus.job.current_stage)}</span>
        </div>
        <p class="sub">{Pipeline.hint(@focus.job.current_stage)}</p>
      </div>
      <button type="button" id="open-battleplan" class="primary" phx-click="battleplan">
        Open battleplan
      </button>
      <form id="next-form" class="field" phx-change="save_next">
        <label for="next_action">Next</label>
        <div class="row">
          <input
            id="next_action"
            type="text"
            name="next_action"
            value={@focus.job.next_action}
            phx-debounce="400"
          />
          <input
            type="date"
            name="next_due"
            value={date_value(@focus.job.next_due)}
            aria-label="Due"
            class={[overdue?(@focus.job.next_due) && "is-due"]}
          />
        </div>
      </form>
      <div>
        <p class="section-label">
          Keywords {Coverage.hit(@focus.coverage)}/{Coverage.total(@focus.coverage)} · root {Coverage.hit(
            @focus.root_coverage
          )}/{Coverage.total(@focus.root_coverage)}
        </p>
        <div class="meter" aria-hidden="true">
          <span style={"width: #{Coverage.percent(@focus.coverage)}%"}></span>
        </div>
        <ul class="chips">
          <li :for={word <- @focus.coverage.hits} class="hit">{word}</li>
          <li :for={word <- @focus.coverage.misses} class="miss">{word}</li>
        </ul>
      </div>
      <div>
        <p class="section-label">
          Mask · {@focus.job.mask_hidden} hidden · {@focus.job.mask_altered} altered · {@focus.job.mask_emphasized} emphasized
        </p>
        <ul class="mask-list">
          <li :for={mask <- Enum.take(@focus.masks, 4)}>
            <span class={"mode mode-#{mask.mode}"}>{mask.mode}</span>
            {mask.title}
            <span :if={mask.reason} class="reason"> — {mask.reason}</span>
          </li>
        </ul>
      </div>
      <p :if={excerpt(@focus.job.listing) != ""} class="sub">{excerpt(@focus.job.listing)}</p>
      <ul :if={@focus.kv != []} class="kv">
        <li :for={pair <- @focus.kv}><strong>{pair.key}</strong> {pair.value}</li>
      </ul>
      <.narrative narrative={@focus.narrative} />
    </aside>
    """
  end

  attr :focus, Hireme.Desk.Focus, required: true
  attr :editing_id, :any, default: nil
  attr :alter_error, :any, default: nil
  attr :hold_error, :string, default: nil

  def battleplan(assigns) do
    assigns = assign(assigns, :active, Pipeline.current(assigns.focus.rail))

    ~H"""
    <div id="battleplan" class="battleplan">
      <div class="bp-bar">
        <button type="button" id="back-to-desk" class="ghost" phx-click="back">Back</button>
        <div class="grow">
          <p class="kicker">
            {Hireme.Desk.code(@focus.job.id)} · {@focus.variant.label} · {@focus.profile.name}
          </p>
          <h2>{@focus.job.company}</h2>
          <p class="sub">{@focus.job.role}</p>
          <p class="sub">
            score_100 {@focus.job.score_100} · {LifeEv.label(LifeEv.band(@focus.job.score_100))}
          </p>
          <p class="sub">{fire_line(@focus.job)}</p>
        </div>
        <p class="count">
          {Coverage.hit(@focus.coverage)}/{Coverage.total(@focus.coverage)} keywords · root {Coverage.hit(
            @focus.root_coverage
          )}/{Coverage.total(@focus.root_coverage)}
        </p>
      </div>
      <div class="bp-body">
        <div class="campaign">
          <.narrative narrative={@focus.narrative} />
          <p :if={@hold_error} id="hold-error" class="banner hold-error">{@hold_error}</p>
          <button
            :if={@focus.job.batch && @focus.job.batch.fire == :hold}
            type="button"
            id="name-open-fire"
            class="ghost"
            phx-click="name_open_fire"
            phx-value-batch={@focus.job.batch.code}
          >
            Name open fire
          </button>
          <button
            :for={rung <- @focus.rail}
            type="button"
            id={"stage-#{Pipeline.name(rung.key)}"}
            class={["stage", rung.state == :active && "is-active"]}
            phx-click="set_stage"
            phx-value-key={Pipeline.name(rung.key)}
          >
            <span class="meta">
              <span class={"pip pip-#{Pipeline.char(rung)}"}></span>
              <span class="label">{Pipeline.label(rung.key)}</span>
            </span>
            <span class="hint">{Pipeline.hint(rung.key)}</span>
            <span :if={rung.note != ""} class="note-preview">{rung.note}</span>
          </button>
          <form :if={@active} id="note-form" class="note" phx-change="save_note">
            <label for="stage-note">Note · {Pipeline.label(@active.key)}</label>
            <input type="hidden" name="key" value={Pipeline.name(@active.key)} />
            <textarea id="stage-note" name="note" phx-debounce="500">{@active.note}</textarea>
          </form>
          <ul class="events">
            <li :for={event <- @focus.events}>{event.body}</li>
          </ul>
        </div>
        <div class="paper-scroll">
          <.paper cv={@focus.cv} editable editing_id={@editing_id} alter_error={@alter_error} />
          <p :if={@focus.job.listing != ""} class="sub">{String.trim(@focus.job.listing)}</p>
        </div>
      </div>
    </div>
    """
  end

  attr :root, Hireme.Desk.Root, required: true

  def root_view(assigns) do
    ~H"""
    <div class="root-wrap">
      <div class="bp-bar">
        <button type="button" id="back-to-desk" class="ghost" phx-click="back">Back</button>
        <div class="grow">
          <p class="kicker">Root · {@root.profile.name}</p>
          <h2>{@root.cv.headline}</h2>
        </div>
      </div>
      <div class="paper-scroll">
        <.narrative narrative={@root.narrative} />
        <.paper cv={@root.cv} editable={false} editing_id={nil} alter_error={nil} />
      </div>
    </div>
    """
  end

  attr :gym, Gym.Progress, required: true
  attr :error, :any, default: nil

  def gym_view(assigns) do
    peak = assigns.gym.topics |> Enum.map(& &1.count) |> Enum.max(fn -> 1 end)
    assigns = assign(assigns, :peak, peak)

    ~H"""
    <div id="gym" class="lane-page">
      <div class="bp-bar">
        <button type="button" id="back-from-gym" class="ghost" phx-click="back">Back</button>
        <div class="grow">
          <p class="kicker">Gym · jumping jacks for the fight</p>
          <h2>Conditioning, not the job</h2>
          <p class="sub">
            LeetCode, Codeforces, systems drills. Daily {@gym.solved_today}/{@gym.target} · streak {@gym.streak}d · week {@gym.solved_week} · pace {@gym.score}
          </p>
        </div>
      </div>
      <p :if={@error} id="gym-error" class="banner hold-error">{@error}</p>
      <div class="lane-body">
        <div class="lane-forms">
          <form id="gym-target" class="lane-form" phx-submit="gym_target">
            <label class="section-label" for="gym-target-n">Daily solved target</label>
            <input id="gym-target-n" type="number" name="target" min="1" max="30" value={@gym.target} />
            <button type="submit" class="ghost">Set target</button>
          </form>
          <form id="gym-log" class="lane-form" phx-submit="gym_log">
            <label class="section-label">Log a rep</label>
            <select name="platform" aria-label="Platform">
              <option :for={platform <- Gym.platforms()} value={Gym.name(platform)}>
                {Gym.label(platform)}
              </option>
            </select>
            <input type="text" name="title" placeholder="Two Sum" required aria-label="Problem title" />
            <input type="text" name="slug" placeholder="two-sum" aria-label="Slug" />
            <select name="topic" aria-label="Topic">
              <option :for={topic <- Gym.topics()} value={Gym.name(topic)}>{Gym.label(topic)}</option>
            </select>
            <select name="difficulty" aria-label="Difficulty">
              <option :for={diff <- Gym.difficulties()} value={Gym.name(diff)}>
                {Gym.label(diff)}
              </option>
            </select>
            <select name="outcome" aria-label="Outcome">
              <option :for={outcome <- Gym.outcomes()} value={Gym.name(outcome)}>
                {Gym.label(outcome)}
              </option>
            </select>
            <input type="number" name="minutes" min="0" placeholder="min" aria-label="Minutes" />
            <input
              type="url"
              name="url"
              placeholder="https://leetcode.com/problems/…"
              aria-label="URL"
            />
            <input type="text" name="note" placeholder="Note" aria-label="Note" />
            <button type="submit" class="primary">Log rep</button>
          </form>
        </div>
        <div class="lane-side">
          <div class="ev-bands" aria-label="Topic counts">
            <div :for={row <- @gym.topics} class="ev-band">
              <span class="ev-band-label">{row.label}</span>
              <span class="ev-band-bar" style={"width: #{bin_pct(row.count, @peak)}%"}></span>
              <span class="ev-band-n">{row.count}</span>
            </div>
          </div>
          <ul id="gym-recent" class="lane-list">
            <li :if={@gym.recent == []} class="empty">No reps yet. Log the first jump.</li>
            <li :for={rep <- @gym.recent} id={"rep-#{rep.id}"}>
              <span class="lane-meta">
                {Date.to_iso8601(rep.done_on)} · {Gym.label(rep.problem.platform)} · {Gym.label(
                  rep.outcome
                )}
              </span>
              <strong>{rep.problem.title}</strong>
              <span class="sub">{Gym.label(rep.problem.topic)} · {Gym.label(rep.problem.difficulty)}</span>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  attr :net, Net.Progress, required: true
  attr :error, :any, default: nil

  def net_view(assigns) do
    ~H"""
    <div id="net" class="lane-page">
      <div class="bp-bar">
        <button type="button" id="back-from-net" class="ghost" phx-click="back">Back</button>
        <div class="grow">
          <p class="kicker">Net · not CRM</p>
          <h2>Broadside Observer + ship the work</h2>
          <p class="sub">
            Posts, artifacts, outreach drafts. No contacts, no sequences. Shipped {@net.shipped_week}/7d · drafts {@net.drafts} · observer {@net.observer_runs}
          </p>
        </div>
      </div>
      <p :if={@error} id="net-error" class="banner hold-error">{@error}</p>
      <div class="lane-body">
        <div class="lane-forms">
          <form id="net-lane" class="lane-form" phx-submit="net_lane">
            <label class="section-label" for="broadside-lane">Broadside research lane</label>
            <input
              id="broadside-lane"
              type="url"
              name="url"
              value={@net.lane}
              placeholder="Observer URL"
              aria-label="Broadside Observer URL"
            />
            <button type="submit" class="ghost">Set lane</button>
          </form>
          <p :if={@net.lane != ""} class="sub">
            <.link href={@net.lane} target="_blank" rel="noreferrer">Open Observer</.link>
          </p>
          <form id="net-log" class="lane-form" phx-submit="net_log">
            <label class="section-label">Log an entry</label>
            <select name="kind" aria-label="Kind">
              <option :for={kind <- Net.kinds()} value={Net.name(kind)}>{Net.label(kind)}</option>
            </select>
            <select name="channel" aria-label="Channel">
              <option :for={channel <- Net.channels()} value={Net.name(channel)}>
                {Net.label(channel)}
              </option>
            </select>
            <input type="text" name="title" placeholder="Title" required aria-label="Title" />
            <input type="url" name="url" placeholder="https://…" aria-label="URL" />
            <textarea name="body" rows="4" placeholder="Draft body or note" aria-label="Body"></textarea>
            <button type="submit" class="primary">Log entry</button>
          </form>
        </div>
        <ul id="net-recent" class="lane-list">
          <li :if={@net.recent == []} class="empty">
            Nothing shipped. Run Observer or draft a post.
          </li>
          <li :for={entry <- @net.recent} id={"net-#{entry.id}"}>
            <span class="lane-meta">
              {Net.label(entry.kind)} · {Net.label(entry.channel)}
              <span :if={entry.shipped_on}> · {Date.to_iso8601(entry.shipped_on)}</span>
            </span>
            <strong>{entry.title}</strong>
            <span :if={entry.url != ""} class="sub">{entry.url}</span>
            <span :if={entry.body != ""} class="sub">{excerpt(entry.body)}</span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :narrative, :any, default: nil

  def narrative(assigns) do
    ~H"""
    <section :if={@narrative} id="narrative" class="narrative">
      <form id="narrative-form" phx-submit="save_narrative">
        <label class="section-label" for="narrative-body">
          Narrative · private · v{@narrative.version}
        </label>
        <textarea id="narrative-body" name="body" rows="8">{@narrative.body}</textarea>
        <button type="submit" class="ghost">Save narrative</button>
      </form>
    </section>
    """
  end

  attr :cv, Hireme.Cv.Document, required: true
  attr :editable, :boolean, required: true
  attr :editing_id, :any, default: nil
  attr :alter_error, :any, default: nil

  def paper(assigns) do
    ~H"""
    <article
      id="cv"
      class="paper"
      data-accent={@cv.accent}
      data-density={@cv.density}
    >
      <header>
        <p class="kicker">{@cv.label}</p>
        <h2 :if={@cv.person}>{@cv.person}</h2>
        <p class="headline">{@cv.headline}</p>
        <p class="summary">{@cv.summary}</p>
        <p :if={@cv.summary_canonical} class="canonical">
          Root: {@cv.summary_canonical}
          <span :if={@cv.summary_reason}> — {@cv.summary_reason}</span>
        </p>
        <div class="facts">
          <span :for={fact <- @cv.facts}>{fact.title}: {fact.body}</span>
        </div>
      </header>
      <section :for={section <- @cv.sections}>
        <h3>{section.label}</h3>
        <.cv_line
          :for={line <- section.lines}
          line={line}
          editable={@editable}
          editing_id={@editing_id}
          alter_error={@alter_error}
        />
      </section>
      <section :if={@cv.hidden != []} class="masked">
        <h3>Masked out</h3>
        <.cv_line
          :for={line <- @cv.hidden}
          line={line}
          editable={@editable}
          editing_id={@editing_id}
          alter_error={@alter_error}
        />
      </section>
    </article>
    """
  end

  attr :line, Hireme.Mask.Line, required: true
  attr :editable, :boolean, required: true
  attr :editing_id, :any, default: nil
  attr :alter_error, :any, default: nil

  def cv_line(assigns) do
    ~H"""
    <div id={"line-#{@line.id}"} class={["line", "is-#{@line.mode}"]}>
      <h4>
        <span :if={@line.org != ""} class="org">{@line.org} · </span>
        {@line.title}
        <span :if={@line.span != ""} class="org"> · {@line.span}</span>
      </h4>
      <p :if={@editing_id != @line.id}>{@line.body}</p>
      <p :if={@line.mode == :altered and @line.canonical_body != @line.body} class="canonical">
        Root: {@line.canonical_body}
      </p>
      <p :if={@line.reason} class="reason">{@line.reason}</p>
      <div :if={@editable and @editing_id != @line.id} class="line-actions">
        <button
          :if={@line.shown}
          type="button"
          id={"mask-hide-#{@line.id}"}
          class="text-btn"
          phx-click="set_mask"
          phx-value-item={@line.id}
          phx-value-mode="hidden"
        >
          Hide
        </button>
        <button
          :if={@line.shown and @line.mode != :emphasized}
          type="button"
          id={"mask-emphasize-#{@line.id}"}
          class="text-btn"
          phx-click="set_mask"
          phx-value-item={@line.id}
          phx-value-mode="emphasized"
        >
          Emphasize
        </button>
        <button
          :if={@line.shown}
          type="button"
          id={"mask-alter-#{@line.id}"}
          class="text-btn"
          phx-click="edit_line"
          phx-value-item={@line.id}
        >
          Alter
        </button>
        <button
          :if={@line.mode != :canonical}
          type="button"
          id={"mask-restore-#{@line.id}"}
          class="text-btn"
          phx-click="set_mask"
          phx-value-item={@line.id}
          phx-value-mode="inherit"
        >
          Restore
        </button>
      </div>
      <form
        :if={@editable and @editing_id == @line.id}
        id={"alter-#{@line.id}"}
        class="alter"
        phx-submit="save_alter"
      >
        <input type="hidden" name="item_id" value={@line.id} />
        <textarea name="body" aria-label="Variant line">{@line.body}</textarea>
        <input
          type="text"
          name="reason"
          value={@line.reason || ""}
          placeholder="Why this line changed"
        />
        <p :if={@alter_error} class="alter-error">{@alter_error}</p>
        <button type="submit" class="primary">Save line</button>
        <button type="button" class="ghost" phx-click="cancel_alter">Cancel</button>
      </form>
    </div>
    """
  end

  defp batch?(batches, code), do: Enum.any?(batches, &(&1.code == code))

  defp band_pct(share) when is_float(share) or is_integer(share) do
    round(share * 100)
  end

  defp bin_pct(_count, 0), do: 0
  defp bin_pct(count, peak), do: round(count / peak * 100)

  defp snapshot_date(nil), do: ""
  defp snapshot_date(%Date{} = date), do: " · #{Date.to_iso8601(date)}"

  defp card_code(%{batch_code: code}) when is_binary(code) and code != "", do: code
  defp card_code(card), do: card.code

  defp hold_mark(%{batch_fire: :hold}), do: " · HOLD"
  defp hold_mark(_), do: ""

  defp fire_line(%{batch: %{code: code, fire: :hold}}), do: "#{code} · FIRE HOLD"
  defp fire_line(%{batch: %{code: code, fire: :open_fire}}), do: "#{code} · OPEN FIRE"

  defp fire_line(job) do
    gate = job.gate || :unset
    freshness = job.freshness || :unknown
    "#{gate} · #{freshness}"
  end

  defp heat_line(job) do
    verdict = Heat.can_apply(job)
    eta = if verdict.cooldown_days, do: " · cooldown #{verdict.cooldown_days}d", else: ""

    "heat #{verdict.decision} · #{Float.round(verdict.company_load, 1)}/#{Float.round(verdict.company_cap, 1)} #{verdict.size} · #{Hireme.Heat.Ats.name(verdict.ats_vendor)}#{eta}"
  end

  defp next_line(%{next_action: action, next_due: due}) do
    action = if action in [nil, ""], do: "No next action", else: action

    case due_label(due) do
      nil -> action
      label -> "#{action} · #{label}"
    end
  end

  defp age_label(nil), do: nil
  defp age_label(0), do: "today"
  defp age_label(1), do: "1d"
  defp age_label(n) when is_integer(n), do: "#{n}d"

  defp due_label(nil), do: nil

  defp due_label(%Date{} = date),
    do: Calendar.strftime(date, "%b ") <> Integer.to_string(date.day)

  defp date_value(nil), do: ""
  defp date_value(%Date{} = date), do: Date.to_iso8601(date)

  defp overdue?(nil), do: false
  defp overdue?(%Date{} = date), do: Date.compare(date, Date.utc_today()) == :lt

  defp excerpt(nil), do: ""

  defp excerpt(text) do
    text = String.trim(text)
    if String.length(text) > 360, do: String.slice(text, 0, 360) <> "…", else: text
  end
end
