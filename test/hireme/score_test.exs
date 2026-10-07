defmodule Hireme.ScoreTest do
  use Hireme.DataCase, async: false

  alias Hireme.Campaign
  alias Hireme.Corpus
  alias Hireme.Desk
  alias Hireme.Desk.Filters
  alias Hireme.Import
  alias Hireme.Letterbox
  alias Hireme.Mcp
  alias Hireme.Score

  test "bands are closed, ordered, and inverse to their floors" do
    assert Score.band(100) == :titan
    assert Score.band(99) == :high
    assert Score.band(85) == :strong
    assert Score.band(84) == :middle
    assert Score.band(0) == :low
    assert Score.band(nil) == :unscored

    for band <- Score.bands(), floor = Score.floor(band) do
      assert Score.band(floor) == band
    end

    assert {:ok, 67} = Score.parse("67")
    assert {:ok, 67} = Score.parse(66.6)
    assert {:ok, nil} = Score.parse("")
    assert :error = Score.parse(101)
    assert :error = Score.parse("high")

    assert Score.histogram([100, 92, nil, 70]) ==
             [titan: 1, high: 1, strong: 0, middle: 1, low: 0, unscored: 1]
  end

  test "the board sorts a batch by score, filters by floor and band, and counts bands" do
    profile = profile()

    pack = """
    {"batch":"Batch-009","status":"draft_prep","fire":"hold","apps":[
      {"company":"Middling Co","role":"Engineer","url":"https://jobs.example.test/mid","score_100":70,"stage":"gated"},
      {"company":"Titan Labs","role":"Engineer","url":"https://jobs.example.test/titan","score_100":100,"stage":"discovered"},
      {"company":"High Co","role":"Engineer","url":"https://jobs.example.test/high","score":92,"stage":"gated"},
      {"company":"Unscored Co","role":"Engineer","url":"https://jobs.example.test/none","stage":"gated"}
    ]}
    """

    assert {:ok, %{count: 4}} = Import.import_body(pack, "batch-009.json", profile)

    all = Desk.list_cards(%Filters{status: :all})
    assert Enum.map(all, & &1.company) == ["Titan Labs", "High Co", "Middling Co", "Unscored Co"]

    assert Desk.list_cards(%Filters{status: :all, min: 90}) |> Enum.map(& &1.score) == [100, 92]

    assert Desk.list_cards(%Filters{status: :all, band: :middle}) |> Enum.map(& &1.company) == [
             "Middling Co"
           ]

    assert Desk.list_cards(%Filters{status: :all, band: :unscored}) |> Enum.map(& &1.company) == [
             "Unscored Co"
           ]

    assert Campaign.scoreboard().bands ==
             [titan: 1, high: 1, strong: 0, middle: 1, low: 0, unscored: 1]

    filters = Filters.from_params(%{"min" => "85", "band" => "weird"})
    assert filters.min == 85
    assert filters.band == :all
    assert Filters.to_query(filters) == %{"min" => "85"}

    # A re-import without a score keeps the one on the card.
    again =
      ~s({"apps":[{"company":"Titan Labs","role":"Engineer","url":"https://jobs.example.test/titan"}]})

    assert {:ok, _} = Import.import_body(again, "again.json", profile)
    assert [%{score: 100}] = Desk.list_cards(%Filters{status: :all, band: :titan})
  end

  test "the directory ranks by score and a lease can set its own" do
    profile = profile()

    low =
      Desk.create_job!(%{
        profile_id: profile.id,
        company: "Low Co",
        role: "Engineer",
        score: 40,
        canonical_url: "https://jobs.example.test/low"
      })

    high =
      Desk.create_job!(%{
        profile_id: profile.id,
        company: "High Co",
        role: "Engineer",
        score: "95",
        canonical_url: "https://jobs.example.test/high"
      })

    assert {:error, {:score, 140}} =
             Desk.create_job(%{profile_id: profile.id, company: "Bad", role: "x", score: 140})

    listed =
      Mcp.directory(%{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "list_applications", "arguments" => %{"status" => "all"}}
      })

    assert Enum.map(listed.result["applications"], & &1["job_id"]) == [high.id, low.id]
    assert hd(listed.result["applications"])["band"] == "high"

    boxes =
      Mcp.directory(%{
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => "list_letterboxes", "arguments" => %{"min_score" => 50}}
      })

    assert Enum.map(boxes.result["letterboxes"], & &1["job_id"]) == [high.id]

    bands =
      Mcp.directory(%{
        "id" => 3,
        "method" => "tools/call",
        "params" => %{"name" => "score_bands"}
      })

    assert Enum.find(bands.result["bands"], &(&1["band"] == "high"))["count"] == 1

    {:ok, handle} = Letterbox.lease(Letterbox.for_job(low.id).id, self())

    set =
      Mcp.handle(handle, %{
        "id" => 4,
        "method" => "tools/call",
        "params" => %{"name" => "set_score", "arguments" => %{"score" => 88}}
      })

    assert set.result == %{"job_id" => low.id, "score" => 88, "band" => "strong"}

    bad =
      Mcp.handle(handle, %{
        "id" => 5,
        "method" => "tools/call",
        "params" => %{"name" => "set_score", "arguments" => %{"score" => 101}}
      })

    assert bad.error.message == "bad argument score"
    assert Letterbox.release(handle) == :ok
  end

  defp profile do
    Corpus.create_profile!(%{
      slug: "scored-#{System.unique_integer([:positive])}",
      name: "Sample Candidate",
      headline: "Engineer",
      summary: "A sample profile."
    })
  end
end
