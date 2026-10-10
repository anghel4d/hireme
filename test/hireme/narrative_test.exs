defmodule Hireme.NarrativeTest do
  use Hireme.DataCase, async: false

  alias Hireme.Narrative

  test "read and update the private blob" do
    user = Narrative.create_user!(%{name: "Sample Candidate", email: "candidate@example.test"})
    row = Narrative.write!(user, "A private working note.")

    assert row.version == 1
    assert row.private
    assert Narrative.get_by_user(user.id).body == "A private working note."

    updated = Narrative.update!(row, "Edited private note.")
    assert updated.version == 2
    assert updated.body == "Edited private note."
    assert DateTime.compare(updated.updated_at, row.updated_at) != :lt
  end
end
