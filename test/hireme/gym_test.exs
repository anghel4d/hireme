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

  test "daily target is stored in kv and capped" do
    assert {:ok, 5} = Gym.set_target("5")
    assert Hireme.Kv.get("gym", "daily_target").value == "5"
    assert {:error, :target} = Gym.set_target(0)
    assert {:error, :target} = Gym.set_target(99)
    assert Hireme.Kv.get("gym", "daily_target").value == "5"
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
end
