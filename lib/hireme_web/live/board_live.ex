defmodule HiremeWeb.BoardLive do
  use HiremeWeb, :live_view

  alias Hireme.Campaign
  alias Hireme.Corpus
  alias Hireme.Desk
  alias Hireme.Desk.Overlay
  alias Hireme.Desk.Placed
  alias Hireme.GridNav
  alias Hireme.Gym
  alias Hireme.Narrative
  alias Hireme.Net
  alias Hireme.Pipeline
  alias Hireme.Desk.Filters

  import HiremeWeb.DeskComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Desk")
     |> assign(:filters, %Filters{})
     |> assign(:cards, [])
     |> assign(:profiles, [])
     |> assign(:batches, [])
     |> assign(:scoreboard, Campaign.scoreboard())
     |> assign(:ev_chart, Hireme.LifeEv.chart([]))
     |> assign(:gym, Gym.progress())
     |> assign(:net, Net.progress())
     |> assign(:gym_error, nil)
     |> assign(:net_error, nil)
     |> assign(:hold_error, nil)
     |> assign(:app_id, nil)
     |> assign(:index, nil)
     |> assign(:focus, nil)
     |> assign(:root, nil)
     |> assign(:lens, :board)
     |> assign(:sheet, false)
     |> assign(:compact, false)
     |> assign(:editing_id, nil)
     |> assign(:alter_error, nil)
     |> assign(:loaded, false)
     |> assign(:grid, %{cols: 3, scroll: 0, viewport: 640, rem: 16.0})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_params(socket, params)}
  end

  @impl true
  def render(assigns) do
    assigns = decorate(assigns)

    ~H"""
    <div id="desk" class="desk" phx-hook="Desk" phx-window-keydown="key">
      <.topbar
        filters={@filters}
        profiles={@profiles}
        batches={@batches}
        count={length(@cards)}
      />
      <.scoreboard board={@scoreboard} gym={@gym} net={@net} />
      <.ev_chart chart={@ev_chart} filters={@filters} />
      <div :if={@lens == :battleplan && @focus} class="battleplan-wrap">
        <.battleplan
          focus={@focus}
          editing_id={@editing_id}
          alter_error={@alter_error}
          hold_error={@hold_error}
        />
      </div>
      <div :if={@lens == :root && @root} class="root-wrap">
        <.root_view root={@root} />
      </div>
      <div :if={@lens == :gym} class="lane-wrap">
        <.gym_view gym={@gym} error={@gym_error} />
      </div>
      <div :if={@lens == :net} class="lane-wrap">
        <.net_view net={@net} error={@net_error} />
      </div>
      <div :if={@lens == :board} class="workspace">
        <div id="grid" class="grid-scroll" phx-hook="Grid" data-scroll={@grid.scroll}>
          <div class="grid-plane" style={"height: #{@plane_h}px"}>
            <.card
              :for={placed <- @window}
              card={placed.card}
              x={placed.x}
              y={placed.y}
              active={placed.card.id == @app_id}
            />
          </div>
          <p :if={@cards == []} class="empty">Nothing matches this filter.</p>
        </div>
        <.focus_panel
          :if={@focus}
          focus={@focus}
          in_filter={@in_filter}
          sheet={@sheet}
          hold_error={@hold_error}
        />
        <div :if={!@focus} id="focus" class="focus">
          <p class="empty">The desk is empty.</p>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("key", %{"key" => "Escape"} = params, socket) do
    if params["typing"] in [true, "true"] and params["field"] not in ["q", nil, ""] do
      {:noreply, socket}
    else
      escape(socket)
    end
  end

  def handle_event("key", %{"key" => key} = params, socket) do
    cond do
      params["typing"] in [true, "true"] ->
        {:noreply, socket}

      params["meta"] in [true, "true"] ->
        {:noreply, socket}

      key == "Escape" ->
        escape(socket)

      key == "/" and socket.assigns.lens == :board ->
        {:noreply, push_event(socket, "focus_search", %{})}

      key in ["Enter", "f"] and socket.assigns.lens == :board ->
        open_battleplan(socket)

      socket.assigns.lens == :board and GridNav.dir_from_key(key) != nil ->
        move(socket, GridNav.dir_from_key(key))

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("key", _params, socket), do: {:noreply, socket}

  def handle_event("select", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:sheet, true)
     |> push_patch(to: desk_path(socket, %{app: parse_id(id), lens: :board}))}
  end

  def handle_event("battleplan", _params, socket), do: open_battleplan(socket)
  def handle_event("back", _params, socket), do: escape(socket)

  def handle_event("root", _params, socket) do
    {:noreply, push_patch(socket, to: desk_path(socket, %{lens: :root}))}
  end

  def handle_event("gym", _params, socket) do
    {:noreply, push_patch(socket, to: desk_path(socket, %{lens: :gym}))}
  end

  def handle_event("net", _params, socket) do
    {:noreply, push_patch(socket, to: desk_path(socket, %{lens: :net}))}
  end

  def handle_event("gym_log", params, socket) do
    case Gym.log(params) do
      {:ok, _rep} ->
        {:noreply, socket |> assign(:gym_error, nil) |> refresh_lanes()}

      {:error, {:argument, name}} ->
        {:noreply, assign(socket, :gym_error, "Need a #{name}.")}

      {:error, _} ->
        {:noreply, assign(socket, :gym_error, "Could not log that rep.")}
    end
  end

  def handle_event("gym_target", %{"target" => target}, socket) do
    case Gym.set_target(target) do
      {:ok, _} -> {:noreply, socket |> assign(:gym_error, nil) |> refresh_lanes()}
      {:error, _} -> {:noreply, assign(socket, :gym_error, "Daily target is 1–30.")}
    end
  end

  def handle_event("net_log", params, socket) do
    case Net.log(params) do
      {:ok, _entry} ->
        {:noreply, socket |> assign(:net_error, nil) |> refresh_lanes()}

      {:error, {:argument, name}} ->
        {:noreply, assign(socket, :net_error, "Need a #{name}.")}

      {:error, _} ->
        {:noreply, assign(socket, :net_error, "Could not log that entry.")}
    end
  end

  def handle_event("net_lane", %{"url" => url}, socket) do
    case Net.set_lane(url) do
      {:ok, _} -> {:noreply, socket |> assign(:net_error, nil) |> refresh_lanes()}
      {:error, _} -> {:noreply, assign(socket, :net_error, "Lane URL did not save.")}
    end
  end

  def handle_event("filter", params, socket) do
    filters = Filters.from_params(params)
    {:noreply, push_patch(socket, to: desk_path(socket, Map.from_struct(filters)))}
  end

  def handle_event("grid", params, socket) do
    previous = socket.assigns.grid

    grid = %{
      cols: max(round_px(parse_num(params["cols"], 3)), 1),
      scroll: round_px(parse_num(params["scroll_top"], 0)),
      viewport: max(round_px(parse_num(params["viewport"], 640)), 1),
      rem: max(parse_num(params["rem"], 16.0), 1.0)
    }

    socket =
      cond do
        grid == previous -> socket
        grid.cols != previous.cols -> socket |> assign(:grid, grid) |> reveal()
        true -> assign(socket, :grid, grid)
      end

    {:noreply, socket}
  end

  def handle_event("chrome", %{"compact" => compact}, socket) do
    {:noreply, assign(socket, :compact, compact in [true, "true"])}
  end

  def handle_event("set_stage", %{"key" => key}, socket) do
    with {:ok, stage} <- Pipeline.parse(key),
         {:ok, _} <- Desk.set_stage(socket.assigns.app_id, stage) do
      {:noreply, socket |> assign(:hold_error, nil) |> refresh_open()}
    else
      {:error, :fire_hold} ->
        {:noreply,
         assign(socket, :hold_error, "FIRE HOLD. Name open fire on this batch before a submit.")}

      {:error, :leased} ->
        {:noreply, assign(socket, :hold_error, "This application is leased to an agent.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("name_open_fire", %{"batch" => code}, socket) do
    case Desk.name_open_fire(code) do
      {:ok, _} ->
        {:noreply, socket |> assign(:hold_error, nil) |> refresh_open()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("set_mask", %{"item" => item_id, "mode" => mode}, socket) do
    item_id = parse_id(item_id)

    result =
      case mask_change(mode) do
        {:ok, change} -> Desk.put_overlay(socket.assigns.app_id, item_id, change)
        :error -> :ignore
      end

    case result do
      {:ok, _} -> {:noreply, refresh_open(socket) |> assign(:editing_id, nil)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("edit_line", %{"item" => id}, socket) do
    {:noreply, assign(socket, editing_id: parse_id(id), alter_error: nil)}
  end

  def handle_event("cancel_alter", _params, socket) do
    {:noreply, assign(socket, editing_id: nil, alter_error: nil)}
  end

  def handle_event("save_alter", %{"item_id" => item_id, "body" => body} = params, socket) do
    case String.trim(body) do
      "" ->
        {:noreply, assign(socket, :alter_error, "A variant line needs text.")}

      trimmed ->
        case Desk.put_overlay(socket.assigns.app_id, parse_id(item_id), %{
               mode: :altered,
               body: trimmed,
               reason: blank(params["reason"])
             }) do
          {:ok, _} ->
            {:noreply, socket |> assign(editing_id: nil, alter_error: nil) |> refresh_open()}

          _ ->
            {:noreply, assign(socket, :alter_error, "This CV is leased to an agent.")}
        end
    end
  end

  def handle_event("save_next", _params, %{assigns: %{app_id: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("save_next", params, socket) do
    due =
      case Date.from_iso8601(params["next_due"] || "") do
        {:ok, date} -> date
        _ -> nil
      end

    case Desk.set_next(socket.assigns.app_id, String.trim(params["next_action"] || ""), due) do
      {:ok, _} -> {:noreply, refresh_open(socket)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("save_narrative", %{"body" => body}, socket) do
    case narrative_of(socket) do
      nil ->
        {:noreply, socket}

      row ->
        Narrative.update!(row, body)
        {:noreply, refresh_open(socket)}
    end
  end

  def handle_event("save_note", %{"key" => key, "note" => note}, socket) do
    with {:ok, stage} <- Pipeline.parse(key),
         {:ok, _} <- Desk.set_note(socket.assigns.app_id, stage, note) do
      {:noreply, assign(socket, :focus, Desk.focus(socket.assigns.app_id))}
    else
      _ -> {:noreply, socket}
    end
  end

  defp mask_change("inherit"), do: {:ok, :inherit}

  defp mask_change(mode) do
    case Overlay.parse_mode(mode) do
      {:ok, :hidden} -> {:ok, %{mode: :hidden, reason: "Hidden from this CV"}}
      {:ok, :emphasized} -> {:ok, %{mode: :emphasized, reason: "Emphasized for this CV"}}
      _ -> :error
    end
  end

  defp apply_params(socket, params) do
    filters = Filters.from_params(params)

    socket =
      if socket.assigns.loaded and filters == socket.assigns.filters do
        socket
      else
        reload(socket, filters)
      end

    app_id = parse_id(params["app"]) || first_id(socket)

    socket
    |> assign_app(app_id)
    |> assign_lens(parse_lens(params["lens"]))
    |> assign_title()
    |> reveal()
  end

  defp reload(socket, filters) do
    cards = Desk.list_cards(filters)

    socket
    |> assign(:filters, filters)
    |> assign(:cards, cards)
    |> assign(:profiles, Corpus.list_profiles())
    |> assign(:batches, Desk.list_batches())
    |> assign(:scoreboard, Campaign.scoreboard())
    |> assign(:ev_chart, Hireme.LifeEv.chart(cards))
    |> assign(:gym, Gym.progress())
    |> assign(:net, Net.progress())
    |> assign(:loaded, true)
  end

  defp assign_app(socket, app_id) do
    same? = socket.assigns.app_id == app_id and not is_nil(socket.assigns.focus)
    focus = if same?, do: socket.assigns.focus, else: Desk.focus(app_id)
    resolved = if focus, do: app_id, else: nil

    socket
    |> assign(:app_id, resolved)
    |> assign(:index, index_of(socket.assigns.cards, resolved))
    |> assign(:focus, focus)
    |> clear_editor_if_moved(socket.assigns.app_id, resolved)
  end

  defp assign_lens(socket, :root) do
    case root_profile_id(socket) do
      nil -> assign(socket, lens: :root, root: nil)
      id -> assign(socket, lens: :root, root: Desk.root(id))
    end
  end

  defp assign_lens(socket, lens), do: assign(socket, :lens, lens)

  defp assign_title(socket) do
    title =
      case {socket.assigns.lens, socket.assigns.focus} do
        {:root, _} -> "Root CV"
        {:gym, _} -> "Gym"
        {:net, _} -> "Net"
        {_, %{job: job}} -> "#{job.company} · #{Desk.code(job.id)}"
        _ -> "Desk"
      end

    assign(socket, :page_title, title)
  end

  defp refresh_open(socket) do
    cards = Desk.list_cards(socket.assigns.filters)
    app_id = socket.assigns.app_id

    socket
    |> assign(:cards, cards)
    |> assign(:index, index_of(cards, app_id))
    |> assign(:focus, Desk.focus(app_id))
    |> assign(:batches, Desk.list_batches())
    |> assign(:scoreboard, Campaign.scoreboard())
    |> assign(:ev_chart, Hireme.LifeEv.chart(cards))
    |> refresh_lanes()
    |> maybe_reload_root()
  end

  defp refresh_lanes(socket) do
    socket
    |> assign(:gym, Gym.progress())
    |> assign(:net, Net.progress())
  end

  defp maybe_reload_root(%{assigns: %{lens: :root}} = socket) do
    case root_profile_id(socket) do
      nil -> assign(socket, :root, nil)
      id -> assign(socket, :root, Desk.root(id))
    end
  end

  defp maybe_reload_root(socket), do: socket

  defp escape(socket) do
    cond do
      socket.assigns.lens != :board ->
        {:noreply, push_patch(socket, to: desk_path(socket, %{lens: :board}))}

      socket.assigns.compact and socket.assigns.sheet ->
        {:noreply, assign(socket, :sheet, false)}

      socket.assigns.filters.q != "" ->
        {:noreply, push_patch(socket, to: desk_path(socket, %{q: ""}))}

      true ->
        {:noreply, socket}
    end
  end

  defp open_battleplan(socket) do
    if socket.assigns.app_id && socket.assigns.lens == :board do
      {:noreply, push_patch(socket, to: desk_path(socket, %{lens: :battleplan}))}
    else
      {:noreply, socket}
    end
  end

  defp reveal(socket) do
    case socket.assigns.index do
      index when is_integer(index) ->
        grid = socket.assigns.grid
        metrics = GridNav.metrics(grid.rem)

        scroll =
          round_px(GridNav.scroll_to(index, grid.cols, grid.scroll, grid.viewport, metrics))

        if scroll == grid.scroll do
          socket
        else
          socket
          |> assign(:grid, %{grid | scroll: scroll})
          |> push_event("scroll_to", %{top: scroll})
        end

      _ ->
        socket
    end
  end

  defp move(socket, dir) do
    cards = socket.assigns.cards
    count = length(cards)

    if count == 0 do
      {:noreply, socket}
    else
      index = socket.assigns.index || 0
      next = GridNav.move(index, socket.assigns.grid.cols, count, dir)
      card = Enum.at(cards, next)

      if card && card.id != socket.assigns.app_id do
        grid = socket.assigns.grid
        metrics = GridNav.metrics(grid.rem)
        scroll = round_px(GridNav.scroll_to(next, grid.cols, grid.scroll, grid.viewport, metrics))

        {:noreply,
         socket
         |> assign(:sheet, true)
         |> assign(:grid, %{grid | scroll: scroll})
         |> push_event("scroll_to", %{top: scroll})
         |> push_patch(to: desk_path(socket, %{app: card.id, lens: :board}))}
      else
        {:noreply, socket}
      end
    end
  end

  defp decorate(assigns) do
    grid = assigns.grid
    metrics = GridNav.metrics(grid.rem)
    count = length(assigns.cards)
    {start_idx, last_idx} = GridNav.slice(count, grid.cols, grid.scroll, grid.viewport, metrics)

    indices =
      cond do
        start_idx < 0 -> []
        true -> Enum.to_list(start_idx..last_idx)
      end

    indices =
      case assigns.index do
        i when is_integer(i) and i >= 0 and i < count ->
          if i in indices, do: indices, else: [i | indices]

        _ ->
          indices
      end

    window =
      Enum.map(indices, fn i ->
        {x, y} = GridNav.origin(i, grid.cols, metrics)
        %Placed{card: Enum.at(assigns.cards, i), x: round_px(x), y: round_px(y)}
      end)

    assign(assigns,
      window: window,
      plane_h: round_px(GridNav.content_height(count, grid.cols, metrics)),
      in_filter: is_integer(assigns.index)
    )
  end

  defp desk_path(socket, overrides) do
    filters = Filters.merge(socket.assigns.filters, overrides)
    lens = Map.get(overrides, :lens, socket.assigns.lens)
    app = Map.get(overrides, :app, socket.assigns.app_id)

    query =
      filters
      |> Filters.to_query()
      |> put_query("lens", lens_param(lens))
      |> put_query("app", app)

    ~p"/?#{query}"
  end

  defp put_query(query, _key, nil), do: query
  defp put_query(query, key, value), do: Map.put(query, key, to_string(value))

  defp lens_param(:battleplan), do: "battleplan"
  defp lens_param(:root), do: "root"
  defp lens_param(:gym), do: "gym"
  defp lens_param(:net), do: "net"
  defp lens_param(_), do: nil

  defp parse_lens("battleplan"), do: :battleplan
  defp parse_lens("root"), do: :root
  defp parse_lens("gym"), do: :gym
  defp parse_lens("net"), do: :net
  defp parse_lens(_), do: :board

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_id(_), do: nil

  defp parse_num(n, _default) when is_integer(n), do: n * 1.0
  defp parse_num(n, _default) when is_float(n), do: n

  defp parse_num(n, default) when is_binary(n) do
    case Float.parse(n) do
      {value, _} -> value
      _ -> default * 1.0
    end
  end

  defp parse_num(_, default), do: default * 1.0

  defp round_px(n) when is_integer(n), do: n
  defp round_px(n) when is_float(n), do: round(n)

  defp first_id(socket) do
    case socket.assigns.cards do
      [%{id: id} | _] -> id
      _ -> nil
    end
  end

  defp index_of(_cards, nil), do: nil
  defp index_of(cards, id), do: Enum.find_index(cards, &(&1.id == id))

  defp root_profile_id(socket) do
    profiles = socket.assigns.profiles

    chosen =
      case socket.assigns.filters.profile do
        :all ->
          case socket.assigns.focus do
            %{profile: %{id: id}} -> id
            _ -> nil
          end

        slug ->
          Enum.find_value(profiles, fn profile ->
            if profile.slug == slug, do: profile.id
          end)
      end

    chosen ||
      case profiles do
        [%{id: id} | _] -> id
        _ -> nil
      end
  end

  defp clear_editor_if_moved(socket, previous, current) when previous == current, do: socket

  defp clear_editor_if_moved(socket, _previous, _current) do
    assign(socket, editing_id: nil, alter_error: nil)
  end

  defp narrative_of(socket) do
    cond do
      match?(%{narrative: %{}}, socket.assigns[:focus]) -> socket.assigns.focus.narrative
      match?(%{narrative: %{}}, socket.assigns[:root]) -> socket.assigns.root.narrative
      true -> nil
    end
  end

  defp blank(nil), do: nil

  defp blank(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
