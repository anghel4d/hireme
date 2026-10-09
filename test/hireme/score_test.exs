defmodule Hireme.ScoreTest do
  use Hireme.DataCase, async: false
  import Hireme.Fixtures

  alias Hireme.Desk.Job
  alias Hireme.Import
  alias Hireme.Repo

  test "a pack's score_100 lands on the row, and a re-import without one keeps it" do
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

    scores = Repo.all(Job) |> Map.new(&{&1.company, &1.score_100})

    assert Map.take(scores, ["Middling Co", "Titan Labs", "High Co"]) ==
             %{"Middling Co" => 70, "Titan Labs" => 100, "High Co" => 92}

    assert scores["Plain Co"] in 0..100

    other = Hireme.Accounts.create!(%{name: "Other score account"})
    assert Hireme.Repo.with_account(other.id, fn -> Repo.all(Job) end) == []

    # A re-import without a score keeps the one on the row.
    again =
      ~s({"apps":[{"company":"Titan Labs","role":"Engineer","url":"https://jobs.example.test/titan"}]})

    assert {:ok, _} = Import.import_body(again, "again.json", profile)
    assert Repo.get_by!(Job, company: "Titan Labs").score_100 == 100
  end
end
