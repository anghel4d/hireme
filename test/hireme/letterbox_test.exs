defmodule Hireme.LetterboxTest do
  use Hireme.DataCase, async: false

  alias Hireme.Corpus
  alias Hireme.Desk
  alias Hireme.Letterbox
  alias Hireme.Letterbox.Handle

  test "one producer cannot hold two leases" do
    first = open_job("North Co")
    second = open_job("South Co")

    assert {:ok, %Handle{}} = Letterbox.lease(first.letterbox_id, self())
    assert {:error, :one_lease} = Letterbox.lease(second.letterbox_id, self())
  end

  test "another producer cannot lease the same letterbox or the same employer CV" do
    first = open_job("North Co")
    sibling = open_job("North Co")
    assert {:ok, handle} = Letterbox.lease(first.letterbox_id, self())

    busy =
      Task.async(fn ->
        Letterbox.lease(first.letterbox_id, self())
      end)

    assert {:error, :busy} = Task.await(busy)

    lineage =
      Task.async(fn ->
        Letterbox.lease(sibling.letterbox_id, self())
      end)

    assert {:error, :lineage_busy} = Task.await(lineage)

    task =
      Task.async(fn ->
        Letterbox.command(handle, :get)
      end)

    assert {:error, :lease} = Task.await(task)

    forged = %{handle | token: make_ref()}
    assert {:error, :lease} = Letterbox.command(forged, :get)
    assert Letterbox.release(handle) == :ok
  end

  test "the desk refuses a write while an agent holds the lease" do
    %{job: job, letterbox_id: letterbox_id} = open_job("Held Co")
    assert {:ok, handle} = Letterbox.lease(letterbox_id, self())
    assert {:error, :leased} = Desk.set_stage(job.id, :freshness)
    assert Letterbox.release(handle) == :ok
    assert {:ok, moved} = Desk.set_stage(job.id, :freshness)
    assert moved.current_stage == :freshness
  end

  defp open_job(company) do
    profile =
      Corpus.create_profile!(%{
        slug: "candidate-#{System.unique_integer([:positive])}",
        name: "Sample Candidate",
        headline: "Engineer",
        summary: "A sample profile."
      })

    job =
      Desk.create_job!(%{
        profile_id: profile.id,
        company: company,
        role: "Engineer",
        stage: "discovered",
        canonical_url: "https://jobs.example.test/#{System.unique_integer([:positive])}"
      })

    %{job: job, letterbox_id: Letterbox.for_job(job.id).id}
  end
end
