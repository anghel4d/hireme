defmodule Hireme.Lanes do
  @moduledoc false
  # Form readers the gym and the net share. Every reader answers
  # `{:ok, value}` or `{:error, {:argument, name}}`; nothing raises.

  alias Hireme.Attrs
  alias Hireme.Closed

  # A member of `set` named by the form, `default` when the field is
  # blank, refused otherwise. A nil default makes the field required.
  def closed(attrs, name, set, default) do
    case Attrs.get(attrs, name) do
      blank when blank in [nil, ""] ->
        if default, do: {:ok, default}, else: argument(name)

      value ->
        case Closed.parse(set, value) do
          {:ok, atom} -> {:ok, atom}
          :error -> argument(name)
        end
    end
  end

  # A date from the form, `default` when blank, refused when unreadable.
  def day(attrs, name, default) do
    case Attrs.get(attrs, name) do
      blank when blank in [nil, ""] ->
        {:ok, default}

      %Date{} = date ->
        {:ok, date}

      s when is_binary(s) ->
        case Date.from_iso8601(s) do
          {:ok, date} -> {:ok, date}
          _ -> argument(name)
        end

      _ ->
        argument(name)
    end
  end

  def required(attrs, name) do
    case Attrs.string(attrs, name) do
      "" -> argument(name)
      text -> {:ok, text}
    end
  end

  defp argument(name), do: {:error, {:argument, Atom.to_string(name)}}
end

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
  alias Hireme.Attrs
  alias Hireme.Closed
  alias Hireme.Gym.Problem
  alias Hireme.Gym.Progress
  alias Hireme.Gym.Rep
  alias Hireme.Kv
  alias Hireme.Lanes
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

  @spec name(atom()) :: String.t()
  def name(key) when is_atom(key), do: Atom.to_string(key)

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
    with {:ok, platform} <- Lanes.closed(attrs, :platform, @platforms, :leetcode),
         {:ok, topic} <- Lanes.closed(attrs, :topic, @topics, :other),
         {:ok, difficulty} <- Lanes.closed(attrs, :difficulty, @difficulties, :unknown),
         {:ok, outcome} <- Lanes.closed(attrs, :outcome, @outcomes, :solved),
         {:ok, done_on} <- Lanes.day(attrs, :done_on, today),
         {:ok, title} <- Lanes.required(attrs, :title),
         {:ok, slug} <- slug(attrs, title) do
      Repo.transaction(fn ->
        problem =
          upsert_problem!(platform, slug, title, topic, difficulty, Attrs.string(attrs, :url))

        %Rep{}
        |> Rep.changeset(%{
          problem_id: problem.id,
          done_on: done_on,
          minutes: max(Attrs.int(attrs, :minutes, 0), 0),
          outcome: outcome,
          note: Attrs.string(attrs, :note)
        })
        |> Repo.insert!()
        |> Repo.preload(:problem)
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
    source =
      case Attrs.string(attrs, :slug) do
        "" -> title
        given -> given
      end

    case Text.slug(source) do
      "" -> {:error, {:argument, "slug"}}
      slug -> {:ok, slug}
    end
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

defmodule Hireme.Net.Progress do
  @moduledoc """
  One reading of the networking lane.

  Not a CRM. Counts shipped posts/artifacts, open drafts, and
  Broadside Observer runs. `lane` is the Observer research URL.
  """

  @enforce_keys [:lane, :shipped_week, :drafts, :observer_runs, :recent]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          lane: String.t(),
          shipped_week: non_neg_integer(),
          drafts: non_neg_integer(),
          observer_runs: non_neg_integer(),
          recent: [Hireme.Net.Entry.t()]
        }
end

