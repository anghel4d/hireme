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

  def create_profile!(attrs),
    do: insert!(:profiles, fn -> %Profile{} |> Profile.changeset(attrs) |> Repo.insert!() end)

  def create_item!(attrs),
    do: insert!(:items, fn -> %Item{} |> Item.changeset(attrs) |> Repo.insert!() end)

  # Every desk write runs in the account's sequencer, so the tables it
  # keeps (and boots tabs from) never miss a row.
  defp insert!(table, write) do
    {:ok, row} = Hireme.Ops.exec({:insert, table, write})
    row
  end

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

  def write!(%User{id: user_id}, body) when is_binary(body) do
    {:ok, row} =
      Hireme.Ops.exec(
        {:insert, :narratives,
         fn ->
           case get_by_user(user_id) do
             nil ->
               %Row{}
               |> Row.changeset(%{user_id: user_id, body: body, version: 1, private: true})
               |> Repo.insert!()

             row ->
               update!(row, body)
           end
         end}
      )

    row
  end

  def update!(%Row{} = row, body) when is_binary(body) do
    row |> Row.changeset(%{body: body, version: row.version + 1}) |> Repo.update!()
  end
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

    {:ok, pair} =
      Hireme.Ops.exec(
        {:insert, :kv_pairs,
         fn ->
           %Pair{}
           |> Pair.changeset(%{namespace: namespace, key: key, value: value})
           |> Repo.insert!(
             on_conflict: [set: [value: value, updated_at: now]],
             conflict_target: [:account_id, :namespace, :key],
             returning: true
           )
         end}
      )

    pair
  end

  def list(namespace),
    do: Repo.all(from p in Pair, where: p.namespace == ^namespace, order_by: p.key)

  def get(namespace, key), do: Repo.get_by(Pair, namespace: namespace, key: key)
end

