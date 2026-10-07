defmodule HiremeWeb.Router do
  use Phoenix.Router, helpers: false
  import Plug.Conn
  import Phoenix.Controller

  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HiremeWeb do
    pipe_through :browser

    get "/", DeskController, :index
  end

  scope "/api", HiremeWeb do
    pipe_through :api

    get "/pack", DeskController, :pack
    get "/scoreboard", DeskController, :scoreboard
    get "/focus/:id", DeskController, :focus
    get "/root/:id", DeskController, :root
    get "/lanes", DeskController, :lanes
    post "/jobs/:id/stage", DeskController, :set_stage
    post "/jobs/:id/next", DeskController, :set_next
    post "/jobs/:id/note", DeskController, :set_note
    post "/jobs/:id/score", DeskController, :set_score
    post "/jobs/:id/overlay", DeskController, :put_overlay
    post "/jobs/:id/heat_override", DeskController, :heat_override
    post "/batches/:code/open_fire", DeskController, :name_open_fire
    post "/narratives/:id", DeskController, :save_narrative
    post "/gym/log", DeskController, :gym_log
    post "/gym/target", DeskController, :gym_target
    post "/net/log", DeskController, :net_log
    post "/net/lane", DeskController, :net_lane
  end
end

defmodule HiremeWeb.DeskController do
  @moduledoc """
  The desk over HTTP: the page the shell draws on, one columnar packet
  for the board, JSON for what is opened and for the lanes, and the
  human's writes. A write answers with the new focus (or the refreshed
  lanes); a refusal maps to a status code and the body says why.
  """

  use Phoenix.Controller, formats: [:html, :json]

  use Phoenix.VerifiedRoutes,
    endpoint: HiremeWeb.Endpoint,
    router: HiremeWeb.Router,
    statics: HiremeWeb.static_paths()

  import Plug.Conn

  alias Hireme.Desk
  alias Hireme.Desk.Overlay
  alias Hireme.Gym
  alias Hireme.Heat
  alias Hireme.Narrative
  alias Hireme.Net
  alias Hireme.Pipeline
  alias Hireme.Repo
  alias HiremeWeb.JSON

  def index(conn, _params) do
    page = """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Desk · Hireme</title>
        <link rel="stylesheet" href="#{~p"/assets/js/app.css"}" />
        <script defer type="module" src="#{~p"/assets/js/app.js"}"></script>
      </head>
      <body>
        <div id="desk" class="desk"></div>
      </body>
    </html>
    """

    conn |> put_resp_content_type("text/html") |> send_resp(200, page)
  end

  def pack(conn, _params) do
    conn
    |> put_resp_content_type("application/vnd.hireme.desk-packet", nil)
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, Desk.packet())
  end

  def scoreboard(conn, _params), do: json(conn, JSON.scoreboard(Desk.scoreboard()))

  def lanes(conn, _params), do: json(conn, JSON.lanes())

  def focus(conn, %{"id" => id}) do
    with {:ok, id} <- int(id),
         %Desk.Focus{} = focus <- Desk.focus(id) do
      json(conn, JSON.focus(focus))
    else
      _ -> JSON.refuse(conn, :not_found)
    end
  end

  def root(conn, %{"id" => id}) do
    case int(id) do
      {:ok, id} -> json(conn, JSON.root(Desk.root(id)))
      :error -> JSON.refuse(conn, :not_found)
    end
  end

  def set_stage(conn, %{"id" => id, "stage" => stage}) do
    write(conn, id, fn id ->
      with {:ok, stage} <- Pipeline.parse(stage) |> or_argument("stage"),
           do: Desk.set_stage(id, stage)
    end)
  end

  def set_next(conn, %{"id" => id} = params) do
    due =
      case Date.from_iso8601(params["next_due"] || "") do
        {:ok, d} -> d
        _ -> nil
      end

    write(conn, id, &Desk.set_next(&1, String.trim(params["next_action"] || ""), due))
  end

  def set_note(conn, %{"id" => id, "stage" => stage, "note" => note}) do
    write(conn, id, fn id ->
      with {:ok, stage} <- Pipeline.parse(stage) |> or_argument("stage"),
           do: Desk.set_note(id, stage, note || "")
    end)
  end

  def set_score(conn, %{"id" => id, "score" => score}) do
    write(conn, id, fn id ->
      case int(score) do
        {:ok, score} when score in 0..100 -> Desk.set_score(id, score)
        _ -> {:error, {:argument, "score"}}
      end
    end)
  end

  def put_overlay(conn, %{"id" => id, "item_id" => item_id, "mode" => mode} = params) do
    write(conn, id, fn id ->
      with {:ok, item_id} <- int(item_id) |> or_argument("item_id"),
           {:ok, change} <- overlay_change(mode, params),
           do: Desk.put_overlay(id, item_id, change)
    end)
  end

  def heat_override(conn, %{"id" => id, "reason" => reason}) do
    write(conn, id, fn id ->
      case Heat.set_override(id, reason || "") do
        {:error, :reason} -> {:error, {400, "HEAT override needs a written reason."}}
        other -> other
      end
    end)
  end

  def name_open_fire(conn, %{"code" => code}) do
    case Desk.name_open_fire(code) do
      {:ok, batch} -> json(conn, %{ok: true, batch: %{code: batch.code, fire: batch.fire}})
      {:error, reason} -> JSON.refuse(conn, reason)
    end
  end

  def save_narrative(conn, %{"id" => id, "body" => body}) when is_binary(body) do
    with {:ok, id} <- int(id),
         %Hireme.Corpus.Narrative{} = row <- Repo.get(Hireme.Corpus.Narrative, id) do
      saved = Narrative.update!(row, body)

      json(conn, %{ok: true, narrative: %{id: saved.id, body: saved.body, version: saved.version}})
    else
      _ -> JSON.refuse(conn, :not_found)
    end
  end

  def gym_log(conn, params),
    do: lane_write(conn, Gym.log(params), {422, "Could not log that rep."})

  def gym_target(conn, %{"target" => target}),
    do: lane_write(conn, Gym.set_target(target), {400, "Daily target is 1–30."})

  def net_log(conn, params),
    do: lane_write(conn, Net.log(params), {422, "Could not log that entry."})

  def net_lane(conn, %{"url" => url}),
    do: lane_write(conn, Net.set_lane(url), {400, "Lane URL did not save."})

  # One write on one application: the id is parsed once, the change runs,
  # and the answer is the application as it now reads.
  defp write(conn, id, change) do
    with {:ok, id} <- int(id),
         {:ok, _} <- change.(id),
         %Desk.Focus{} = focus <- Desk.focus(id) do
      json(conn, %{ok: true, focus: JSON.focus(focus)})
    else
      {:error, reason} -> JSON.refuse(conn, reason)
      _ -> JSON.refuse(conn, :not_found)
    end
  end

  defp lane_write(conn, result, failed) do
    case result do
      {:ok, _} -> json(conn, Map.put(JSON.lanes(), :ok, true))
      {:error, {:argument, name}} -> JSON.refuse(conn, {400, "Need a #{name}."})
      {:error, _} -> JSON.refuse(conn, failed)
    end
  end

  defp overlay_change("inherit", _params), do: {:ok, :inherit}

  defp overlay_change(mode, params) do
    case Overlay.parse_mode(mode) do
      {:ok, :altered} ->
        case String.trim(params["body"] || "") do
          "" -> {:error, {:argument, "body"}}
          body -> {:ok, %{mode: :altered, body: body, reason: blank(params["reason"])}}
        end

      {:ok, :hidden} ->
        {:ok, %{mode: :hidden, reason: params["reason"] || "Hidden from this CV"}}

      {:ok, :emphasized} ->
        {:ok, %{mode: :emphasized, reason: params["reason"] || "Emphasized for this CV"}}

      :error ->
        {:error, {:argument, "mode"}}
    end
  end

  defp or_argument({:ok, v}, _name), do: {:ok, v}
  defp or_argument(_, name), do: {:error, {:argument, name}}

  defp int(n) when is_integer(n), do: {:ok, n}

  defp int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp int(_), do: :error

  defp blank(nil), do: nil

  defp blank(text) do
    case String.trim(text) do
      "" -> nil
      t -> t
    end
  end
end
