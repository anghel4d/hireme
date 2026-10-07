defmodule HiremeWeb.DeskControllerTest do
  use HiremeWeb.ConnCase, async: false

  alias Hireme.Corpus
  alias Hireme.Desk
  alias Hireme.Desk.Batch
  alias Hireme.Desk.Packet
  alias Hireme.Repo

  test "the packet is HDP1 with a directory, and its columns are the board", %{conn: conn} do
    {job, _experience, _education} = sample_job()

    conn = get(conn, "/api/pack")
    assert response_content_type(conn, :"vnd.hireme.desk-packet") =~ "desk-packet"
    <<"HDP1", header_len::little-32, rest::binary>> = response(conn, 200)
    <<header::binary-size(^header_len), _::binary>> = rest
    pad = rem(4 - rem(header_len, 4), 4)
    body = binary_part(rest, header_len + pad, byte_size(rest) - header_len - pad)

    directory = Jason.decode!(header)
    assert directory["n"] == 1
    assert Enum.map(directory["tables"]["stages"], & &1["key"]) |> hd() == "discovered"
    assert Enum.any?(directory["tables"]["bands"], &(&1["key"] == "frontier"))

    col = fn name -> Enum.find(directory["columns"], &(&1["name"] == name)) end
    assert <<id::little-32>> = binary_part(body, col.("id")["at"], 4)
    assert id == job.id
    assert <<score::little-32>> = binary_part(body, col.("score")["at"], 4)
    assert score == job.score_100
    assert <<stage::little-32>> = binary_part(body, col.("stage")["at"], 4)
    assert stage == 5

    company = col.("company")

    <<first::little-32, last::little-32, text::binary>> =
      binary_part(body, company["at"], company["size"])

    assert binary_part(text, first, last - first) == "Lumen Field"

    assert IO.iodata_to_binary(Packet.build()) == response(conn, 200)
  end

  test "focus is the opened application and writes come back as the new focus", %{conn: conn} do
    {job, experience, _education} = sample_job()

    focus = conn |> get("/api/focus/#{job.id}") |> json_response(200)
    assert focus["job"]["company"] == "Lumen Field"
    assert focus["job"]["stage"] == "fire_ready"
    assert length(focus["rail"]) == 10
    assert Enum.any?(focus["cv"]["hidden"], &(&1["body"] == "Theatre elective."))
    assert focus["coverage"]["hits"] == ["ecs"]

    assert %{"error" => "not found"} = conn |> get("/api/focus/999999") |> json_response(404)

    restored =
      conn
      |> post("/api/jobs/#{job.id}/overlay", %{item_id: experience.id, mode: "inherit"})
      |> json_response(200)

    refute Enum.any?(restored["focus"]["masks"], &(&1["id"] == experience.id))

    assert %{"error" => "bad argument mode"} =
             conn
             |> post("/api/jobs/#{job.id}/overlay", %{item_id: experience.id, mode: "loud"})
             |> json_response(400)

    noted =
      conn
      |> post("/api/jobs/#{job.id}/note", %{stage: "fire_ready", note: "Packed."})
      |> json_response(200)

    assert Enum.find(noted["focus"]["rail"], &(&1["key"] == "fire_ready"))["note"] == "Packed."

    assert %{"error" => "bad argument stage"} =
             conn |> post("/api/jobs/#{job.id}/stage", %{stage: "sent"}) |> json_response(400)
  end

  test "a submit is refused with 409 until the batch is named open fire", %{conn: conn} do
    profile = profile()

    {:ok, batch} =
      %Batch{}
      |> Batch.changeset(%{code: "Batch-001", ordinal: 1, status: :fire_ready, fire: :hold})
      |> Repo.insert()

    job =
      Desk.create_job!(%{
        profile_id: profile.id,
        company: "Keel Systems",
        role: "Runtime engineer",
        stage: "fire_ready",
        batch_id: batch.id,
        canonical_url: "https://jobs.example.test/keel"
      })

    assert %{"error" => "fire_hold"} =
             conn
             |> post("/api/jobs/#{job.id}/stage", %{stage: "submitted"})
             |> json_response(409)

    assert %{"ok" => true} =
             conn |> post("/api/batches/Batch-001/open_fire", %{}) |> json_response(200)

    moved = conn |> post("/api/jobs/#{job.id}/stage", %{stage: "submitted"}) |> json_response(200)
    assert moved["focus"]["job"]["stage"] == "submitted"

    board = conn |> get("/api/scoreboard") |> json_response(200)
    assert board["fire"] == "open_fire"
    assert Enum.any?(board["chart"]["bands"], &(&1["key"] == "systems"))
  end

  test "the page hosts the shell and the root view reads a profile", %{conn: conn} do
    profile = profile()
    html = conn |> get("/") |> html_response(200)
    assert html =~ ~s(<div id="desk" class="desk"></div>)
    assert html =~ "/assets/js/app.js"

    root = conn |> get("/api/root/#{profile.id}") |> json_response(200)
    assert root["cv"]["label"] == "Root"
    assert root["profile"]["slug"] == "systems"
  end

  defp profile do
    Corpus.create_profile!(%{
      slug: "systems",
      name: "Systems",
      headline: "Runtime",
      summary: "Plain data."
    })
  end

  defp sample_job do
    profile = profile()

    experience =
      Corpus.create_item!(%{
        profile_id: profile.id,
        kind: :experience,
        key: "exp.tick",
        title: "Engineer",
        body: "An entity store laid out as structure-of-arrays.",
        org: "Northwind",
        span: "2023 — 2026",
        position: 1
      })

    education =
      Corpus.create_item!(%{
        profile_id: profile.id,
        kind: :education,
        key: "edu.general",
        title: "DEC",
        body: "Theatre elective.",
        position: 2
      })

    job =
      Desk.create_job!(%{
        profile_id: profile.id,
        company: "Lumen Field",
        role: "Runtime engineer",
        stage: "fire_ready",
        heat: 5,
        theme: %{"targets" => ["ecs", "theatre"]},
        overlays: [
          %{
            item_id: experience.id,
            mode: :altered,
            body: "A columnar ECS.",
            reason: "their word"
          },
          %{item_id: education.id, mode: :hidden, reason: "noise"}
        ]
      })

    {job, experience, education}
  end
end
