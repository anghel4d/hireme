defmodule Hireme.Gym.Progress do
  @moduledoc """
  One reading of the gym for one day.

  Conditioning, not the job. `score` is weekly pace against the daily
  target (0–100). It is not Life-EV `score_100`.
  """

  @enforce_keys [:today, :target, :streak, :solved_today, :solved_week, :score, :topics, :recent]
  defstruct @enforce_keys

  @type topic_row :: %{key: atom(), label: String.t(), count: non_neg_integer()}

  @type t :: %__MODULE__{
          today: Date.t(),
          target: pos_integer(),
          streak: non_neg_integer(),
          solved_today: non_neg_integer(),
          solved_week: non_neg_integer(),
          score: 0..100,
          topics: [topic_row()],
          recent: [Hireme.Gym.Rep.t()]
        }
end

defmodule Hireme.Gym do
  @moduledoc """
  Training grind. Jumping jacks for the fight.

  LeetCode, Codeforces, systems drills. Closed atoms at the edge:
  platform, topic, difficulty, outcome. Daily target lives in kv
  (`gym` / `daily_target`). Streak counts consecutive days with a
  solved rep, GitHub-style (today, or yesterday if today is empty).
  """

  import Ecto.Query
  alias Hireme.Gym.Problem
  alias Hireme.Gym.Progress
  alias Hireme.Gym.Rep
  alias Hireme.Kv
  alias Hireme.Repo

  @platforms [:leetcode, :codeforces, :other]
  @topics [:arrays, :graphs, :strings, :dp, :trees, :systems, :other]
  @difficulties [:easy, :medium, :hard, :unknown]
  @outcomes [:solved, :attempt, :skip]

  @platform_names Map.new(@platforms, &{Atom.to_string(&1), &1})
  @topic_names Map.new(@topics, &{Atom.to_string(&1), &1})
  @difficulty_names Map.new(@difficulties, &{Atom.to_string(&1), &1})
  @outcome_names Map.new(@outcomes, &{Atom.to_string(&1), &1})

  @default_target 3
  @week 7

  @spec platforms() :: [atom()]
  def platforms, do: @platforms

  @spec topics() :: [atom()]
  def topics, do: @topics

  @spec difficulties() :: [atom()]
  def difficulties, do: @difficulties

  @spec outcomes() :: [atom()]
  def outcomes, do: @outcomes

  @spec name(atom()) :: String.t()
  def name(key) when is_atom(key), do: Atom.to_string(key)

  @spec label(atom()) :: String.t()
  def label(:dp), do: "DP"
  def label(:leetcode), do: "LeetCode"
  def label(:codeforces), do: "Codeforces"
  def label(key) when is_atom(key), do: key |> Atom.to_string() |> String.capitalize()

  @spec parse_platform(term()) :: {:ok, atom()} | :error
  def parse_platform(value), do: parse_closed(value, @platforms, @platform_names)

  @spec parse_topic(term()) :: {:ok, atom()} | :error
  def parse_topic(value), do: parse_closed(value, @topics, @topic_names)

  @spec parse_difficulty(term()) :: {:ok, atom()} | :error
  def parse_difficulty(value), do: parse_closed(value, @difficulties, @difficulty_names)

  @spec parse_outcome(term()) :: {:ok, atom()} | :error
  def parse_outcome(value), do: parse_closed(value, @outcomes, @outcome_names)

  @spec target() :: pos_integer()
  def target do
    case Kv.get("gym", "daily_target") do
      %{value: value} -> parse_target(value)
      _ -> @default_target
    end
  end

  @spec set_target(term()) :: {:ok, pos_integer()} | {:error, :target}
  def set_target(n) when is_integer(n) and n >= 1 and n <= 30 do
    Kv.put("gym", "daily_target", Integer.to_string(n))
    {:ok, n}
  end

  def set_target(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> set_target(n)
      _ -> {:error, :target}
    end
  end

  def set_target(_), do: {:error, :target}

  @spec log(map(), Date.t()) :: {:ok, Rep.t()} | {:error, term()}
  def log(attrs, today \\ Date.utc_today()) when is_map(attrs) do
    with {:ok, platform} <- required_closed(attrs, "platform", &parse_platform/1, :leetcode),
         {:ok, topic} <- required_closed(attrs, "topic", &parse_topic/1, :other),
         {:ok, difficulty} <- required_closed(attrs, "difficulty", &parse_difficulty/1, :unknown),
         {:ok, outcome} <- required_closed(attrs, "outcome", &parse_outcome/1, :solved),
         {:ok, done_on} <-
           parse_day(Map.get(attrs, "done_on") || Map.get(attrs, :done_on), today),
         {:ok, title} <- required_title(attrs),
         {:ok, slug} <- slug_of(attrs, title) do
      url = string(attrs, "url")
      note = string(attrs, "note")
      minutes = int(attrs, "minutes", 0)

      Repo.transaction(fn ->
        problem = upsert_problem!(platform, slug, title, topic, difficulty, url)

        %Rep{}
        |> Rep.changeset(%{
          problem_id: problem.id,
          done_on: done_on,
          minutes: minutes,
          outcome: outcome,
          note: note
        })
        |> Repo.insert!()
        |> Repo.preload(:problem)
      end)
    end
  end

  @spec progress(Date.t()) :: Progress.t()
  def progress(today \\ Date.utc_today()) do
    target = target()
    recent = recent()
    solved_today = solved_on(today)
    week_start = Date.add(today, 1 - @week)
    solved_week = solved_since(week_start)

    %Progress{
      today: today,
      target: target,
      streak: streak(today),
      solved_today: solved_today,
      solved_week: solved_week,
      score: pace_score(solved_week, target),
      topics: topic_rows(),
      recent: recent
    }
  end

  @spec recent(pos_integer()) :: [Rep.t()]
  def recent(limit \\ 40) do
    Repo.all(
      from r in Rep,
        join: p in assoc(r, :problem),
        preload: [problem: p],
        order_by: [desc: r.done_on, desc: r.id],
        limit: ^limit
    )
  end

  @spec ascii(Progress.t()) :: String.t()
  def ascii(%Progress{} = progress) do
    topic_line =
      progress.topics
      |> Enum.filter(&(&1.count > 0))
      |> Enum.map(&"#{&1.label} #{&1.count}")
      |> Enum.join(" · ")

    topic_line = if topic_line == "", do: "no topics yet", else: topic_line

    """
    GYM  today #{progress.solved_today}/#{progress.target}  streak #{progress.streak}d  week #{progress.solved_week}  pace #{progress.score}
    #{topic_line}
    Conditioning, not the job. FIRE HOLD still holds the hunt.
    """
    |> String.trim()
  end

  defp upsert_problem!(platform, slug, title, topic, difficulty, url) do
    case Repo.get_by(Problem, platform: platform, slug: slug) do
      nil ->
        %Problem{}
        |> Problem.changeset(%{
          platform: platform,
          slug: slug,
          title: title,
          topic: topic,
          difficulty: difficulty,
          url: url
        })
        |> Repo.insert!()

      problem ->
        problem
        |> Problem.changeset(%{
          title: title,
          topic: topic,
          difficulty: difficulty,
          url: if(url == "", do: problem.url, else: url)
        })
        |> Repo.update!()
    end
  end

  defp solved_on(%Date{} = day) do
    Repo.aggregate(
      from(r in Rep, where: r.outcome == :solved and r.done_on == ^day),
      :count
    )
  end

  defp solved_since(%Date{} = day) do
    Repo.aggregate(
      from(r in Rep, where: r.outcome == :solved and r.done_on >= ^day),
      :count
    )
  end

  defp topic_rows do
    counts =
      Repo.all(
        from r in Rep,
          join: p in assoc(r, :problem),
          where: r.outcome == :solved,
          group_by: p.topic,
          select: {p.topic, count(r.id)}
      )
      |> Map.new()

    Enum.map(@topics, fn key ->
      %{key: key, label: label(key), count: Map.get(counts, key, 0)}
    end)
  end

  defp streak(today) do
    days =
      Repo.all(from r in Rep, where: r.outcome == :solved, distinct: true, select: r.done_on)
      |> MapSet.new()

    start = if MapSet.member?(days, today), do: today, else: Date.add(today, -1)
    count_back(days, start, 0)
  end

  defp count_back(days, date, n) do
    if MapSet.member?(days, date), do: count_back(days, Date.add(date, -1), n + 1), else: n
  end

  defp pace_score(solved_week, target) do
    denom = target * @week
    min(100, round(solved_week / denom * 100))
  end

  defp parse_closed(value, keys, names) do
    cond do
      value in keys ->
        {:ok, value}

      is_binary(value) ->
        case Map.fetch(names, value) do
          {:ok, key} -> {:ok, key}
          :error -> :error
        end

      true ->
        :error
    end
  end

  defp required_closed(attrs, name, parse, default) do
    case Map.get(attrs, name) || Map.get(attrs, String.to_atom(name)) do
      nil ->
        {:ok, default}

      "" ->
        {:ok, default}

      value ->
        case parse.(value) do
          {:ok, key} -> {:ok, key}
          :error -> {:error, {:argument, name}}
        end
    end
  end

  defp required_title(attrs) do
    title = string(attrs, "title")

    if title == "" do
      {:error, {:argument, "title"}}
    else
      {:ok, title}
    end
  end

  defp slug_of(attrs, title) do
    case string(attrs, "slug") do
      "" ->
        case slugify(title) do
          "" -> {:error, {:argument, "slug"}}
          slug -> {:ok, slug}
        end

      slug ->
        {:ok, slugify(slug)}
    end
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp string(attrs, name) do
    case Map.get(attrs, name) || Map.get(attrs, String.to_atom(name)) do
      s when is_binary(s) -> String.trim(s)
      _ -> ""
    end
  end

  defp int(attrs, name, default) do
    case Map.get(attrs, name) || Map.get(attrs, String.to_atom(name)) do
      n when is_integer(n) and n >= 0 ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n >= 0 -> n
          _ -> default
        end

      _ ->
        default
    end
  end

  defp parse_day(nil, today), do: {:ok, today}
  defp parse_day("", today), do: {:ok, today}
  defp parse_day(%Date{} = date, _today), do: {:ok, date}

  defp parse_day(s, _today) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, {:argument, "done_on"}}
    end
  end

  defp parse_day(_, _), do: {:error, {:argument, "done_on"}}

  defp parse_target(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 1 and n <= 30 -> n
      _ -> @default_target
    end
  end
end
