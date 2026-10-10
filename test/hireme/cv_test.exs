defmodule Hireme.CvTest do
  use Hireme.DataCase, async: false
  import Hireme.Fixtures

  import Ecto.Query, only: [from: 2]

  alias Hireme.Cv.Lineage
  alias Hireme.CvPair
  alias Hireme.CvPair.JobId
  alias Hireme.Desk
  alias Hireme.Desk.Overlay
  alias Hireme.Repo
  alias Hireme.Theme

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

    refute Enum.any?(overlays_of(second), &(&1.body in ["North only", "stolen"]))
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

    assert Enum.any?(overlays_of(second), &(&1.body == "Shared"))
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

    overlays = overlays_of(first)
    assert Enum.any?(overlays, &(&1.body == "Original"))
    refute Enum.any?(overlays, &(&1.body == "Replaced"))
    assert Enum.any?(overlays, &(&1.item_id == added.id and &1.mode == :emphasized))
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
    assert Enum.any?(overlays_of(additive), &(&1.body == "Original"))
  end

  test "a theme parses once from loose keys and round-trips through storage" do
    theme =
      Theme.parse(%{"lead" => " Lead line ", "accent" => "signal", :targets => ["ecs", " "]})

    assert theme.lead == "Lead line"
    assert theme.accent == :signal
    assert theme.density == :cv
    assert theme.targets == ["ecs"]
    assert Theme.parse(Theme.to_map(theme)) == theme

    assert Theme.parse(%{"accent" => "neon", "density" => 3}) == %Theme{}
    assert Theme.empty?(Theme.parse(nil))
  end

  # The overlays an application's CV shows: those on its lineage.
  defp overlays_of(job) do
    lineage = CvPair.lineage_id(CvPair.bind!(job.id))
    Repo.all(from o in Overlay, where: o.lineage_id == ^lineage)
  end
end
