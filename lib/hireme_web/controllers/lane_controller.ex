defmodule HiremeWeb.LaneController do
  @moduledoc """
  The lanes beside the desk: gym, networking, and company heat. One read
  returns all three; the writes answer with the refreshed lanes.
  """

  use Phoenix.Controller, formats: [:json]
  import Plug.Conn

  alias Hireme.Gym
  alias Hireme.Heat
  alias Hireme.Net

  def index(conn, _params), do: json(conn, lanes())

  def gym_log(conn, params) do
    case Gym.log(params) do
      {:ok, _rep} -> json(conn, Map.put(lanes(), :ok, true))
      {:error, {:argument, name}} -> refuse(conn, 400, "Need a #{name}.")
      {:error, _} -> refuse(conn, 422, "Could not log that rep.")
    end
  end

  def gym_target(conn, %{"target" => target}) do
    case Gym.set_target(target) do
      {:ok, _} -> json(conn, Map.put(lanes(), :ok, true))
      {:error, _} -> refuse(conn, 400, "Daily target is 1–30.")
    end
  end

  def net_log(conn, params) do
    case Net.log(params) do
      {:ok, _entry} -> json(conn, Map.put(lanes(), :ok, true))
      {:error, {:argument, name}} -> refuse(conn, 400, "Need a #{name}.")
      {:error, _} -> refuse(conn, 422, "Could not log that entry.")
    end
  end

  def net_lane(conn, %{"url" => url}) do
    case Net.set_lane(url) do
      {:ok, _} -> json(conn, Map.put(lanes(), :ok, true))
      {:error, _} -> refuse(conn, 400, "Lane URL did not save.")
    end
  end

  def heat_override(conn, %{"id" => id, "reason" => reason}) do
    with {id, ""} <- Integer.parse(to_string(id)),
         {:ok, _} <- Heat.set_override(id, reason || "") do
      case Hireme.Desk.focus(id) do
        nil -> refuse(conn, 404, "not found")
        focus -> json(conn, %{ok: true, focus: HiremeWeb.DeskJSON.focus(focus)})
      end
    else
      {:error, :reason} -> refuse(conn, 400, "HEAT override needs a written reason.")
      _ -> refuse(conn, 404, "not found")
    end
  end

  @doc false
  def lanes do
    gym = Gym.progress()
    net = Net.progress()
    chart = Heat.chart()

    %{
      gym: %{
        target: gym.target,
        streak: gym.streak,
        solved_today: gym.solved_today,
        solved_week: gym.solved_week,
        score: gym.score,
        topics: Enum.map(gym.topics, &%{key: &1.key, label: &1.label, count: &1.count}),
        recent:
          Enum.map(gym.recent, fn rep ->
            %{
              id: rep.id,
              done_on: rep.done_on,
              outcome: rep.outcome,
              minutes: rep.minutes,
              note: rep.note,
              title: rep.problem.title,
              url: rep.problem.url,
              platform: Gym.label(rep.problem.platform),
              topic: Gym.label(rep.problem.topic),
              difficulty: Gym.label(rep.problem.difficulty)
            }
          end),
        platforms: options(Gym.platforms(), &Gym.label/1),
        topics_all: options(Gym.topics(), &Gym.label/1),
        difficulties: options(Gym.difficulties(), &Gym.label/1),
        outcomes: options(Gym.outcomes(), &Gym.label/1)
      },
      net: %{
        lane: net.lane,
        shipped_week: net.shipped_week,
        drafts: net.drafts,
        observer_runs: net.observer_runs,
        recent:
          Enum.map(net.recent, fn e ->
            %{
              id: e.id,
              kind: Net.label(e.kind),
              channel: Net.label(e.channel),
              title: e.title,
              url: e.url,
              body: e.body,
              shipped_on: e.shipped_on
            }
          end),
        kinds: options(Net.kinds(), &Net.label/1),
        channels: options(Net.channels(), &Net.label/1)
      },
      heat: %{
        companies: Enum.map(chart.companies, &heat_row/1),
        vendors: Enum.map(chart.vendors, &heat_row/1)
      }
    }
  end

  defp heat_row(row) do
    %{
      key: row.key,
      label: row.label,
      load: Float.round(row.load * 1.0, 1),
      cap: Float.round(row.cap * 1.0, 1),
      ratio: row.ratio,
      n: row.n,
      cooldown_days: row.cooldown_days
    }
  end

  defp options(keys, label), do: Enum.map(keys, &%{key: Atom.to_string(&1), label: label.(&1)})

  defp refuse(conn, status, message), do: conn |> put_status(status) |> json(%{error: message})
end
