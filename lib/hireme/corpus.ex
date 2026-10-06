defmodule Hireme.Corpus do
  @moduledoc """
  The root record: profiles and the items a CV is built from.

  Items with no profile are shared. A profile's CV is its own items plus
  those shared lines.
  """

  import Ecto.Query
  alias Hireme.Corpus.Item
  alias Hireme.Corpus.Profile
  alias Hireme.Repo

  def list_profiles do
    Repo.all(from p in Profile, order_by: p.id)
  end

  def get_profile!(id), do: Repo.get!(Profile, id)

  def get_profile_by_slug!(slug), do: Repo.get_by!(Profile, slug: slug)

  def create_profile!(attrs) do
    %Profile{}
    |> Profile.changeset(attrs)
    |> Repo.insert!()
  end

  def create_item!(attrs) do
    %Item{}
    |> Item.changeset(attrs)
    |> Repo.insert!()
  end

  def list_items(profile_id) do
    Repo.all(
      from i in Item,
        where: is_nil(i.profile_id) or i.profile_id == ^profile_id,
        order_by: [asc: i.position, asc: i.id]
    )
  end

  def get_item!(id), do: Repo.get!(Item, id)

  def get_item_by_key!(key), do: Repo.get_by!(Item, key: key)
end
