defmodule Hireme.Corpus.User do
  @moduledoc "The candidate. A profile is a positioning; the narrative hangs off the person."
  use Hireme.Schema

  schema "users" do
    field :name, :string
    field :email, :string, default: ""
    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email])
    |> validate_required([:name])
    |> unique_constraint(:email)
  end
end

defmodule Hireme.Corpus.Profile do
  use Hireme.Schema

  schema "profiles" do
    field :slug, :string
    field :name, :string
    field :headline, :string
    field :summary, :string
    belongs_to :user, Hireme.Corpus.User
    timestamps()
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:slug, :name, :headline, :summary, :user_id])
    |> validate_required([:slug, :name, :headline, :summary])
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:user_id)
  end
end

defmodule Hireme.Corpus.Item do
  use Hireme.Schema

  @kinds [:experience, :project, :education, :skill, :timeline, :fact]

  schema "items" do
    field :kind, Ecto.Enum, values: @kinds
    field :key, :string
    field :title, :string
    field :body, :string, default: ""
    field :org, :string, default: ""
    field :span, :string, default: ""
    field :position, :integer, default: 0
    field :keywords, {:array, :string}, default: []
    belongs_to :profile, Hireme.Corpus.Profile
    timestamps()
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:profile_id, :kind, :key, :title, :body, :org, :span, :position, :keywords])
    |> validate_required([:kind, :key, :title, :position])
    |> unique_constraint(:key)
  end
end

defmodule Hireme.Corpus.Narrative do
  @moduledoc """
  Private memory for one candidate. Not a CV section and not an overlay.
  Application export leaves it out while `private` is true, the default.
  """
  use Hireme.Schema

  schema "narratives" do
    field :body, :string, default: ""
    field :version, :integer, default: 1
    field :private, :boolean, default: true
    belongs_to :user, Hireme.Corpus.User
    timestamps()
  end

  def changeset(narrative, attrs) do
    narrative
    |> cast(attrs, [:user_id, :body, :version, :private])
    |> validate_required([:user_id, :body, :version])
    |> validate_number(:version, greater_than: 0)
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
  end
end

defmodule Hireme.Kv.Pair do
  use Hireme.Schema

  schema "kv_pairs" do
    field :namespace, :string
    field :key, :string
    field :value, :string, default: ""
    timestamps()
  end

  def changeset(pair, attrs) do
    pair
    |> cast(attrs, [:namespace, :key, :value])
    |> validate_required([:namespace, :key])
    |> unique_constraint([:namespace, :key])
  end
end

defmodule Hireme.Corpus do
  @moduledoc """
  The root record: profiles and the items a CV is built from. Items with
  no profile are shared; a profile's CV is its own items plus those.
  """

  import Ecto.Query
  alias Hireme.Corpus.Item
  alias Hireme.Corpus.Profile
  alias Hireme.Repo

  def list_profiles, do: Repo.all(from p in Profile, order_by: p.id)
  def get_profile!(id), do: Repo.get!(Profile, id)
  def create_profile!(attrs), do: %Profile{} |> Profile.changeset(attrs) |> Repo.insert!()
  def create_item!(attrs), do: %Item{} |> Item.changeset(attrs) |> Repo.insert!()
  def get_item_by_key!(key), do: Repo.get_by!(Item, key: key)

  def list_items(profile_id) do
    Repo.all(
      from i in Item,
        where: is_nil(i.profile_id) or i.profile_id == ^profile_id,
        order_by: [asc: i.position, asc: i.id]
    )
  end
end

defmodule Hireme.Narrative do
  @moduledoc """
  Read and revise a user's private narrative: one row per user, each
  save bumps `version`. It stays off application export while private.
  """

  alias Hireme.Corpus.Narrative, as: Row
  alias Hireme.Corpus.User
  alias Hireme.Repo

  def create_user!(attrs), do: %User{} |> User.changeset(attrs) |> Repo.insert!()

  def get_by_user(user_id) when is_integer(user_id), do: Repo.get_by(Row, user_id: user_id)
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
    row |> Row.changeset(%{body: body, version: row.version + 1}) |> Repo.update!()
  end

  def delete(%Row{} = row), do: Repo.delete(row)

  @doc "Text that may ride along with an application. Private narratives contribute nothing."
  def for_application(%Row{private: false, body: body}), do: body
  def for_application(_), do: nil
end

defmodule Hireme.Kv do
  @moduledoc """
  Namespaced key-value pairs. `global` is the person, `profile:<id>` a
  positioning, `app:<id>` process metadata for one application. Nothing
  here is a CV line.
  """

  import Ecto.Query
  alias Hireme.Kv.Pair
  alias Hireme.Repo

  def put(namespace, key, value) when is_binary(namespace) and is_binary(key) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Pair{}
    |> Pair.changeset(%{namespace: namespace, key: key, value: value})
    |> Repo.insert!(
      on_conflict: [set: [value: value, updated_at: now]],
      conflict_target: [:namespace, :key]
    )
  end

  def list(namespace),
    do: Repo.all(from p in Pair, where: p.namespace == ^namespace, order_by: p.key)

  def get(namespace, key), do: Repo.get_by(Pair, namespace: namespace, key: key)
end
