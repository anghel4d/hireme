defmodule HiremeWeb.DeskComponents do
  @moduledoc """
  Card, focus pane, and battleplan for the desk.
  """
  use HiremeWeb, :html

  alias Hireme.Pipeline

  attr :filters, :map, required: true
  attr :profiles, :list, required: true
  attr :count, :integer, required: true
  attr :showcase_id, :integer, default: nil

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
          <.link :if={@showcase_id} patch={~p"/?app=#{@showcase_id}"} class="showcase">
            JobApp{@showcase_id}
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
          <option value="all" selected={@filters.stage == "all"}>All stages</option>
          <option
            :for={stage <- Pipeline.stages()}
            value={stage.key}
            selected={@filters.stage == stage.key}
          >
            {stage.label}
          </option>
        </select>
        <select name="profile" aria-label="Profile">
          <option value="all" selected={@filters.profile == "all"}>All profiles</option>
          <option
            :for={profile <- @profiles}
            value={profile.slug}
            selected={@filters.profile == profile.slug}
          >
            {profile.name}
          </option>
        </select>
        <select name="status" aria-label="Status">
          <option
            :for={status <- ~w(open paused hired closed all)}
            value={status}
            selected={@filters.status == status}
          >
            {status}
          </option>
        </select>
        <span class="count">{@count} showing</span>
      </form>
      <button type="button" id="root-cv" class="ghost" phx-click="root">Root CV</button>
    </header>
    """
  end

  attr :card, :map, required: true
  attr :active, :boolean, required: true

  def card(assigns) do
    ~H"""
    <button
      type="button"
      id={"card-#{@card.id}"}
      class={["card", @active && "is-active"]}
      style={"left: #{@card.x}px; top: #{@card.y}px"}
      phx-click="select"
      phx-value-id={@card.id}
      aria-current={@active && "true"}
      title={"#{@card.company} — #{@card.role}"}
    >
      <div class="card-kicker">
        <span class="code">{@card.code}</span>
        <span class="stage-name">{@card.stage_label}</span>
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

  attr :focus, :map, required: true
  attr :in_filter, :boolean, required: true
  attr :sheet, :boolean, required: true

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
      </header>
      <p :if={!@in_filter} class="banner">This application is outside the current filter.</p>
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
          Keywords {@focus.coverage.hit}/{@focus.coverage.total} · root {@focus.root_coverage.hit}/{@focus.root_coverage.total}
        </p>
        <div class="meter" aria-hidden="true">
          <span style={"width: #{pct(@focus.coverage)}%"}></span>
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
    </aside>
    """
  end

  attr :focus, :map, required: true
  attr :editing_id, :any, default: nil
  attr :alter_error, :any, default: nil

  def battleplan(assigns) do
    assigns = assign(assigns, :active, active_stage(assigns.focus.stages))

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
        </div>
        <p class="count">
          {@focus.coverage.hit}/{@focus.coverage.total} keywords · root {@focus.root_coverage.hit}/{@focus.root_coverage.total}
        </p>
      </div>
      <div class="bp-body">
        <div class="campaign">
          <button
            :for={stage <- @focus.stages}
            type="button"
            id={"stage-#{stage.key}"}
            class={["stage", stage.state == :active && "is-active"]}
            phx-click="set_stage"
            phx-value-key={stage.key}
          >
            <span class="meta">
              <span class={"pip pip-#{Pipeline.char(stage)}"}></span>
              <span class="label">{Pipeline.label(stage.key)}</span>
            </span>
            <span class="hint">{Pipeline.hint(stage.key)}</span>
            <span :if={stage.note != ""} class="note-preview">{stage.note}</span>
          </button>
          <form :if={@active} id="note-form" class="note" phx-change="save_note">
            <label for="stage-note">Note · {Pipeline.label(@active.key)}</label>
            <input type="hidden" name="key" value={@active.key} />
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

  attr :root, :map, required: true

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
        <.paper cv={@root.cv} editable={false} editing_id={nil} alter_error={nil} />
      </div>
    </div>
    """
  end

  attr :cv, :map, required: true
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

  attr :line, :map, required: true
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

  defp pct(%{total: 0}), do: 0
  defp pct(%{hit: hit, total: total}), do: round(hit / total * 100)

  defp excerpt(nil), do: ""

  defp excerpt(text) do
    text = String.trim(text)
    if String.length(text) > 360, do: String.slice(text, 0, 360) <> "…", else: text
  end

  defp active_stage(stages), do: Enum.find(stages, &(&1.state == :active))
end
