defmodule HiremeWeb.DeskComponents do
  @moduledoc """
  Card, focus pane, and battleplan for the desk.
  """
  use HiremeWeb, :html

  alias Hireme.Desk.Job
  alias Hireme.Keywords.Coverage
  alias Hireme.Pipeline
  alias Hireme.Score
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
        <select name="band" aria-label="Score band">
          <option value="all" selected={@filters.band == :all}>All scores</option>
          <option :for={band <- Score.bands()} value={band} selected={@filters.band == band}>
            {band_label(band)}
          </option>
        </select>
        <input
          id="min"
          type="number"
          name="min"
          min="0"
          max="100"
          value={@filters.min}
          placeholder="min"
          aria-label="Minimum score"
          phx-debounce="300"
          class="min-score"
        />
        <span class="count">{@count} showing</span>
      </form>
      <button type="button" id="root-cv" class="ghost" phx-click="root">Root CV</button>
    </header>
    """
  end

  attr :board, Hireme.Campaign.Scoreboard, required: true

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
      <span :for={row <- @board.varieties} class="variety">
        {row.code} {row.label}
      </span>
      <.bands bands={@board.bands} />
    </div>
    """
  end

  attr :bands, :list, required: true

  @doc """
  One bar per score band, widths proportional to the largest band. Each
  bar is a link to that band's filter.
  """
  def bands(assigns) do
    assigns =
      assign(assigns, :peak, assigns.bands |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 1 end))

    ~H"""
    <span id="bands" class="bands" aria-label="Applications by score band">
      <.link
        :for={{band, n} <- @bands}
        patch={~p"/?band=#{band}"}
        class={["band", "band-#{band}"]}
        title={"#{band_label(band)} · #{n}"}
      >
        <i style={"height: #{bar_height(n, @peak)}%"}></i>
        <b>{n}</b>
      </.link>
    </span>
    """
  end

  defp bar_height(0, _peak), do: 4
  defp bar_height(n, peak), do: max(round(n / max(peak, 1) * 100), 8)

  defp band_label(:titan), do: "100"
  defp band_label(:high), do: "90–99"
  defp band_label(:strong), do: "85–89"
  defp band_label(:middle), do: "65–84"
  defp band_label(:low), do: "< 65"
  defp band_label(:unscored), do: "unscored"

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
        <span class="code">{@card.batch_code || Hireme.Desk.code(@card.id)}</span>
        <.score score={@card.score} />
        <span class="stage-name">{Pipeline.label(@card.stage)}{hold_mark(@card)}</span>
      </div>
      <h2>{@card.company}</h2>
      <p class="role">{@card.role}</p>
      <div class="meta">
        <span class="pips" aria-label={"Battleplan #{Pipeline.label(@card.stage)}"}>
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
        <span :if={@card.stage_on}>{age_label(@card.stage_on)}</span>
      </p>
    </button>
    """
  end

  attr :score, :any, required: true

  def score(assigns) do
    ~H"""
    <span
      :if={@score}
      class={["score", "band-#{Score.band(@score)}"]}
      aria-label={"Score #{@score} of 100"}
    >
      {@score}
    </span>
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
          <.score score={@focus.job.score} />
          <span>{@focus.variant.label}</span>
          <span>{@focus.profile.name}</span>
        </p>
        <h2>{@focus.job.company}</h2>
        <p class="sub">{@focus.job.role}</p>
        <p class="sub">{@focus.job.location}</p>
        <p class="sub">{fire_line(@focus.job)}</p>
      </header>
      <p :if={!@in_filter} class="banner">This application is outside the current filter.</p>
      <p :if={@hold_error} id="hold-error" class="banner hold-error">{@hold_error}</p>
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
            {Hireme.Desk.code(@focus.job.id)} · <.score score={@focus.job.score} />
            {@focus.variant.label} · {@focus.profile.name}
          </p>
          <h2>{@focus.job.company}</h2>
          <p class="sub">{@focus.job.role}</p>
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

  defp snapshot_date(nil), do: ""
  defp snapshot_date(%Date{} = date), do: " · #{Date.to_iso8601(date)}"

  defp hold_mark(%{batch_fire: :hold}), do: " · HOLD"
  defp hold_mark(_), do: ""

  defp fire_line(%{batch: %{code: code, fire: :hold}}), do: "#{code} · FIRE HOLD"
  defp fire_line(%{batch: %{code: code, fire: :open_fire}}), do: "#{code} · OPEN FIRE"

  defp fire_line(job) do
    gate = job.gate || :unset
    freshness = job.freshness || :unknown
    "#{gate} · #{freshness}"
  end

  defp next_line(%{next_action: action, next_due: due}) do
    action = if action in [nil, ""], do: "No next action", else: action

    case due_label(due) do
      nil -> action
      label -> "#{action} · #{label}"
    end
  end

  defp age_label(%Date{} = date) do
    case Date.diff(Date.utc_today(), date) do
      0 -> "today"
      n -> "#{n}d"
    end
  end

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
