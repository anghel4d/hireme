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

  test "progress counts repeated solves and preserves lifetime and open-ended week windows" do
    assert Gym.progress(@today).solved_week == 0

    for day <- [Date.add(@today, -7), Date.add(@today, -6), @today, @today, Date.add(@today, 1)] do
      assert {:ok, rep} =
               Gym.log(%{"title" => "Repeated graph", "topic" => "graphs"}, day)

      assert rep.problem.id == rep.problem_id
      assert rep.problem.topic == :graphs
    end

    assert {:ok, _} =
             Gym.log(%{"title" => "Attempt", "outcome" => "attempt"}, @today)

    progress = Gym.progress(@today)
    assert progress.solved_today == 2
    assert progress.solved_week == 4
    assert progress.streak == 1
    assert Enum.find(progress.topics, &(&1.key == :graphs)).count == 5
    assert Enum.find(progress.topics, &(&1.key == :arrays)).count == 0
    assert hd(progress.recent).done_on == Date.add(@today, 1)

    Hireme.DataCase.open_account("Other gym")
    other = Gym.progress(@today)
    assert {other.solved_today, other.solved_week, other.streak, other.recent} == {0, 0, 0, []}
    assert Enum.all?(other.topics, &(&1.count == 0))
  end

  test "minutes remain strict nonnegative integers, not rounded or trimmed" do
    for {value, expected} <- [
          {7, 7},
          {"7", 7},
          {"+7", 7},
          {2.6, 0},
          {" 7 ", 0},
          {-1, 0},
          {"-1", 0},
          {"7x", 0},
          {nil, 0}
        ] do
      assert {:ok, rep} = Gym.log(%{"title" => "Strict minutes", "minutes" => value}, @today)
      assert rep.minutes == expected
    end
  end

  test "lane forms prefer truthy string keys before atom keys" do
    assert {:ok, rep} =
             Gym.log(
               %{
                 :title => nil,
                 "title" => "Mixed keys",
                 :platform => :other,
                 "platform" => "leetcode",
                 :minutes => 25,
                 "minutes" => false,
                 :done_on => @today,
                 "done_on" => "2020-01-01",
                 :note => "atom note",
                 "note" => ""
               },
               @today
             )

    assert rep.problem.title == "Mixed keys"
    assert rep.problem.platform == :leetcode
    assert {rep.minutes, rep.done_on, rep.note} == {25, ~D[2020-01-01], ""}
  end

  test "implicit empty slugs are refused; explicit empty normalized slugs reach the changeset" do
    assert Gym.log(%{"title" => "!!!"}, @today) == {:error, {:argument, "slug"}}

    assert_raise Ecto.InvalidChangesetError, fn ->
      Gym.log(%{"title" => "Explicit slug", "slug" => "!!!"}, @today)
    end
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
