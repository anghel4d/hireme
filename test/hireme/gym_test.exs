defmodule Hireme.GymTest do
  use Hireme.DataCase, async: false

  alias Hireme.Gym

  @today ~D[2026-10-07]

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

  # Forms as a page or an agent could send them: closed names, junk, dates,
  # numbers, under string or atom keys, some fields missing.
  test "any form logs a rep whose closed fields are members, or names the field it refuses" do
    :rand.seed(:exsss, {2026, 10, 9})

    members = %{
      platform: Gym.platforms(),
      topic: Gym.topics(),
      difficulty: Gym.difficulties(),
      outcome: Gym.outcomes()
    }

    results =
      for i <- 1..150 do
        form =
          Hireme.Fixtures.form(
            Map.merge(members, %{
              title: ["Two Sum #{i}", "", "!!!", "x"],
              slug: ["two-sum", "", "!!!", "Ü"],
              url: ["https://x.test/#{i}", ""],
              minutes: [0, 7, -1, "9", "x"],
              note: ["", "n"],
              done_on: ["2026-10-09", "2026-13-40", "", nil]
            })
          )

        case Gym.log(form, @today) do
          {:ok, %Gym.Rep{} = rep} ->
            assert rep.problem.platform in members.platform and rep.problem.topic in members.topic
            assert rep.problem.difficulty in members.difficulty and rep.outcome in members.outcome
            assert is_integer(rep.minutes) and rep.minutes >= 0
            assert match?(%Date{}, rep.done_on)
            assert rep.problem.title != "" and rep.problem.slug != ""
            :ok

          {:error, {:argument, field}} when is_binary(field) ->
            :refused
        end
      end

    assert :ok in results and :refused in results
  end
end
