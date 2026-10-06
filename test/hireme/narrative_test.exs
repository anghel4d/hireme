defmodule Hireme.NarrativeTest do
  use Hireme.DataCase, async: false

  alias Hireme.Corpus.Narrative, as: Row
  alias Hireme.Narrative
  alias Hireme.Repo

  test "read and update the private blob, and keep it off an application" do
    user = Narrative.create_user!(%{name: "Sample Candidate", email: "candidate@example.test"})
    row = Narrative.write!(user, "A private working note.")

    assert row.version == 1
    assert row.private
    assert Narrative.get_by_user(user.id).body == "A private working note."
    assert Narrative.for_application(row) == nil

    updated = Narrative.update!(row, "Edited private note.")
    assert updated.version == 2
    assert updated.body == "Edited private note."
    assert DateTime.compare(updated.updated_at, row.updated_at) != :lt

    assert {:ok, _} = Narrative.delete(updated)
    refute Repo.get(Row, row.id)
  end
end
