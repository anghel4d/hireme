defmodule Hireme.NarrativeTest do
  use Hireme.DataCase, async: false

  alias Hireme.Corpus.Narrative, as: Row
  alias Hireme.Narrative
  alias Hireme.Repo

  test "read and update the private blob, and keep it off an application" do
    user = Narrative.create_user!(%{name: "Matei Anghel", email: "matei3d@gmail.com"})
    row = Narrative.write!(user, Narrative.seed_body())

    assert row.version == 1
    assert row.private
    assert Narrative.get_by_user(user.id).body =~ "end of 2030"
    assert Narrative.get_by_user(user.id).body =~ "computational linear algebra"
    assert Narrative.for_application(row) == nil

    updated = Narrative.update!(row, "Edited vector. Frontier labs stay the target.")
    assert updated.version == 2
    assert updated.body =~ "Edited vector"
    assert DateTime.compare(updated.updated_at, row.updated_at) != :lt

    assert {:ok, _} = Narrative.delete(updated)
    refute Repo.get(Row, row.id)
  end
end
