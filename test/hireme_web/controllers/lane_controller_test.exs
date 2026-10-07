defmodule HiremeWeb.LaneControllerTest do
  use HiremeWeb.ConnCase, async: false

  alias Hireme.Corpus
  alias Hireme.Desk

  test "lanes read as one document and each write answers with the refreshed lanes", %{conn: conn} do
    lanes = conn |> get("/api/lanes") |> json_response(200)
    assert lanes["gym"]["solved_today"] == 0
    assert is_list(lanes["gym"]["platforms"])
    assert lanes["net"]["recent"] == []
    assert Map.has_key?(lanes["heat"], "companies")

    logged =
      conn
      |> post("/api/gym/log", %{
        platform: "leetcode",
        title: "Two Sum",
        slug: "two-sum",
        topic: "arrays",
        difficulty: "easy",
        outcome: "solved",
        minutes: "12"
      })
      |> json_response(200)

    assert logged["gym"]["solved_today"] == 1
    assert [%{"title" => "Two Sum", "platform" => "LeetCode"}] = logged["gym"]["recent"]

    assert %{"error" => "Need a title."} =
             conn |> post("/api/gym/log", %{platform: "leetcode"}) |> json_response(400)

    assert %{"error" => "Daily target is 1–30."} =
             conn |> post("/api/gym/target", %{target: "99"}) |> json_response(400)

    assert %{"gym" => %{"target" => 5}} =
             conn |> post("/api/gym/target", %{target: "5"}) |> json_response(200)

    shipped =
      conn
      |> post("/api/net/log", %{
        kind: "post",
        channel: "x",
        title: "On columns",
        url: "https://example.test/p"
      })
      |> json_response(200)

    assert shipped["net"]["shipped_week"] == 1

    assert %{"net" => %{"lane" => "https://observer.example.test/"}} =
             conn
             |> post("/api/net/lane", %{url: "https://observer.example.test/"})
             |> json_response(200)
  end

  test "the packet carries a heat column and a focus carries the verdict", %{conn: conn} do
    profile =
      Corpus.create_profile!(%{
        slug: "heat",
        name: "Heat",
        headline: "Runtime",
        summary: "Plain data."
      })

    job =
      Desk.create_job!(%{
        profile_id: profile.id,
        company: "Keel Systems",
        role: "Runtime engineer",
        canonical_url: "https://jobs.example.test/keel"
      })

    <<"HDP1", header_len::little-32, rest::binary>> = conn |> get("/api/pack") |> response(200)
    <<header::binary-size(^header_len), _::binary>> = rest
    directory = Jason.decode!(header)
    assert directory["tables"]["heat_states"] == ["cool", "warm", "hot", "blocked"]
    assert Enum.any?(directory["columns"], &(&1["name"] == "heat_state"))

    focus = conn |> get("/api/focus/#{job.id}") |> json_response(200)
    assert focus["heat"]["decision"] in ["allow", "defer"]
    assert focus["heat"]["override"] == false

    assert %{"error" => "HEAT override needs a written reason."} =
             conn
             |> post("/api/jobs/#{job.id}/heat_override", %{reason: "  "})
             |> json_response(400)

    overridden =
      conn
      |> post("/api/jobs/#{job.id}/heat_override", %{reason: "Named by hand."})
      |> json_response(200)

    assert overridden["focus"]["heat"]["override"] == true
    assert overridden["focus"]["heat"]["override_reason"] == "Named by hand."
  end
end
