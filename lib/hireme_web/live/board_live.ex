defmodule HiremeWeb.BoardLive do
  use HiremeWeb, :live_view

  alias Hireme.Corpus
  alias Hireme.Desk
  alias Hireme.GridNav
  alias Hireme.Pipeline

  import HiremeWeb.DeskComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Desk")
     |> assign(:filters, %{q: "", stage: "all", profile: "all", status: "open"})
     |> assign(:cards, [])
     |> assign(:profiles, [])
     |> assign(:app_id, nil)
     |> assign(:index, nil)
     |> assign(:focus, nil)
     |> assign(:root, nil)
     |> assign(:lens, :board)
     |> assign(:sheet, false)
     |> assign(:compact, false)
     |> assign(:editing_id, nil)
     |> assign(:alter_error, nil)
     |> assign(:showcase_id, nil)
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
        count={length(@cards)}
        showcase_id={@showcase_id}
      />
      <div :if={@lens == :battleplan && @focus} class="battleplan-wrap">
        <.battleplan focus={@focus} editing_id={@editing_id} alter_error={@alter_error} />
      </div>
      <div :if={@lens == :root && @root} class="root-wrap">
        <.root_view root={@root} />
      </div>
      <div :if={@lens == :board} class="workspace">
        <div id="grid" class="grid-scroll" phx-hook="Grid" data-scroll={@grid.scroll}>
          <div class="grid-plane" style={"height: #{@plane_h}px"}>
            <.card :for={card <- @window} card={card} active={card.id == @app_id} />
          </div>
          <p :if={@cards == []} class="empty">Nothing matches this filter.</p>
        </div>
        <.focus_panel :if={@focus} focus={@focus} in_filter={@in_filter} sheet={@sheet} />
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

      socket.assigns.lens == :board && is_binary(GridNav.dir_from_key(key)) ->
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

  def handle_event("filter", params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         desk_path(socket, %{
           q: params["q"] || "",
           stage: params["stage"] || "all",
           profile: params["profile"] || "all",
           status: params["status"] || "open"
         })
     )}
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
    case Desk.set_stage(socket.assigns.app_id, key) do
      {:ok, _} -> {:noreply, refresh_open(socket)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("set_mask", %{"item" => item_id, "mode" => mode}, socket) do
    item_id = parse_id(item_id)

    result =
      case mode do
        "inherit" ->
          Desk.put_overlay(socket.assigns.app_id, item_id, :inherit)

        "hidden" ->
          Desk.put_overlay(socket.assigns.app_id, item_id, %{
            mode: :hidden,
            reason: "Hidden from this CV"
          })

        "emphasized" ->
          Desk.put_overlay(socket.assigns.app_id, item_id, %{
            mode: :emphasized,
            reason: "Emphasized for this CV"
          })

        _ ->
          :ignore
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
        {:ok, _} =
          Desk.put_overlay(socket.assigns.app_id, parse_id(item_id), %{
            mode: :altered,
            body: trimmed,
            reason: blank(params["reason"])
          })

        {:noreply, socket |> assign(editing_id: nil, alter_error: nil) |> refresh_open()}
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

    {:ok, _} = Desk.set_next(socket.assigns.app_id, String.trim(params["next_action"] || ""), due)
    {:noreply, refresh_open(socket)}
  end

  def handle_event("save_note", %{"key" => key, "note" => note}, socket) do
    {:ok, _} = Desk.set_note(socket.assigns.app_id, key, note)
    {:noreply, assign(socket, :focus, Desk.focus(socket.assigns.app_id))}
  end

  defp apply_params(socket, params) do
    filters = parse_filters(params)

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

    showcase =
      cond do
        socket.assigns.showcase_id -> socket.assigns.showcase_id
        Desk.exists?(14_413) -> 14_413
        true -> nil
      end

    socket
    |> assign(:filters, filters)
    |> assign(:cards, cards)
    |> assign(:profiles, Corpus.list_profiles())
    |> assign(:showcase_id, showcase)
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
    |> maybe_reload_root()
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
        Map.merge(Enum.at(assigns.cards, i), %{x: round_px(x), y: round_px(y)})
      end)

    assign(assigns,
      window: window,
      plane_h: round_px(GridNav.content_height(count, grid.cols, metrics)),
      in_filter: is_integer(assigns.index)
    )
  end

  defp desk_path(socket, overrides) do
    filters =
      Map.merge(socket.assigns.filters, Map.take(overrides, [:q, :stage, :profile, :status]))

    lens = Map.get(overrides, :lens, socket.assigns.lens)
    app = Map.get(overrides, :app, socket.assigns.app_id)

    query =
      %{}
      |> put_query("q", filters.q, "")
      |> put_query("stage", filters.stage, "all")
      |> put_query("profile", filters.profile, "all")
      |> put_query("status", filters.status, "open")
      |> put_query("lens", lens_param(lens), nil)
      |> put_query("app", app, nil)

    ~p"/?#{query}"
  end

  defp put_query(query, _key, value, value), do: query
  defp put_query(query, _key, nil, _default), do: query
  defp put_query(query, key, value, _default), do: Map.put(query, key, to_string(value))

  defp lens_param(:battleplan), do: "battleplan"
  defp lens_param(:root), do: "root"
  defp lens_param(_), do: nil

  defp parse_filters(params) do
    %{
      q: params["q"] || "",
      stage: if(Pipeline.key?(params["stage"]), do: params["stage"], else: "all"),
      profile:
        if(is_binary(params["profile"]) and params["profile"] not in ["", "all"],
          do: params["profile"],
          else: "all"
        ),
      status:
        if(params["status"] in ~w(open paused hired closed all),
          do: params["status"],
          else: "open"
        )
    }
  end

  defp parse_lens("battleplan"), do: :battleplan
  defp parse_lens("root"), do: :root
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
        "all" ->
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

  defp blank(nil), do: nil

  defp blank(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
