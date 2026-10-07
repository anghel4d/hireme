defmodule Hireme.GymTest do
  use Hireme.DataCase, async: false

  alias Hireme.Gym

  @today ~D[2026-10-07]

  test "closed atoms parse at the edge and refuse junk" do
    assert Gym.parse_platform("leetcode") == {:ok, :leetcode}
    assert Gym.parse_topic("graphs") == {:ok, :graphs}
    assert Gym.parse_difficulty("hard") == {:ok, :hard}
    assert Gym.parse_outcome("attempt") == {:ok, :attempt}
    assert Gym.parse_platform("hackerrank") == :error
    assert Gym.parse_topic("crm") == :error
  end

  test "a solved rep counts toward today, streak, topics, and weekly pace" do
    assert {:ok, _} =
             Gym.log(
               %{
                 "platform" => "leetcode",
                 "title" => "Two Sum",
                 "topic" => "arrays",
                 "difficulty" => "easy",
                 "outcome" => "solved"
               },
               @today
             )

    assert {:ok, _} =
             Gym.log(
               %{
                 "platform" => "codeforces",
                 "title" => "Shortest Path",
                 "topic" => "graphs",
                 "difficulty" => "medium"
               },
               @today
             )

    assert {:ok, _} =
             Gym.log(
               %{
                 "title" => "Warmup skip",
                 "topic" => "arrays",
                 "outcome" => "skip"
               },
               @today
             )

    progress = Gym.progress(@today)
    assert progress.solved_today == 2
    assert progress.target == 3
    assert progress.streak == 1
    assert progress.solved_week == 2
    assert progress.score == round(2 / 21 * 100)

    arrays = Enum.find(progress.topics, &(&1.key == :arrays))
    graphs = Enum.find(progress.topics, &(&1.key == :graphs))
    assert arrays.count == 1
    assert graphs.count == 1
  end

  test "streak is consecutive solved days, GitHub-style" do
    log_solved("Day three", ~D[2026-10-05])
    log_solved("Day two", ~D[2026-10-06])
    progress = Gym.progress(@today)
    assert progress.streak == 2
    assert progress.solved_today == 0

    log_solved("Day one", @today)
    assert Gym.progress(@today).streak == 3
  end

  test "daily target is stored in kv and capped" do
    assert {:ok, 5} = Gym.set_target("5")
    assert Gym.target() == 5
    assert {:error, :target} = Gym.set_target(0)
    assert {:error, :target} = Gym.set_target(99)
    assert Gym.target() == 5
  end

  test "the same platform+slug updates the problem instead of duplicating" do
    assert {:ok, first} =
             Gym.log(
               %{"title" => "Clone Graph", "slug" => "clone-graph", "topic" => "graphs"},
               @today
             )

    assert {:ok, second} =
             Gym.log(
               %{
                 "title" => "Clone Graph",
                 "slug" => "clone-graph",
                 "topic" => "graphs",
                 "difficulty" => "medium"
               },
               @today
             )

    assert first.problem_id == second.problem_id
    assert second.problem.difficulty == :medium
  end

  test "ascii names conditioning and not Life-EV" do
    text = Gym.ascii(Gym.progress(@today))
    assert text =~ "GYM"
    assert text =~ "Conditioning, not the job"
  end

  defp log_solved(title, day) do
    {:ok, _} = Gym.log(%{"title" => title, "topic" => "systems"}, day)
  end
end
