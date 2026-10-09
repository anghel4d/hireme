defmodule Hireme.TenancyTest do
  use Hireme.DataCase, async: false
  import Hireme.Fixtures

  alias Hireme.Desk
  alias Hireme.Desk.Filters
  alias Hireme.Desk.Job
  alias Hireme.Letterbox
  alias Hireme.Repo

  test "one account's rows do not exist for another" do
    job = job(profile(), %{company: "Mine Co"})
    assert [%{id: id}] = Desk.list_cards(%Filters{status: :all})
    assert id == job.id

    Hireme.DataCase.open_account("Other desk")
    assert Desk.list_cards(%Filters{status: :all}) == []
    assert Desk.focus(job.id) == nil
    assert Repo.get(Job, job.id) == nil
    assert {:error, :not_found} = Letterbox.claim(job.id)
  end

  test "a read with no account on the process is refused, and so is a write" do
    Repo.put_account(nil)
    assert_raise ArgumentError, ~r/no account on the process/, fn -> Repo.all(Job) end

    assert_raise Ecto.InvalidChangesetError, fn ->
      Hireme.Corpus.create_profile!(%{slug: "x", name: "X", headline: "h", summary: "s"})
    end
  end

  test "the account comes from the process, never from the attributes" do
    other = Hireme.Accounts.create!(%{name: "Other desk"})

    profile =
      Hireme.Corpus.create_profile!(%{
        slug: "p",
        name: "P",
        headline: "h",
        summary: "s",
        account_id: other.id
      })

    assert profile.account_id == Repo.account_id!()
  end
end