defmodule Hireme.Net do
  @moduledoc """
  Lightweight networking. Not CRM spam.

  Closed kinds: observer run, shipped artifact, public post, outreach
  draft. Closed channels: Broadside, X, other. The Broadside research
  lane URL lives in kv (`net` / `broadside_lane`).
  """

  import Ecto.Query
  alias Hireme.Attrs
  alias Hireme.Closed
  alias Hireme.Kv
  alias Hireme.Lanes
  alias Hireme.Net.Entry
  alias Hireme.Net.Progress
  alias Hireme.Repo

  @kinds [:observer, :artifact, :post, :draft]
  @channels [:broadside, :x, :other]
  @week 7

  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @spec channels() :: [atom()]
  def channels, do: @channels

  @spec name(atom()) :: String.t()
  def name(key) when is_atom(key), do: Atom.to_string(key)

  @spec label(atom()) :: String.t()
  def label(:x), do: "X"
  def label(key) when is_atom(key), do: key |> Atom.to_string() |> String.capitalize()

  @spec parse_kind(term()) :: {:ok, atom()} | :error
  def parse_kind(value), do: Closed.parse(@kinds, value)

  @spec parse_channel(term()) :: {:ok, atom()} | :error
  def parse_channel(value), do: Closed.parse(@channels, value)

  @spec lane() :: String.t()
  def lane do
    case Kv.get("net", "broadside_lane") do
      %Kv.Pair{value: value} -> String.trim(value)
      _ -> ""
    end
  end

  @spec set_lane(term()) :: {:ok, String.t()} | {:error, :lane}
  def set_lane(url) when is_binary(url) do
    trimmed = String.trim(url)
    Kv.put("net", "broadside_lane", trimmed)
    {:ok, trimmed}
  end

  def set_lane(_), do: {:error, :lane}

  @spec log(map(), Date.t()) :: {:ok, Entry.t()} | {:error, term()}
  def log(attrs, today \\ Date.utc_today()) when is_map(attrs) do
    with {:ok, kind} <- Lanes.closed(attrs, :kind, @kinds, nil),
         {:ok, channel} <- Lanes.closed(attrs, :channel, @channels, default_channel(kind)),
         {:ok, title} <- Lanes.required(attrs, :title),
         {:ok, shipped_on} <-
           Lanes.day(attrs, :shipped_on, if(kind == :draft, do: nil, else: today)) do
      %Entry{}
      |> Entry.changeset(%{
        kind: kind,
        channel: channel,
        title: title,
        url: Attrs.string(attrs, :url),
        body: Attrs.string(attrs, :body),
        shipped_on: shipped_on
      })
      |> Repo.insert()
    end
  end

  @spec progress(Date.t()) :: Progress.t()
  def progress(today \\ Date.utc_today()) do
    %Progress{
      lane: lane(),
      shipped_week: shipped_since(Date.add(today, 1 - @week)),
      drafts: count_kind(:draft),
      observer_runs: count_kind(:observer),
      recent: recent()
    }
  end

  @spec recent(pos_integer()) :: [Entry.t()]
  def recent(limit \\ 40) do
    Repo.all(from e in Entry, order_by: [desc: e.id], limit: ^limit)
  end

  @spec ascii(Progress.t()) :: String.t()
  def ascii(%Progress{} = progress) do
    """
    NET  shipped #{progress.shipped_week}/7d  drafts #{progress.drafts}  observer #{progress.observer_runs}
    lane #{if progress.lane == "", do: "(no Broadside lane yet)", else: progress.lane}
    Not CRM. Run Observer. Ship the work. Post it.
    """
    |> String.trim()
  end

  defp shipped_since(%Date{} = day) do
    Repo.aggregate(
      from(e in Entry,
        where: e.kind in [:artifact, :post] and not is_nil(e.shipped_on) and e.shipped_on >= ^day
      ),
      :count
    )
  end

  defp count_kind(kind), do: Repo.aggregate(from(e in Entry, where: e.kind == ^kind), :count)

  defp default_channel(:observer), do: :broadside
  defp default_channel(:post), do: :x
  defp default_channel(_), do: :other
end
