defmodule Hireme.Narrative do
  @moduledoc """
  Read and revise the candidate's private narrative.

  The blob is one row per user. Each save bumps `version` and `updated_at`.
  It stays off application export while private.
  """

  alias Hireme.Corpus.Narrative, as: Row
  alias Hireme.Corpus.User
  alias Hireme.Repo

  @seed """
  The vector is frontier labs by the end of 2030.

  Founders and titans are not the same age curve. The founders worth studying are young relative to the titans they get measured against, and the clock is the point. I am not arranging a mid-career impression. I am spending the years between now and that date on purpose.

  The bridge is computational linear algebra, done in batches. DESERT STORM is that bridge: volume, variety, and a hard filter. Mid-curve shops are the filter, not the destination. A role that does not move the linear-algebra and systems depth toward a frontier lab is a skip.

  Life plans fold into the same vector. Remote and relocation are tactics. Canada and Romania are the legal base. Anoptic is the depth already in hand. The game years were tumultuous. They are context. They are not the pitch.

  This note stays off the application. The CV is what a reader sees. This is the memory I edit.
  """

  def seed_body, do: String.trim(@seed)

  def create_user!(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert!()
  end

  def get_by_user(user_id) when is_integer(user_id) do
    Repo.get_by(Row, user_id: user_id)
  end

  def get_by_user(_), do: nil

  def for_profile(%{user_id: user_id}), do: get_by_user(user_id)
  def for_profile(_), do: nil

  def write!(%User{id: user_id}, body) when is_binary(body) do
    case get_by_user(user_id) do
      nil ->
        %Row{}
        |> Row.changeset(%{user_id: user_id, body: body, version: 1, private: true})
        |> Repo.insert!()

      row ->
        update!(row, body)
    end
  end

  def update!(%Row{} = row, body) when is_binary(body) do
    row
    |> Row.changeset(%{body: body, version: row.version + 1})
    |> Repo.update!()
  end

  def delete(%Row{} = row), do: Repo.delete(row)

  @doc """
  Text that may ride along with an application. Private narratives contribute nothing.
  """
  def for_application(nil), do: nil
  def for_application(%Row{private: true}), do: nil
  def for_application(%Row{private: false, body: body}), do: body
end
