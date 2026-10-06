defmodule Hireme.Narrative do
  @moduledoc """
  Read and revise a user's private narrative.

  The blob is one row per user. Each save bumps `version` and `updated_at`.
  It stays off application export while private.
  """

  alias Hireme.Corpus.Narrative, as: Row
  alias Hireme.Corpus.User
  alias Hireme.Repo

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
