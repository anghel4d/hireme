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
      conflict_target: [:account_id, :namespace, :key]
    )
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

  @spec accents() :: [accent()]
  def accents, do: @accents

  @spec densities() :: [density()]
  def densities, do: @densities

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

  defp fetch(map, key), do: Hireme.Attrs.get(map, key)

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

defmodule Hireme.Mask.Line do
  @moduledoc """
  One canonical item after the overlay has spoken.

  `mode` is `:canonical` when no overlay touches the line. `shown` is
  false only for `:hidden`. The canonical title and body ride along so
  an altered line can show the root text beside it.
  """

  @enforce_keys [
    :id,
    :key,
    :kind,
    :title,
    :body,
    :org,
    :span,
    :position,
    :shown,
    :mode,
    :reason,
    :canonical_title,
    :canonical_body
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: pos_integer(),
          key: String.t(),
          kind: atom(),
          title: String.t(),
          body: String.t(),
          org: String.t(),
          span: String.t(),
          position: integer(),
          shown: boolean(),
          mode: Hireme.Mask.mode(),
          reason: String.t() | nil,
          canonical_title: String.t(),
          canonical_body: String.t()
        }
end

defmodule Hireme.Mask do
  @moduledoc """
  Resolves canonical items through an application's overlays.

  No overlay means the root line is what the CV shows. `:hidden` drops
  the line from the variant. `:altered` replaces title or body and keeps
  the root text beside it. `:emphasized` leaves the words and marks the
  line for the theme.

  An overlay is anything with `item_id`, `mode`, and optional `title`,
  `body`, `reason` under atom keys: the `Overlay` schema or a plain map
  built in code. Strings from the outside are parsed by
  `Hireme.Desk.Overlay.parse_mode/1` before they get here.
  """

  alias Hireme.Mask.Line

  @modes [:hidden, :altered, :emphasized]

  @type applied :: :hidden | :altered | :emphasized
  @type mode :: :canonical | applied()
  @type overlay :: %{
          required(:item_id) => pos_integer(),
          required(:mode) => :hidden | :altered | :emphasized,
          optional(atom()) => term()
        }
  @type counts :: %{
          hidden: non_neg_integer(),
          altered: non_neg_integer(),
          emphasized: non_neg_integer()
        }

  @spec modes() :: [applied()]
  def modes, do: @modes

  @spec apply([struct() | map()], [overlay()]) :: [Line.t()]
  def apply(items, overlays) do
    by_item = Map.new(overlays, &{&1.item_id, &1})

    items
    |> Enum.map(fn item -> resolve(item, Map.get(by_item, item.id)) end)
    |> Enum.sort_by(&{&1.position, &1.id})
  end

  @spec resolve(struct() | map(), overlay() | nil) :: Line.t()
  def resolve(item, nil), do: line(item, :canonical, item.title, item.body, nil)

  def resolve(item, %{mode: :hidden} = overlay) do
    line(item, :hidden, item.title, item.body, reason(overlay))
  end

  def resolve(item, %{mode: :altered} = overlay) do
    line(
      item,
      :altered,
      blank_to(Map.get(overlay, :title), item.title),
      blank_to(Map.get(overlay, :body), item.body),
      reason(overlay)
    )
  end

  def resolve(item, %{mode: :emphasized} = overlay) do
    line(item, :emphasized, item.title, item.body, reason(overlay))
  end

  @spec counts([overlay()]) :: counts()
  def counts(overlays) do
    Enum.reduce(overlays, %{hidden: 0, altered: 0, emphasized: 0}, fn
      %{mode: mode}, acc when mode in @modes -> Map.update!(acc, mode, &(&1 + 1))
    end)
  end

  defp line(item, mode, title, body, reason) do
    %Line{
      id: item.id,
      key: item.key,
      kind: item.kind,
      title: title,
      body: body,
      org: item.org || "",
      span: item.span || "",
      position: item.position,
      shown: mode != :hidden,
      mode: mode,
      reason: reason,
      canonical_title: item.title,
      canonical_body: item.body
    }
  end

  defp reason(overlay), do: Map.get(overlay, :reason)

  defp blank_to(nil, fallback), do: fallback
  defp blank_to("", fallback), do: fallback
  defp blank_to(value, _fallback), do: value
end

defmodule Hireme.Keywords.Coverage do
  @moduledoc """
  Which target words the visible CV hits.
  """

  @enforce_keys [:hits, :misses]
  defstruct hits: [], misses: []

  @type t :: %__MODULE__{hits: [String.t()], misses: [String.t()]}

  @spec hit(t()) :: non_neg_integer()
  def hit(%__MODULE__{hits: hits}), do: length(hits)

  @spec total(t()) :: non_neg_integer()
  def total(%__MODULE__{hits: hits, misses: misses}), do: length(hits) + length(misses)

  @spec percent(t()) :: 0..100
  def percent(%__MODULE__{} = coverage) do
    case total(coverage) do
      0 -> 0
      total -> round(hit(coverage) / total * 100)
    end
  end
end

