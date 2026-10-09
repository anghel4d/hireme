defmodule Hireme.ScoreTest do
  use Hireme.DataCase, async: false
  import Hireme.Fixtures

  alias Hireme.Desk
  alias Hireme.Desk.Filters
  alias Hireme.Import

  test "a pack's score_100 lands on the card, orders the board, and filters by floor and band" do
    profile = profile()

    pack = """
    {"batch":"Batch-009","status":"draft_prep","fire":"hold","apps":[
      {"company":"Middling Co","role":"Engineer","url":"https://jobs.example.test/mid","score_100":70,"stage":"gated"},
      {"company":"Titan Labs","role":"Engineer","url":"https://jobs.example.test/titan","score_100":100,"stage":"discovered"},
      {"company":"High Co","role":"Engineer","url":"https://jobs.example.test/high","score":92,"stage":"gated"},
      {"company":"Plain Co","role":"Engineer","url":"https://jobs.example.test/plain","stage":"gated"}
    ]}
    """

    assert {:ok, %{count: 4}} = Import.import_body(pack, "batch-009.json", profile)

    all = Desk.list_cards(%Filters{status: :all})
    assert Enum.map(all, & &1.company) |> Enum.take(3) == ["Titan Labs", "High Co", "Middling Co"]

    assert Desk.list_cards(%Filters{status: :all, min_score: 90}) |> Enum.map(& &1.score_100) == [
             100,
             92
           ]

    assert Desk.list_cards(%Filters{status: :all, band: :systems}) |> Enum.map(& &1.company) == [
             "Middling Co"
           ]

    chart = Desk.score_chart("Batch-009")
    assert Desk.score_chart("Batch-missing").n == 0
    assert Desk.score_chart(:leftover).n == 0
    assert chart.n == 4
    assert Enum.find(chart.bands, &(&1.key == :frontier)).count == 1

    assert %{n: 2, min: 92, max: 100, mean: 96.0} =
             Desk.score_chart(%Filters{status: :all, min_score: 90})

    assert %{n: 1, min: 70, max: 70} =
             Desk.score_chart(%Filters{status: :all, band: :systems, batch: "Batch-009"})

    assert %{n: 1, min: 92} = Desk.score_chart(%Filters{status: :all, q: "High"})
    assert Desk.score_chart(%Filters{status: :all, heat: :cool}).n == 4
    assert Desk.score_chart(%Filters{status: :all, heat: :blocked}).n == 0
    other = Hireme.Accounts.create!(%{name: "Other score account"})

    assert Hireme.Repo.with_account(other.id, fn ->
             Desk.score_chart(%Filters{status: :all}).n
           end) == 0

    filters = Filters.from_params(%{"min_score" => "85", "band" => "weird"})
    assert filters.min_score == 85
    assert filters.band == :all
    assert Filters.to_query(filters) == %{"min_score" => "85"}

    # A re-import without a score keeps the one on the card.
    again =
      ~s({"apps":[{"company":"Titan Labs","role":"Engineer","url":"https://jobs.example.test/titan"}]})

    assert {:ok, _} = Import.import_body(again, "again.json", profile)
    assert [%{score_100: 100}] = Desk.list_cards(%Filters{status: :all, band: :frontier})
  end
end
