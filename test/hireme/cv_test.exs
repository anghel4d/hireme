defmodule Hireme.CvTest do
  use Hireme.DataCase, async: false
  import Hireme.Fixtures

  alias Hireme.Cv.Lineage
  alias Hireme.CvPair
  alias Hireme.CvPair.JobId
  alias Hireme.Desk
  alias Hireme.Repo

  test "a CV pair cannot be aimed at another application" do
    profile = profile()
    item = item(profile)
    first = job(profile, %{company: "North Co"})
    second = job(profile, %{company: "South Co"})

    assert {:ok, _} =
             CvPair.tailor(CvPair.bind!(first.id), item.id, %{mode: :altered, body: "North only"})

    north = CvPair.bind!(first.id)
    forged = %CvPair{north | job_id: JobId.new(second.id)}

    assert {:error, :cv_mismatch} =
             CvPair.tailor(forged, item.id, %{mode: :altered, body: "stolen"})

    south = Desk.focus(second.id)
    refute Enum.any?(south.masks, &(&1.body == "North only"))
    refute Enum.any?(south.masks, &(&1.body == "stolen"))
  end

  test "one employer has one lineage, so two applications share that CV" do
    profile = profile()
    item = item(profile)
    first = job(profile, %{company: "Same Co"})
    second = job(profile, %{company: "Same Co"})

    assert CvPair.lineage_id(CvPair.bind!(first.id)) == CvPair.lineage_id(CvPair.bind!(second.id))
    assert CvPair.variant_id(CvPair.bind!(first.id)) != CvPair.variant_id(CvPair.bind!(second.id))

    assert {:ok, _} =
             CvPair.tailor(CvPair.bind!(first.id), item.id, %{mode: :altered, body: "Shared"})

    assert Enum.any?(Desk.focus(second.id).masks, &(&1.body == "Shared"))
  end

  test "the database rejects a variant pointed at another employer's lineage" do
    profile = profile()
    first = job(profile, %{company: "North Co"})
    second = job(profile, %{company: "South Co"})
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
    kept = item(profile)
    added = item(profile)
    first = job(profile, %{company: "Same Co"})

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

  test "creation keeps inherited masks through cooldown and rejects non-additive opening overlays" do
    profile = profile()
    kept = item(profile, %{body: "Canonical"})

    first =
      job(profile, %{
        company: "Creation cooldown",
        theme: %{targets: ["original"]},
        overlays: [%{item_id: kept.id, mode: :altered, body: "Original"}]
      })

    pair = CvPair.bind!(first.id)
    lineage = Repo.get!(Lineage, CvPair.lineage_id(pair))
    past = Date.add(Date.utc_today(), -(CvPair.cooldown_days() + 1))
    lineage |> Ecto.Changeset.change(opened_on: past) |> Repo.update!()

    attrs = %{profile_id: profile.id, company: first.company, role: "Retry"}
    assert {:ok, bare} = Desk.create_job(attrs)
    assert bare == Repo.get!(Hireme.Desk.Job, bare.id)
    assert CvPair.lineage_id(CvPair.bind!(bare.id)) == lineage.id

    changed = Map.put(attrs, :overlays, [%{item_id: kept.id, mode: :hidden}])
    count = Repo.aggregate(Hireme.Desk.Job, :count)
    assert {:error, :cooldown} = Desk.create_job(changed)
    assert Repo.aggregate(Hireme.Desk.Job, :count) == count
    assert {:ok, _} = CvPair.open_generation(first.employer_id)
    assert {:error, :not_additive} = Desk.create_job(changed)
    assert Repo.aggregate(Hireme.Desk.Job, :count) == count
    assert {:ok, additive} = Desk.create_job(attrs)
    assert additive == Repo.get!(Hireme.Desk.Job, additive.id)
    assert Enum.any?(Desk.focus(additive.id).masks, &(&1.body == "Original"))
  end
end
