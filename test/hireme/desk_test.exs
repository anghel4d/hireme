defmodule Hireme.DeskTest do
  use Hireme.DataCase, async: false
  import Hireme.Fixtures

  alias Hireme.Desk
  alias Hireme.Desk.Batch
  alias Hireme.Repo

  test "a bare opening returns the persisted row and its newly stored lineage theme" do
    profile = profile()
    item(profile, %{body: "Elixir systems"})

    added =
      job(profile, %{
        company: "New themed employer",
        listing: "databases",
        theme: %{targets: ["elixir", "databases"]},
        stage_notes: %{discovered: "Ready for review"}
      })

    assert added == Repo.get!(Hireme.Desk.Job, added.id)
    assert Enum.find(Desk.rail(added), &(&1.key == :discovered)).note == "Ready for review"
    variant = Repo.get_by!(Hireme.Desk.Variant, job_app_id: added.id)
    assert Repo.get!(Hireme.Cv.Lineage, variant.lineage_id).theme == variant.theme
    assert Hireme.Theme.parse(variant.theme).targets == ["elixir", "databases"]
    assert Hireme.CvPair.job_id(Hireme.CvPair.bind!(added.id)) == added.id
  end

  test "a bare opening inherits shared masks and lineage targets without rewriting a leased sibling" do
    profile = profile()
    altered = item(profile, %{body: "Original wording"})
    hidden = item(profile, %{body: "Theatre"})
    emphasized = item(profile, %{body: "Systems"})

    first =
      job(profile, %{
        company: "Inherited employer",
        theme: %{targets: ["elixir", "theatre", "systems"]},
        overlays: [
          %{item_id: altered.id, mode: :altered, body: "Elixir"},
          %{item_id: hidden.id, mode: :hidden},
          %{item_id: emphasized.id, mode: :emphasized}
        ]
      })

    {{:ok, _block, _}, lease} = hold_lease(first.id)

    try do
      added =
        job(profile, %{
          company: "Inherited employer",
          listing: "unmatched",
          theme: %{targets: ["unmatched"]}
        })

      assert added == Repo.get!(Hireme.Desk.Job, added.id)
      assert Repo.get!(Hireme.Desk.Job, first.id) == first
      pair = Hireme.CvPair.bind!(added.id)
      original_pair = Hireme.CvPair.bind!(first.id)
      assert Hireme.CvPair.lineage_id(pair) == Hireme.CvPair.lineage_id(original_pair)
      assert Hireme.CvPair.variant_id(pair) != Hireme.CvPair.variant_id(original_pair)
      assert {:error, :leased} = Desk.put_overlay(first.id, altered.id, %{mode: :hidden})
    after
      let_go(lease)
    end
  end

  test "bare openings remain tenant scoped even for the same employer name" do
    profile = profile()
    own_item = item(profile, %{body: "Elixir"})

    own =
      job(profile, %{
        company: "Tenant employer",
        overlays: [%{item_id: own_item.id, mode: :hidden}]
      })

    other = Hireme.Accounts.create!(%{name: "Creation tenant"})

    foreign =
      Repo.with_account(other.id, fn ->
        other_profile = profile()
        item(other_profile, %{body: "Elixir"})
        added = job(other_profile, %{company: "Tenant employer", theme: %{targets: ["elixir"]}})
        assert added == Repo.get!(Hireme.Desk.Job, added.id)
        assert overlays_on(added) == 0
        added
      end)

    refute own.employer_id == foreign.employer_id
    assert overlays_on(own) == 1
    assert Repo.get(Hireme.Desk.Job, foreign.id) == nil
  end

  test "an opening casts wire strings once and refuses an unknown stage" do
    profile = profile()

    assert {:ok, job} =
             Desk.create_job(%{
               profile_id: profile.id,
               company: "Cast Co",
               role: "Engineer",
               stage: "gated",
               freshness: "open",
               gate: :pursue
             })

    assert job.current_stage == :gated
    assert job.freshness == :open
    assert job.pips == "DDAPPPPPPP"

    assert {:error, %Ecto.Changeset{}} =
             Desk.create_job(%{
               profile_id: profile.id,
               company: "Cast Co",
               role: "x",
               stage: "sent"
             })

    assert {:ok, _} = Hireme.Ops.exec({:note, job.id, :gated, "Pursue: strong fit"})
    noted = Repo.get!(Hireme.Desk.Job, job.id)
    assert Enum.find(Desk.rail(noted), &(&1.key == :gated)).note == "Pursue: strong fit"
  end

  test "a submit stays locked until that batch is named open fire" do
    {:ok, batch} =
      %Batch{}
      |> Batch.changeset(%{code: "Batch-001", ordinal: 1, status: :fire_ready, fire: :hold})
      |> Repo.insert()

    job = job(profile(), %{company: "Keel Systems", stage: "fire_ready", batch_id: batch.id})

    assert {:error, :fire_hold} = Desk.set_stage(job.id, :submitted)
    assert {:error, :fire_hold} = Desk.set_stage(job.id, :open_fire)
    assert {:ok, _} = Hireme.Ops.exec({:open_fire, "Batch-001"})
    assert {:ok, moved} = Desk.set_stage(job.id, :submitted)
    assert moved.current_stage == :submitted
  end

  defp overlays_on(job) do
    lineage = Hireme.CvPair.lineage_id(Hireme.CvPair.bind!(job.id))
    Repo.aggregate(from(o in Hireme.Desk.Overlay, where: o.lineage_id == ^lineage), :count)
  end

  test "applications are numbered from 1 per account, and a number is never handed out again" do
    p = profile()
    [a, b, c] = for n <- 1..3, do: job(p, %{company: "No #{n}"})
    assert Enum.map([a, b, c], & &1.no) == [1, 2, 3]

    Repo.delete!(c)
    assert job(p, %{company: "No 4"}).no == 4

    other = Hireme.Accounts.create!(%{name: "Numbered elsewhere"})
    assert Repo.with_account(other.id, fn -> job(profile(), %{company: "Theirs"}).no end) == 1
  end
end