defmodule Hireme.Theme do
  @moduledoc """
  How one CV reads: the lead line, its reason, the accent, the density,
  and the words the listing is measured against.

  The database keeps a theme as a JSON object. `parse/1` turns that
  object, with string or atom keys, into this struct once. Everything
  after that reads fields. `to_map/1` is the inverse for storage.
  """

  @accents [:ink, :signal, :paper]
  @densities [:cv, :tight, :narrative]

  @type accent :: :ink | :signal | :paper
  @type density :: :cv | :tight | :narrative

  defstruct lead: nil, lead_reason: nil, accent: :ink, density: :cv, targets: []

  @type t :: %__MODULE__{
          lead: String.t() | nil,
          lead_reason: String.t() | nil,
          accent: accent(),
          density: density(),
          targets: [String.t()]
        }

  @spec parse(map() | nil) :: t()
  def parse(nil), do: %__MODULE__{}
  def parse(%__MODULE__{} = theme), do: theme

  def parse(map) when is_map(map) do
    %__MODULE__{
      lead: text(fetch(map, :lead)),
      lead_reason: text(fetch(map, :lead_reason)),
      accent: choice(fetch(map, :accent), @accents, :ink),
      density: choice(fetch(map, :density), @densities, :cv),
      targets: words(fetch(map, :targets))
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = theme) do
    %{}
    |> put_text("lead", theme.lead)
    |> put_text("lead_reason", theme.lead_reason)
    |> Map.put("accent", Atom.to_string(theme.accent))
    |> Map.put("density", Atom.to_string(theme.density))
    |> put_list("targets", theme.targets)
  end

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = theme), do: theme == %__MODULE__{}

  # The atom key, else its string twin.
  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_), do: nil

  defp choice(value, allowed, default) do
    case Hireme.Closed.parse(allowed, value) do
      {:ok, atom} -> atom
      :error -> default
    end
  end

  defp words(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp words(_), do: []

  defp put_text(map, _key, nil), do: map
  defp put_text(map, key, value), do: Map.put(map, key, value)

  defp put_list(map, _key, []), do: map
  defp put_list(map, key, list), do: Map.put(map, key, list)
end

# Four ids, four structs. The same shape, so one definition; the names
# are what keep a job id out of a variant id's slot.
for name <- [JobId, VariantId, EmployerId, LineageId] do
  defmodule Module.concat(Hireme.CvPair, name) do
    @moduledoc false
    @enforce_keys [:value]
    defstruct [:value]

    @type t :: %__MODULE__{value: pos_integer()}

    @spec new(pos_integer()) :: t()
    def new(value) when is_integer(value) and value > 0, do: %__MODULE__{value: value}
  end
end

defmodule Hireme.CvPair do
  @moduledoc """
  The CV for one application.

  `t()` is that application and its variant, loaded together. `bind/1`
  is the constructor. The query joins the variant to the application's
  employer lineage, so a variant from another employer does not produce
  a pair. `tailor/3` and `drop_line/2` accept only `t()`. They load the
  pair again and require the two structs to be equal. A struct built for
  a different application does not match, and the write does not run.

  `JobId`, `VariantId`, `EmployerId`, and `LineageId` are different
  structs. A job id does not have the variant id's type, so the pair
  cannot be assembled by swapping those fields and still type-check.

  One employer has one lineage (`cv_lineages.employer_id` is unique).
  One application has one variant (`cv_variants.job_app_id` is unique).
  The trigger `cv_variants_employer_match` aborts a row that points an
  application at another employer's lineage. The overlay trigger does
  the same for a line.

  For 90 days after a generation opens, the lineage can be rewritten.
  That is one quarter. After that, edits wait. `open_generation/1`
  starts the next quarter and accepts new lines only. An existing line
  stays, so a later attempt cannot replace it with another CV's wording.
  """

  import Ecto.Query
  alias Hireme.Cv.Lineage
  alias Hireme.CvPair.EmployerId
  alias Hireme.CvPair.JobId
  alias Hireme.CvPair.LineageId
  alias Hireme.CvPair.VariantId
  alias Hireme.Desk.Employer
  alias Hireme.Desk.Overlay
  alias Hireme.Desk.Variant
  alias Hireme.LifeEv
  alias Hireme.Repo

  @enforce_keys [:job_id, :variant_id, :employer_id, :lineage_id]
  defstruct [:job_id, :variant_id, :employer_id, :lineage_id]

  @typedoc """
  One application paired with the only variant that belongs to it.
  """
  @type t :: %__MODULE__{
          job_id: JobId.t(),
          variant_id: VariantId.t(),
          employer_id: EmployerId.t(),
          lineage_id: LineageId.t()
        }

  @cooldown_days 90

  @spec cooldown_days() :: 90
  def cooldown_days, do: @cooldown_days

  @spec job_id(t()) :: pos_integer()
  def job_id(%__MODULE__{job_id: %JobId{value: value}}), do: value

  @spec variant_id(t()) :: pos_integer()
  def variant_id(%__MODULE__{variant_id: %VariantId{value: value}}), do: value

  @spec employer_id(t()) :: pos_integer()
  def employer_id(%__MODULE__{employer_id: %EmployerId{value: value}}), do: value

  @spec lineage_id(t()) :: pos_integer()
  def lineage_id(%__MODULE__{lineage_id: %LineageId{value: value}}), do: value

  def ensure_employer(nil, company) when is_binary(company) and company != "" do
    case Repo.get_by(Employer, name: company) do
      nil ->
        %Employer{}
        |> Employer.changeset(%{name: company, score_100: LifeEv.score(company)})
        |> Repo.insert!()

      employer ->
        employer
    end
  end

  def ensure_employer(id, _company) when is_integer(id), do: Repo.get!(Employer, id)

  def ensure_lineage(employer_id, today \\ Date.utc_today()) do
    case Repo.get_by(Lineage, employer_id: employer_id) do
      nil ->
        lineage =
          %Lineage{}
          |> Lineage.changeset(%{
            employer_id: employer_id,
            generation: 1,
            opened_on: today,
            rewrites_allowed: true,
            theme: %{}
          })
          |> Repo.insert!()

        {:new, lineage}

      lineage ->
        {:existing, lineage}
    end
  end

  @doc """
  Load the only CV pair for this application.
  """
  @spec bind(pos_integer()) :: {:ok, t()} | {:error, :unbound}
  def bind(job_id) when is_integer(job_id), do: load(job_id)

  @spec bind!(pos_integer()) :: t()
  def bind!(job_id) do
    {:ok, pair} = bind(job_id)
    pair
  end

  @spec tailor(t(), pos_integer(), map(), Date.t()) ::
          {:ok, t()} | {:error, atom() | Ecto.Changeset.t()}
  def tailor(%__MODULE__{} = claimed, item_id, attrs, today \\ Date.utc_today())
      when is_integer(item_id) do
    with {:ok, pair} <- verified(claimed),
         :ok <- line?(item_id),
         {:ok, lineage} <- editable(pair, today) do
      write_line(pair, lineage, item_id, attrs, today)
    end
  end

  # A line of this account's corpus. Another account's line, or none,
  # would leave an overlay pointing outside the desk.
  defp line?(item_id) do
    if Repo.exists?(from i in Hireme.Corpus.Item, where: i.id == ^item_id),
      do: :ok,
      else: {:error, :not_found}
  end

  @spec drop_line(t(), pos_integer(), Date.t()) :: {:ok, t()} | {:error, atom()}
  def drop_line(%__MODULE__{} = claimed, item_id, today \\ Date.utc_today())
      when is_integer(item_id) do
    with {:ok, pair} <- verified(claimed),
         {:ok, %Lineage{rewrites_allowed: true}} <- editable(pair, today) do
      Repo.delete_all(
        from o in Overlay, where: o.lineage_id == ^lineage_id(pair) and o.item_id == ^item_id
      )

      {:ok, pair}
    else
      {:ok, %Lineage{}} -> {:error, :not_additive}
      error -> error
    end
  end

  @spec open_generation(pos_integer(), Date.t()) ::
          {:ok, Lineage.t()} | {:error, atom() | Ecto.Changeset.t()}
  def open_generation(employer_id, today \\ Date.utc_today()) when is_integer(employer_id) do
    case Repo.get_by(Lineage, employer_id: employer_id) do
      nil ->
        {:error, :lineage}

      %Lineage{} = lineage ->
        if Date.diff(today, lineage.opened_on) < @cooldown_days do
          {:error, :cooldown}
        else
          lineage
          |> Lineage.changeset(%{
            generation: lineage.generation + 1,
            opened_on: today,
            rewrites_allowed: false
          })
          |> Repo.update()
        end
    end
  end

  @spec phase(Lineage.t(), Date.t()) :: :ready | :tailor | :additive
  defp phase(%Lineage{} = lineage, today) do
    cond do
      Date.diff(today, lineage.opened_on) >= @cooldown_days -> :ready
      lineage.rewrites_allowed -> :tailor
      true -> :additive
    end
  end

  defp load(job_id) do
    query =
      from v in Variant,
        join: j in Hireme.Desk.Job,
        on: j.id == v.job_app_id,
        join: l in Lineage,
        on: l.id == v.lineage_id and l.employer_id == j.employer_id,
        where: v.job_app_id == ^job_id,
        select: %{
          job_id: j.id,
          variant_id: v.id,
          employer_id: j.employer_id,
          lineage_id: l.id
        }

    case Repo.one(query) do
      nil ->
        {:error, :unbound}

      row ->
        {:ok,
         %__MODULE__{
           job_id: JobId.new(row.job_id),
           variant_id: VariantId.new(row.variant_id),
           employer_id: EmployerId.new(row.employer_id),
           lineage_id: LineageId.new(row.lineage_id)
         }}
    end
  end

  defp verified(%__MODULE__{job_id: %JobId{value: job_id}} = claimed) do
    case load(job_id) do
      {:ok, ^claimed} -> {:ok, claimed}
      {:ok, _other} -> {:error, :cv_mismatch}
      error -> error
    end
  end

  defp verified(_), do: {:error, :cv_mismatch}

  defp editable(pair, today) do
    lineage = Repo.get!(Lineage, lineage_id(pair))

    case phase(lineage, today) do
      :ready -> {:error, :cooldown}
      _ -> {:ok, lineage}
    end
  end

  defp write_line(pair, lineage, item_id, attrs, _today) do
    result =
      case Repo.get_by(Overlay, lineage_id: lineage_id(pair), item_id: item_id) do
        %Overlay{} when not lineage.rewrites_allowed ->
          {:error, :not_additive}

        %Overlay{} = existing ->
          existing |> Overlay.changeset(attrs) |> Repo.update()

        nil ->
          %Overlay{}
          |> Overlay.changeset(
            Map.merge(attrs, %{
              job_app_id: job_id(pair),
              lineage_id: lineage_id(pair),
              item_id: item_id,
              generation: lineage.generation
            })
          )
          |> Repo.insert()
      end

    with {:ok, _overlay} <- result, do: {:ok, pair}
  end
end