defmodule Hireme.Keywords do
  @moduledoc """
  Coverage of a listing's target words against the CV a reader would see.

  Hidden lines do not count. Matching is a whole term, so `ecs` does not
  hit inside `specs`.
  """

  alias Hireme.Keywords.Coverage
  alias Hireme.Mask.Line
  alias Hireme.Theme

  @stop ~w(
    about after also and any are because been being both from have here
    into just more most only onto our over role such team that the their
    them then there these they this those very what when where which will
    with work would your you our for the and
  )

  @doc """
  The theme's targets when it names any, else the listing's own words.
  """
  @spec targets(Theme.t(), String.t() | nil) :: [String.t()]
  def targets(%Theme{targets: [_ | _] = targets}, _listing), do: targets
  def targets(%Theme{}, listing), do: extract(listing || "")

  @spec extract(String.t()) :: [String.t()]
  def extract(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9+#.]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 4 or &1 in @stop))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {word, count} -> {-count, word} end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.take(10)
  end

  @spec coverage([String.t()], [Line.t()]) :: Coverage.t()
  def coverage(targets, resolved) when is_list(targets) do
    text = visible_text(resolved)
    {hits, misses} = Enum.split_with(targets, fn term -> hit?(text, term) end)
    %Coverage{hits: hits, misses: misses}
  end

  @spec visible_text([Line.t()]) :: String.t()
  def visible_text(resolved) do
    resolved
    |> Enum.filter(& &1.shown)
    |> Enum.map_join("\n", fn line -> "#{line.title}\n#{line.body}" end)
    |> String.downcase()
  end

  @spec hit?(String.t(), String.t()) :: boolean()
  def hit?(text, term) do
    escaped = Regex.escape(String.downcase(term))
    Regex.match?(~r/(^|[^a-z0-9])#{escaped}([^a-z0-9]|$)/u, text)
  end
end

defmodule Hireme.Cv.Section do
  @moduledoc false
  @enforce_keys [:kind, :label, :lines]
  defstruct [:kind, :label, :lines]

  @type t :: %__MODULE__{kind: atom(), label: String.t(), lines: [Hireme.Mask.Line.t()]}
end

defmodule Hireme.Cv.Document do
  @moduledoc """
  The CV a reader sees: masthead, sections, and the masked tray.
  """

  alias Hireme.Theme

  @enforce_keys [:label, :headline, :summary, :accent, :density, :facts, :sections, :hidden]
  defstruct [
    :label,
    :person,
    :headline,
    :summary,
    :summary_canonical,
    :summary_reason,
    :accent,
    :density,
    :facts,
    :sections,
    :hidden
  ]

  @type t :: %__MODULE__{
          label: String.t(),
          person: String.t() | nil,
          headline: String.t() | nil,
          summary: String.t() | nil,
          summary_canonical: String.t() | nil,
          summary_reason: String.t() | nil,
          accent: Theme.accent(),
          density: Theme.density(),
          facts: [Hireme.Mask.Line.t()],
          sections: [Hireme.Cv.Section.t()],
          hidden: [Hireme.Mask.Line.t()]
        }
end

defmodule Hireme.Cv do
  @moduledoc """
  Folds resolved lines into the document a reader sees.

  Facts sit in the masthead. Experience, projects, education, skills, and
  timeline follow. Hidden lines stay on the document as a masked tray so
  the battleplan can put them back.
  """

  alias Hireme.Cv.Document
  alias Hireme.Cv.Section
  alias Hireme.Mask.Line
  alias Hireme.Theme

  @sections [
    {:experience, "Experience"},
    {:project, "Projects"},
    {:education, "Education"},
    {:skill, "Skills"},
    {:timeline, "Timeline"}
  ]

  @type opts :: [label: String.t(), person: String.t() | nil]

  @spec compose(%{headline: term(), summary: term()}, [Line.t()], Theme.t(), opts()) ::
          Document.t()
  def compose(profile, resolved, %Theme{} = theme, opts \\ []) do
    summary = theme.lead || profile.summary
    {shown, hidden} = Enum.split_with(resolved, & &1.shown)

    %Document{
      label: Keyword.get(opts, :label, "CV"),
      person: Keyword.get(opts, :person),
      headline: profile.headline,
      summary: summary,
      summary_canonical: if(summary == profile.summary, do: nil, else: profile.summary),
      summary_reason: theme.lead_reason,
      accent: theme.accent,
      density: theme.density,
      facts: Enum.filter(shown, &(&1.kind == :fact)),
      sections: sections(shown),
      hidden: hidden
    }
  end

  defp sections(shown) do
    Enum.flat_map(@sections, fn {kind, label} ->
      case Enum.filter(shown, &(&1.kind == kind)) do
        [] -> []
        lines -> [%Section{kind: kind, label: label, lines: lines}]
      end
    end)
  end
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
         {:ok, lineage} <- editable(pair, today) do
      write_line(pair, lineage, item_id, attrs, today)
    end
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
  def phase(%Lineage{} = lineage, today \\ Date.utc_today()) do
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
