defmodule Hireme.ScoreTest do
  use Hireme.DataCase, async: false
  import Hireme.Fixtures

  alias Hireme.Campaign
  alias Hireme.Desk
  alias Hireme.Desk.Filters
  alias Hireme.Import
  alias Hireme.Letterbox

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

    chart = Campaign.scoreboard().chart
    assert Desk.score_chart("Batch-009") == chart
    assert Desk.score_chart("Batch-missing").n == 0
    assert Desk.score_chart(:leftover).n == 0
    assert chart.n == 4
    assert Enum.find(chart.bands, &(&1.key == :frontier)).count == 1

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

  test "the directory ranks by score_100 and a lease can set its own" do
    profile = profile()

    low = job(profile, %{company: "Low Co", score_100: 40})
    high = job(profile, %{company: "High Co", score_100: "95"})

    listed = tool_call("list_applications", %{"status" => "all"})

    assert Enum.map(listed.result["applications"], & &1["job_id"]) == [high.id, low.id]
    assert hd(listed.result["applications"])["band"] == "labs"

    boxes = tool_call("list_letterboxes", %{"min_score" => 50})

    assert Enum.map(boxes.result["letterboxes"], & &1["job_id"]) == [high.id]

    rec = tool_call("recommend_applications", %{"limit" => 1})

    assert rec.result["fire"] == "hold"
    assert Enum.map(rec.result["applications"], & &1["job_id"]) == [high.id]

    {:ok, handle} = Letterbox.lease(Letterbox.for_job(low.id).id, self())

    set = tool_call(handle, "set_score", %{"score" => 88})

    assert set.result == %{"job_id" => low.id, "score_100" => 88, "band" => "big_tech"}

    bad = tool_call(handle, "set_score", %{"score" => 101})

    assert bad.error.message == "bad argument score"
    assert Letterbox.release(handle) == :ok
  end
end
