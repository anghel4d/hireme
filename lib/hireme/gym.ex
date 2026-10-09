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
  Logged reps reuse the problem loaded inside their write transaction.
  """

  import Ecto.Query
  alias Hireme.Closed
  alias Hireme.Form
  alias Hireme.Gym.Problem
  alias Hireme.Gym.Progress
  alias Hireme.Gym.Rep
  alias Hireme.Kv
  alias Hireme.Repo
  alias Hireme.Text

  @platforms [:leetcode, :codeforces, :other]
  @topics [:arrays, :graphs, :strings, :dp, :trees, :systems, :other]
  @difficulties [:easy, :medium, :hard, :unknown]
  @outcomes [:solved, :attempt, :skip]
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

  @spec label(atom()) :: String.t()
  def label(:dp), do: "DP"
  def label(:leetcode), do: "LeetCode"
  def label(:codeforces), do: "Codeforces"
  def label(key) when is_atom(key), do: key |> Atom.to_string() |> String.capitalize()

  @spec parse_platform(term()) :: {:ok, atom()} | :error
  def parse_platform(value), do: Closed.parse(@platforms, value)

  @spec parse_topic(term()) :: {:ok, atom()} | :error
  def parse_topic(value), do: Closed.parse(@topics, value)

  @spec parse_difficulty(term()) :: {:ok, atom()} | :error
  def parse_difficulty(value), do: Closed.parse(@difficulties, value)

  @spec parse_outcome(term()) :: {:ok, atom()} | :error
  def parse_outcome(value), do: Closed.parse(@outcomes, value)

  @spec target() :: pos_integer()
  def target do
    with %Kv.Pair{value: value} <- Kv.get("gym", "daily_target"),
         {:ok, n} <- parse_target(value) do
      n
    else
      _ -> @default_target
    end
  end

  @spec set_target(term()) :: {:ok, pos_integer()} | {:error, :target}
  def set_target(value) do
    with {:ok, n} <- parse_target(value) do
      Kv.put("gym", "daily_target", Integer.to_string(n))
      {:ok, n}
    end
  end

  @spec log(map(), Date.t()) :: {:ok, Rep.t()} | {:error, term()}
  def log(attrs, today \\ Date.utc_today()) when is_map(attrs) do
    with {:ok, platform} <- Form.closed(attrs, :platform, @platforms, :leetcode),
         {:ok, topic} <- Form.closed(attrs, :topic, @topics, :other),
         {:ok, difficulty} <- Form.closed(attrs, :difficulty, @difficulties, :unknown),
         {:ok, outcome} <- Form.closed(attrs, :outcome, @outcomes, :solved),
         {:ok, done_on} <- Form.day(attrs, :done_on, today),
         {:ok, title} <- Form.required(attrs, :title),
         {:ok, slug} <- slug(attrs, title) do
      Repo.transaction(fn ->
        problem =
          upsert_problem!(platform, slug, title, topic, difficulty, Form.string(attrs, :url))

        %Rep{}
        |> Rep.changeset(%{
          problem_id: problem.id,
          done_on: done_on,
          minutes: Form.nonnegative(attrs, :minutes),
          outcome: outcome,
          note: Form.string(attrs, :note)
        })
        |> Repo.insert!()
        |> Map.put(:problem, problem)
      end)
    end
  end

  @spec progress(Date.t()) :: Progress.t()
  def progress(today \\ Date.utc_today()) do
    target = target()
    solved_week = solved_since(Date.add(today, 1 - @week))

    %Progress{
      today: today,
      target: target,
      streak: streak(today),
      solved_today: solved_on(today),
      solved_week: solved_week,
      score: min(100, round(solved_week / (target * @week) * 100)),
      topics: topic_rows(),
      recent: recent()
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
      |> Enum.map_join(" · ", &"#{&1.label} #{&1.count}")

    """
    GYM  today #{progress.solved_today}/#{progress.target}  streak #{progress.streak}d  week #{progress.solved_week}  pace #{progress.score}
    #{if topic_line == "", do: "no topics yet", else: topic_line}
    Conditioning, not the job. FIRE HOLD still holds the hunt.
    """
    |> String.trim()
  end

  defp parse_target(n) when is_integer(n) and n in 1..30, do: {:ok, n}

  defp parse_target(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> parse_target(n)
      _ -> {:error, :target}
    end
  end

  defp parse_target(_), do: {:error, :target}

  defp slug(attrs, title) do
    given = Form.string(attrs, :slug)
    slug = Text.slug(if(given == "", do: title, else: given))
    if given == "" and slug == "", do: {:error, {:argument, "slug"}}, else: {:ok, slug}
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
    Repo.aggregate(from(r in Rep, where: r.outcome == :solved and r.done_on == ^day), :count)
  end

  defp solved_since(%Date{} = day) do
    Repo.aggregate(from(r in Rep, where: r.outcome == :solved and r.done_on >= ^day), :count)
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

    Enum.map(@topics, &%{key: &1, label: label(&1), count: Map.get(counts, &1, 0)})
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
end
