defmodule Hireme.CvTest do
  use Hireme.DataCase, async: false

  alias Hireme.Corpus
  alias Hireme.Cv.Lineage
  alias Hireme.CvPair
  alias Hireme.CvPair.JobId
  alias Hireme.Desk
  alias Hireme.Repo

  test "a CV pair cannot be aimed at another application" do
    profile = profile()
    item = item(profile)
    first = job(profile, "North Co")
    second = job(profile, "South Co")

    assert {:ok, _} =
             CvPair.tailor(CvPair.bind!(first.id), item.id, %{mode: :altered, body: "North only"})

    north = CvPair.bind!(first.id)

    forged = %CvPair{
      job_id: JobId.new(second.id),
      variant_id: north.variant_id,
      employer_id: north.employer_id,
      lineage_id: north.lineage_id
    }

    assert {:error, :cv_mismatch} =
             CvPair.tailor(forged, item.id, %{mode: :altered, body: "stolen"})

    south = Desk.focus(second.id)
    refute Enum.any?(south.masks, &(&1.body == "North only"))
    refute Enum.any?(south.masks, &(&1.body == "stolen"))
  end

  test "one employer has one lineage, so two applications share that CV" do
    profile = profile()
    item = item(profile)
    first = job(profile, "Same Co")
    second = job(profile, "Same Co")

    assert CvPair.lineage_id(CvPair.bind!(first.id)) == CvPair.lineage_id(CvPair.bind!(second.id))
    assert CvPair.variant_id(CvPair.bind!(first.id)) != CvPair.variant_id(CvPair.bind!(second.id))

    assert {:ok, _} =
             CvPair.tailor(CvPair.bind!(first.id), item.id, %{mode: :altered, body: "Shared"})

    focus = Desk.focus(second.id)
    assert Enum.any?(focus.masks, &(&1.body == "Shared"))
  end

  test "the database rejects a variant pointed at another employer's lineage" do
    profile = profile()
    first = job(profile, "North Co")
    second = job(profile, "South Co")
    foreign = CvPair.lineage_id(CvPair.bind!(second.id))

    assert_raise Exqlite.Error, ~r/cv lineage employer mismatch/, fn ->
      Repo.query!("UPDATE cv_variants SET lineage_id = ? WHERE job_app_id = ?", [
        foreign,
        first.id
      ])
    end
  end

  test "after the cooldown, a re-attempt can add a line and cannot rewrite one" do
    profile = profile()
    kept = item(profile, "exp.kept")
    added = item(profile, "exp.added")
    first = job(profile, "Same Co")

    assert {:ok, _} =
             CvPair.tailor(CvPair.bind!(first.id), kept.id, %{mode: :altered, body: "Original"})

    lineage = Repo.get_by!(Lineage, employer_id: CvPair.employer_id(CvPair.bind!(first.id)))
    past = Date.add(Date.utc_today(), -(CvPair.cooldown_days() + 1))
    lineage |> Ecto.Changeset.change(%{opened_on: past}) |> Repo.update!()

    assert {:error, :cooldown} =
             CvPair.tailor(CvPair.bind!(first.id), added.id, %{mode: :emphasized})

    assert {:ok, _} = CvPair.open_generation(lineage.employer_id)

    assert {:error, :not_additive} =
             CvPair.tailor(CvPair.bind!(first.id), kept.id, %{mode: :altered, body: "Replaced"})

    assert {:ok, _} = CvPair.tailor(CvPair.bind!(first.id), added.id, %{mode: :emphasized})

    focus = Desk.focus(first.id)
    assert Enum.any?(focus.masks, &(&1.body == "Original"))
    refute Enum.any?(focus.masks, &(&1.body == "Replaced"))
    assert Enum.any?(focus.masks, &(&1.id == added.id and &1.mode == :emphasized))
  end

  defp profile do
    Corpus.create_profile!(%{
      slug: "candidate-#{System.unique_integer([:positive])}",
      name: "Sample Candidate",
      headline: "Engineer",
      summary: "A sample profile."
    })
  end

  defp item(profile, key \\ "exp.one") do
    Corpus.create_item!(%{
      profile_id: profile.id,
      kind: :experience,
      key: key <> Integer.to_string(System.unique_integer([:positive])),
      title: "Line",
      body: "Root line",
      position: 1
    })
  end

  defp job(profile, company) do
    Desk.create_job!(%{
      profile_id: profile.id,
      company: company,
      role: "Engineer",
      stage: "discovered",
      canonical_url: "https://jobs.example.test/#{System.unique_integer([:positive])}"
    })
  end
end
