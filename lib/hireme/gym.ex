defmodule Hireme.Gym do
  @moduledoc """
  Training grind. Jumping jacks for the fight.

  LeetCode, Codeforces, systems drills. Closed atoms at the edge:
  platform, topic, difficulty, outcome. Daily target lives in kv
  (`gym` / `daily_target`); streak and pace are the client's to derive
  from the reps. Logged reps reuse the problem loaded inside their
  write transaction.
  """

  alias Hireme.Form
  alias Hireme.Gym.Problem
  alias Hireme.Gym.Rep
  alias Hireme.Kv
  alias Hireme.Repo
  alias Hireme.Text

  @platforms [:leetcode, :codeforces, :other]
  @topics [:arrays, :graphs, :strings, :dp, :trees, :systems, :other]
  @difficulties [:easy, :medium, :hard, :unknown]
  @outcomes [:solved, :attempt, :skip]

  @spec platforms() :: [atom()]
  def platforms, do: @platforms

  @spec topics() :: [atom()]
  def topics, do: @topics

  @spec difficulties() :: [atom()]
  def difficulties, do: @difficulties

  @spec outcomes() :: [atom()]
  def outcomes, do: @outcomes

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
    if slug == "", do: {:error, {:argument, "slug"}}, else: {:ok, slug}
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
end
