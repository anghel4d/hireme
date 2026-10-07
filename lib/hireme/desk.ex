defmodule Hireme.Desk.Card do
  @moduledoc """
  What the board shows for one application: the job's own columns minus
  the listing text, the names it is joined to, and the heat painted on
  after the fetch. The query selects the job fields by name and merges
  the joins; `order/1` is the board order.
  """

  alias Hireme.Pipeline

  @job_fields ~w(id company role location heat status next_action next_due stage_on pips
                 keyword_hits keyword_total mask_hidden mask_altered mask_emphasized
                 freshness gate fit score_100 listing_url canonical_url department squad
                 heat_override heat_override_reason)a
  @joined ~w(stage profile_name profile_slug cv_label batch_code batch_fire batch_ordinal)a

  @enforce_keys @job_fields ++ @joined
  defstruct @enforce_keys ++
              [load: 0.0, cap: 1.0, heat_state: :cool, ats_vendor: :unknown, cooldown_days: nil]

  @type t :: %__MODULE__{
          id: pos_integer(),
          company: String.t(),
          role: String.t(),
          location: String.t(),
          heat: 1..5,
          status: Hireme.Desk.Job.status(),
          next_action: String.t(),
          next_due: Date.t() | nil,
          stage_on: Date.t() | nil,
          pips: String.t(),
          keyword_hits: non_neg_integer(),
          keyword_total: non_neg_integer(),
          mask_hidden: non_neg_integer(),
          mask_altered: non_neg_integer(),
          mask_emphasized: non_neg_integer(),
          freshness: atom(),
          gate: atom(),
          fit: String.t(),
          score_100: Hireme.LifeEv.score(),
          listing_url: String.t(),
          canonical_url: String.t(),
          department: String.t(),
          squad: String.t(),
          heat_override: boolean(),
          heat_override_reason: String.t(),
          stage: Pipeline.stage(),
          profile_name: String.t(),
          profile_slug: String.t(),
          cv_label: String.t(),
          batch_code: String.t() | nil,
          batch_fire: :hold | :open_fire | nil,
          batch_ordinal: non_neg_integer() | nil,
          load: float(),
          cap: float(),
          heat_state: :cool | :warm | :hot | :blocked,
          ats_vendor: atom(),
          cooldown_days: non_neg_integer() | nil
        }

  @doc false
  def job_fields, do: @job_fields

  @doc """
  Board order: highest `score_100` first, then cooler company load, then
  batch, then rung, then interest heat, then company.
  """
  @spec order(t()) :: tuple()
  def order(%__MODULE__{} = card) do
    ratio = if card.cap <= 0, do: 100, else: round(card.load / card.cap * 100)

    {-card.score_100, ratio, card.batch_ordinal || 999, Pipeline.rank(card.stage), -card.heat,
     card.company}
  end
end

defmodule Hireme.Desk.Focus do
  @moduledoc """
  One application opened: its row, its rail, its document, and the
  coverage of the listing's words against that document and the root.
  """

  @enforce_keys [
    :job,
    :profile,
    :variant,
    :theme,
    :rail,
    :events,
    :cv,
    :narrative,
    :coverage,
    :root_coverage,
    :kv,
    :masks
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          job: Hireme.Desk.Job.t(),
          profile: Hireme.Corpus.Profile.t(),
          variant: Hireme.Desk.Variant.t(),
          theme: Hireme.Theme.t(),
          rail: Hireme.Pipeline.rail(),
          events: [Hireme.Desk.Event.t()],
          cv: Hireme.Cv.Document.t(),
          narrative: Hireme.Corpus.Narrative.t() | nil,
          coverage: Hireme.Keywords.Coverage.t(),
          root_coverage: Hireme.Keywords.Coverage.t(),
          kv: [Hireme.Kv.Pair.t()],
          masks: [Hireme.Mask.Line.t()]
        }
end

defmodule Hireme.Desk.Root do
  @moduledoc "A profile's root CV: every line as written, no mask."

  @enforce_keys [:profile, :cv, :kv, :narrative]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          profile: Hireme.Corpus.Profile.t(),
          cv: Hireme.Cv.Document.t(),
          kv: [Hireme.Kv.Pair.t()],
          narrative: Hireme.Corpus.Narrative.t() | nil
        }
end

defmodule Hireme.Desk.Signal do
  @moduledoc """
  One change on the desk, broadcast on the `"desk"` topic as
  `{:desk_event, %Signal{}}`.

  `kind` is the closed set of things that can change. `job_id` is set for
  every change to one application and nil for a batch-level change, so a
  letterbox can match its own application with one field.
  """

  @type kind :: :application_opened | :stage | :cv | :open_fire

  @enforce_keys [:kind]
  defstruct [:kind, :job_id, :lineage_id, :stage, :batch]

  @type t :: %__MODULE__{
          kind: kind(),
          job_id: pos_integer() | nil,
          lineage_id: pos_integer() | nil,
          stage: Hireme.Pipeline.stage() | nil,
          batch: String.t() | nil
        }

  @spec application_opened(pos_integer(), pos_integer()) :: t()
  def application_opened(job_id, lineage_id),
    do: %__MODULE__{kind: :application_opened, job_id: job_id, lineage_id: lineage_id}

  @spec stage(pos_integer(), Hireme.Pipeline.stage()) :: t()
  def stage(job_id, stage), do: %__MODULE__{kind: :stage, job_id: job_id, stage: stage}

  @spec cv(pos_integer(), pos_integer()) :: t()
  def cv(job_id, lineage_id), do: %__MODULE__{kind: :cv, job_id: job_id, lineage_id: lineage_id}

  @spec open_fire(String.t()) :: t()
  def open_fire(batch), do: %__MODULE__{kind: :open_fire, batch: batch}

  @spec about?(t(), pos_integer()) :: boolean()
  def about?(%__MODULE__{job_id: job_id}, job_id) when is_integer(job_id), do: true
  def about?(%__MODULE__{}, _job_id), do: false

  @doc "The wire shape. Nil fields are left out."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = signal) do
    %{"type" => Atom.to_string(signal.kind)}
    |> put("job_id", signal.job_id)
    |> put("lineage_id", signal.lineage_id)
    |> put("stage", signal.stage && Atom.to_string(signal.stage))
    |> put("batch", signal.batch)
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end

defmodule Hireme.Desk.Filters do
  @moduledoc """
  The board's filter, parsed once from the URL and written back to it.

  `from_params/1` never fails: an unknown stage, status, or band falls
  back to the default. `to_query/1` is the inverse and leaves defaults
  out so the URL stays short.

  `min_score` is the lowest `score_100` shown. `band` picks one band of
  the Life-EV ladder; both apply when both are given. `heat` is company
  load after the governor paints the card (`cool` / `warm` / `hot` /
  `blocked`); it is not a SQL column.
  """

  alias Hireme.Closed
  alias Hireme.Desk.Job
  alias Hireme.Heat
  alias Hireme.LifeEv
  alias Hireme.Pipeline

  @type t :: %__MODULE__{
          q: String.t(),
          stage: Pipeline.stage() | :all,
          profile: String.t() | :all,
          status: Job.status() | :all,
          batch: String.t() | :leftover | :all,
          min_score: LifeEv.score(),
          band: LifeEv.band() | :all,
          heat: :all | :cool | :warm | :hot | :blocked
        }

  defstruct q: "",
            stage: :all,
            profile: :all,
            status: :open,
            batch: :all,
            min_score: 0,
            band: :all,
            heat: :all

  @keys [:q, :stage, :profile, :status, :batch, :min_score, :band, :heat]

  @spec from_params(map()) :: t()
  def from_params(params) when is_map(params) do
    %__MODULE__{
      q: params["q"] || "",
      stage: params["stage"] |> Pipeline.parse() |> or_all(),
      profile: name(params["profile"]),
      status: Closed.get([:all | Job.statuses()], params["status"], :open),
      batch: if(params["batch"] == "leftover", do: :leftover, else: name(params["batch"])),
      min_score: min_score(params["min_score"]),
      band: params["band"] |> LifeEv.parse_band() |> or_all(),
      heat: params["heat"] |> Heat.parse_state() |> or_all()
    }
  end

  @spec merge(t(), map()) :: t()
  def merge(%__MODULE__{} = filters, overrides) when is_map(overrides) do
    struct!(filters, Map.take(overrides, @keys))
  end

  @spec to_query(t()) :: map()
  def to_query(%__MODULE__{} = filters) do
    defaults = %__MODULE__{}

    Map.new(
      for key <- @keys,
          value = Map.fetch!(filters, key),
          value != Map.fetch!(defaults, key),
          do: {Atom.to_string(key), to_string(value)}
    )
  end

  defp or_all({:ok, value}), do: value
  defp or_all(:error), do: :all

  defp name(value) when is_binary(value) and value not in ["", "all"], do: value
  defp name(_), do: :all

  defp min_score(n) when is_integer(n), do: LifeEv.clamp(n)

  defp min_score(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> LifeEv.clamp(n)
      _ -> 0
    end
  end

  defp min_score(_), do: 0
end

defmodule Hireme.Desk do
  @moduledoc """
  Applications on the desk.

  The board reads a slim projection (`Card`, no listing text). Opening a
  card builds a `Focus`: the mask resolved against the root items and the
  document composed from it. Glance numbers on the card are written back
  so the grid never resolves thousands of documents.

  The rail is the pip string on the row. `Pipeline.decode/1` gives the
  rungs back and `stage_notes` carries the one thing the pips cannot.

  Writes return `{:ok, value}` or `{:error, reason}` with `reason` a
  member of `t:refusal/0` or a changeset. Every change is broadcast as a
  `Hireme.Desk.Signal`.
  """

  import Ecto.Query
  import Ecto.Changeset, only: [apply_action: 2, put_change: 3]
  alias Hireme.Corpus
  alias Hireme.Cv
  alias Hireme.Cv.Lineage
  alias Hireme.CvPair
  alias Hireme.Desk.Batch
  alias Hireme.Desk.Card
  alias Hireme.Desk.Event
  alias Hireme.Desk.Filters
  alias Hireme.Desk.Focus
  alias Hireme.Desk.Job
  alias Hireme.Desk.Overlay
  alias Hireme.Desk.Root
  alias Hireme.Desk.Signal
  alias Hireme.Desk.Variant
  alias Hireme.Heat
  alias Hireme.Heat.Verdict
  alias Hireme.Keywords
  alias Hireme.Kv
  alias Hireme.Letterbox
  alias Hireme.LifeEv
  alias Hireme.Mask
  alias Hireme.Narrative
  alias Hireme.Pipeline
  alias Hireme.Pipeline.Rung
  alias Hireme.Repo
  alias Hireme.Theme

  @topic "desk"

  @type refusal ::
          :fire_hold
          | :leased
          | :batch
          | :not_found
          | :unbound
          | :cv_mismatch
          | :cooldown
          | :not_additive
          | :lineage
          | :command
          | :heat
          | :reason

  @type command ::
          :get
          | :open_generation
          | {:set_stage, Pipeline.stage()}
          | {:set_next, String.t()}
          | {:set_score, LifeEv.score()}
          | {:tailor, pos_integer(), map()}

  @type reply ::
          {:ok, Focus.t()}
          | {:ok, Job.t()}
          | {:ok, Lineage.t()}
          | {:ok, CvPair.t()}
          | {:error, refusal() | Ecto.Changeset.t()}

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec code(pos_integer()) :: String.t()
  def code(id), do: "JobApp#{id}"

  @spec list_cards(Filters.t()) :: [Card.t()]
  def list_cards(%Filters{} = filters) do
    snap = Heat.snapshot()

    filters
    |> card_query()
    |> Repo.all()
    |> Enum.map(&Heat.decorate(struct!(Card, &1), snap))
    |> Enum.filter(&(filters.heat == :all or &1.heat_state == filters.heat))
    |> Enum.sort_by(&Card.order/1)
  end

  @spec list_batches() :: [Batch.t()]
  def list_batches, do: Repo.all(from b in Batch, order_by: b.ordinal)

  @spec focus(pos_integer() | nil) :: Focus.t() | nil
  def focus(nil), do: nil

  def focus(job_id) do
    case Repo.get(Job, job_id) do
      nil ->
        nil

      job ->
        job = Repo.preload(job, [:profile, :batch])
        variant = variant_of(job.id)
        theme = theme_of(variant)
        items = Corpus.list_items(job.profile_id)
        resolved = Mask.apply(items, overlays(variant))
        canonical = Mask.apply(items, [])
        targets = Keywords.targets(theme, job.listing)

        %Focus{
          job: job,
          profile: job.profile,
          variant: variant,
          theme: theme,
          rail: rail(job),
          events:
            Repo.all(
              from e in Event, where: e.job_app_id == ^job.id, order_by: [desc: e.id], limit: 12
            ),
          cv:
            Cv.compose(job.profile, resolved, theme, label: variant.label, person: person_name()),
          narrative: Narrative.for_profile(job.profile),
          coverage: Keywords.coverage(targets, resolved),
          root_coverage: Keywords.coverage(targets, canonical),
          kv: Kv.list("app:#{job.id}"),
          masks: Enum.filter(resolved, &(&1.mode != :canonical))
        }
    end
  end

  @spec root(pos_integer()) :: Root.t()
  def root(profile_id) do
    profile = Corpus.get_profile!(profile_id)
    items = Corpus.list_items(profile_id)

    variant =
      Repo.one(from v in Variant, where: v.profile_id == ^profile_id and is_nil(v.job_app_id)) ||
        %Variant{label: "Root", theme: %{}, profile_id: profile_id}

    %Root{
      profile: profile,
      cv:
        Cv.compose(profile, Mask.apply(items, []), Theme.parse(variant.theme),
          label: variant.label,
          person: person_name()
        ),
      kv: Kv.list("global"),
      narrative: Narrative.for_profile(profile)
    }
  end

  @doc """
  Open one application. `attrs` is cast through the `Job` changeset, so
  stage, status, freshness, and gate may arrive as atoms or their names.
  `theme` is parsed once. `overlays` are tailored onto the employer's CV.
  """
  @spec create_job(map()) :: {:ok, Job.t()} | {:error, refusal() | Ecto.Changeset.t()}
  def create_job(attrs) when is_map(attrs) do
    Repo.transaction(fn -> open!(attrs) end)
  end

  @spec create_job!(map()) :: Job.t()
  def create_job!(attrs) do
    {:ok, job} = create_job(attrs)
    job
  end

  defp open!(attrs) do
    changeset =
      Job.changeset(
        %Job{},
        attrs
        |> Map.drop([:id, :stage, :theme, :overlays, :label, :note])
        |> Map.put(:current_stage, Map.get(attrs, :stage, :discovered))
        |> Map.put(:score_100, LifeEv.score(attrs))
      )

    draft =
      case apply_action(changeset, :insert) do
        {:ok, draft} -> draft
        {:error, changeset} -> Repo.rollback(changeset)
      end

    rail = Pipeline.initial(draft.current_stage)
    employer = CvPair.ensure_employer(draft.employer_id, draft.company)
    {lineage_state, lineage} = CvPair.ensure_lineage(employer.id)
    theme = Theme.parse(Map.get(attrs, :theme))

    if lineage_state == :new and not Theme.empty?(theme) do
      lineage |> Lineage.changeset(%{theme: Theme.to_map(theme)}) |> Repo.update!()
    end

    job =
      changeset
      |> put_change(:pips, Pipeline.encode(rail))
      |> put_change(:employer_id, employer.id)
      |> put_change(:stage_on, draft.stage_on || Date.utc_today())
      |> force_id(Map.get(attrs, :id))
      |> Repo.insert!()

    %Variant{}
    |> Variant.changeset(%{
      job_app_id: job.id,
      profile_id: job.profile_id,
      lineage_id: lineage.id,
      label: Map.get(attrs, :label) || "CV#{job.id}",
      theme: Theme.to_map(theme),
      note: Map.get(attrs, :note) || ""
    })
    |> Repo.insert!()

    pair = CvPair.bind!(job.id)
    overlays = Map.get(attrs, :overlays, [])

    Enum.each(overlays, fn overlay ->
      case CvPair.tailor(pair, overlay.item_id, Map.delete(overlay, :item_id)) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)

    Letterbox.open!(job.id)
    record!(job.id, "open", "Opened at #{Pipeline.label(draft.current_stage)}")

    # A new line on the shared CV moves every sibling's glance; a bare
    # opening moves only its own.
    if overlays == [], do: refresh_glance!(job.id), else: refresh_lineage!(lineage.id)

    publish(Signal.application_opened(job.id, lineage.id))
    Repo.get!(Job, job.id)
  end

  @spec set_score(pos_integer(), LifeEv.score()) ::
          {:ok, Job.t()} | {:error, :leased | Ecto.Changeset.t()}
  def set_score(job_id, score) when score in 0..100, do: write(job_id, %{score_100: score})

  @spec set_next(pos_integer(), String.t(), Date.t() | nil) ::
          {:ok, Job.t()} | {:error, :leased | Ecto.Changeset.t()}
  def set_next(job_id, action, due), do: write(job_id, %{next_action: action, next_due: due})

  @spec set_note(pos_integer(), Pipeline.stage(), String.t()) ::
          {:ok, Job.t()} | {:error, :leased | Ecto.Changeset.t()}
  def set_note(job_id, stage, note) do
    write(job_id, fn job ->
      %{stage_notes: Map.put(job.stage_notes || %{}, Pipeline.name(stage), note)}
    end)
  end

  # One row, one changeset, only while no agent holds the lease.
  defp write(job_id, attrs) do
    with :ok <- Letterbox.permit_job(job_id) do
      job = Repo.get!(Job, job_id)
      attrs = if is_function(attrs, 1), do: attrs.(job), else: attrs
      job |> Job.changeset(attrs) |> Repo.update()
    end
  end

  @spec refresh_glance!(pos_integer()) :: :ok
  def refresh_glance!(job_id) do
    job_id |> variant_of() |> List.wrap() |> refresh_variants!()
  end

  @spec set_stage(pos_integer(), Pipeline.stage()) :: {:ok, Job.t()} | {:error, refusal()}
  def set_stage(job_id, stage) do
    with :ok <- Letterbox.permit_job(job_id),
         :ok <- fire_permits(job_id, stage),
         :ok <- heat_permits(job_id, stage) do
      Repo.transaction(fn -> write_stage(Repo.get!(Job, job_id), stage) end)
    end
  end

  defp fire_permits(job_id, stage) do
    if Pipeline.fire_locked?(stage) and not batch_open?(job_id),
      do: {:error, :fire_hold},
      else: :ok
  end

  defp heat_permits(job_id, stage) do
    job = Repo.get!(Job, job_id)

    if Heat.entering?(job.current_stage, stage) do
      case Heat.can_apply(job) do
        %Verdict{decision: :allow} -> :ok
        %Verdict{} -> {:error, :heat}
      end
    else
      :ok
    end
  end

  @spec govern_batch(Batch.t() | String.t()) :: %{
          kept: [Job.t()],
          deferred: [{Job.t(), Verdict.t()}]
        }
  def govern_batch(%Batch{} = batch) do
    result = Heat.mix_batch(batch)
    Enum.each(result.deferred, fn {job, verdict} -> defer!(job, verdict) end)
    result
  end

  def govern_batch(code) when is_binary(code) do
    case Repo.get_by(Batch, code: code) do
      nil -> %{kept: [], deferred: []}
      batch -> govern_batch(batch)
    end
  end

  defp defer!(%Job{} = job, %Verdict{} = verdict) do
    days = verdict.cooldown_days

    note =
      "HEAT DEFER · #{verdict.note}" <>
        if(is_integer(days) and days > 0, do: " · #{days}d", else: "")

    job = job |> Job.changeset(%{batch_id: nil, next_action: note}) |> Repo.update!()
    if job.current_stage in [:fire_ready, :open_fire], do: write_stage(job, :gated)
    record!(job.id, "heat", note)
  end

  defp write_stage(%Job{} = job, stage) do
    before = rail(job)
    previous = Pipeline.current(before)
    moved = Pipeline.move_to(before, stage)
    active = Pipeline.current(moved)
    changed? = is_nil(previous) or previous.key != active.key

    changes = %{current_stage: active.key, pips: Pipeline.encode(moved)}
    changes = if changed?, do: Map.put(changes, :stage_on, Date.utc_today()), else: changes
    job = job |> Ecto.Changeset.change(changes) |> Repo.update!()

    if changed?, do: record!(job.id, "stage", "Stage → #{Pipeline.label(active.key)}")
    publish(Signal.stage(job.id, active.key))
    job
  end

  defp batch_open?(job_id) do
    Repo.exists?(
      from j in Job,
        join: b in Batch,
        on: b.id == j.batch_id,
        where: j.id == ^job_id and b.fire == :open_fire
    )
  end

  @spec name_open_fire(String.t()) :: {:ok, Batch.t()} | {:error, :batch | Ecto.Changeset.t()}
  def name_open_fire(code) when is_binary(code) do
    case Repo.get_by(Batch, code: code) do
      nil ->
        {:error, :batch}

      batch ->
        with {:ok, updated} <-
               batch |> Batch.changeset(%{fire: :open_fire, status: :open_fire}) |> Repo.update() do
          publish(Signal.open_fire(updated.code))
          {:ok, updated}
        end
    end
  end

  @doc """
  Run one letterbox command against the application its pair names.
  The pair, not an id in the command, decides which application changes.
  """
  @spec perform(CvPair.t(), command()) :: reply()
  def perform(%CvPair{} = pair, command) do
    with :ok <- Letterbox.permit_job(CvPair.job_id(pair)) do
      perform_held(pair, command)
    end
  end

  @spec put_overlay(pos_integer(), pos_integer(), :inherit | map()) ::
          {:ok, Job.t()} | {:error, refusal() | Ecto.Changeset.t()}
  def put_overlay(job_id, item_id, change) do
    with :ok <- Letterbox.permit_job(job_id),
         {:ok, pair} <- CvPair.bind(job_id),
         {:ok, _} <- write_line(pair, item_id, change) do
      after_cv_change(pair)
    end
  end

  defp write_line(pair, item_id, :inherit), do: CvPair.drop_line(pair, item_id)

  defp write_line(pair, item_id, attrs) when is_map(attrs),
    do: CvPair.tailor(pair, item_id, attrs)

  defp after_cv_change(pair) do
    refresh_lineage!(CvPair.lineage_id(pair))
    publish(Signal.cv(CvPair.job_id(pair), CvPair.lineage_id(pair)))
    {:ok, Repo.get!(Job, CvPair.job_id(pair))}
  end

  defp perform_held(pair, :get) do
    case focus(CvPair.job_id(pair)) do
      nil -> {:error, :not_found}
      focus -> {:ok, focus}
    end
  end

  defp perform_held(pair, {:set_stage, stage}) when is_atom(stage) do
    set_stage(CvPair.job_id(pair), stage)
  end

  defp perform_held(pair, {:set_next, action}) when is_binary(action) do
    set_next(CvPair.job_id(pair), action, nil)
  end

  defp perform_held(pair, {:set_score, score}) when score in 0..100 do
    set_score(CvPair.job_id(pair), score)
  end

  defp perform_held(pair, {:tailor, item_id, attrs}) when is_integer(item_id) and is_map(attrs) do
    with {:ok, _} <- CvPair.tailor(pair, item_id, attrs),
         {:ok, _job} <- after_cv_change(pair) do
      {:ok, pair}
    end
  end

  defp perform_held(pair, :open_generation), do: CvPair.open_generation(CvPair.employer_id(pair))
  defp perform_held(%CvPair{}, _command), do: {:error, :command}

  @spec rail(Job.t()) :: Pipeline.rail()
  def rail(%Job{} = job) do
    rungs =
      case Pipeline.decode(job.pips) do
        {:ok, rungs} -> rungs
        :error -> Pipeline.initial(job.current_stage)
      end

    notes = job.stage_notes || %{}

    Enum.map(rungs, fn %Rung{} = rung ->
      %Rung{rung | note: Map.get(notes, Pipeline.name(rung.key), "")}
    end)
  end

  @doc """
  The `score_100` chart for the whole desk or for one batch: band counts
  and ten-point bins.
  """
  @spec score_chart(String.t() | :leftover | :all) :: LifeEv.Chart.t()
  def score_chart(batch \\ :all) do
    Job
    |> join(:left, [j], b in Batch, on: b.id == j.batch_id)
    |> filter(:batch, batch)
    |> select([j], j.score_100)
    |> Repo.all()
    |> LifeEv.chart()
  end

  defp card_query(%Filters{} = f) do
    Job
    |> join(:inner, [j], p in Corpus.Profile, on: p.id == j.profile_id)
    |> join(:inner, [j], v in Variant, on: v.job_app_id == j.id)
    |> join(:left, [j], b in Batch, on: b.id == j.batch_id)
    |> filter(:status, f.status)
    |> filter(:stage, f.stage)
    |> filter(:profile, f.profile)
    |> filter(:batch, f.batch)
    |> filter(:q, f.q)
    |> filter(:band, f.band)
    |> filter(:min_score, f.min_score)
    |> select([j], map(j, ^Card.job_fields()))
    |> select_merge([j, p, v, b], %{
      stage: j.current_stage,
      profile_name: p.name,
      profile_slug: p.slug,
      cv_label: v.label,
      batch_code: b.code,
      batch_fire: b.fire,
      batch_ordinal: b.ordinal
    })
  end

  defp filter(query, _field, :all), do: query
  defp filter(query, :q, ""), do: query
  defp filter(query, :min_score, 0), do: query
  defp filter(query, :min_score, min), do: where(query, [j], j.score_100 >= ^min)

  defp filter(query, :band, band) do
    %{min: low, max: high} = Enum.find(LifeEv.bands(), &(&1.key == band))
    where(query, [j], j.score_100 >= ^low and j.score_100 <= ^high)
  end

  defp filter(query, :batch, :leftover), do: where(query, [j], is_nil(j.batch_id))
  defp filter(query, :batch, code), do: where(query, [..., b], b.code == ^code)
  defp filter(query, :status, status), do: where(query, [j], j.status == ^status)
  defp filter(query, :stage, stage), do: where(query, [j], j.current_stage == ^stage)
  defp filter(query, :profile, slug), do: where(query, [_j, p], p.slug == ^slug)

  defp filter(query, :q, q) do
    like = "%#{String.downcase(String.trim(q))}%"

    where(
      query,
      [j, p, v],
      like(fragment("lower(?)", j.company), ^like) or
        like(fragment("lower(?)", j.role), ^like) or
        like(fragment("lower(?)", j.location), ^like) or
        like(fragment("lower(?)", j.next_action), ^like) or
        like(fragment("lower(?)", p.name), ^like) or
        like(fragment("lower(?)", v.label), ^like) or
        like(fragment("lower('jobapp' || ?)", j.id), ^like) or
        like(fragment("lower('cv' || ?)", j.id), ^like) or
        like(fragment("cast(? as text)", j.id), ^like)
    )
  end

  defp variant_of(job_id) do
    Repo.one!(from v in Variant, where: v.job_app_id == ^job_id, preload: [:lineage, :job_app])
  end

  defp overlays(%Variant{lineage_id: lineage_id}) do
    Repo.all(from o in Overlay, where: o.lineage_id == ^lineage_id)
  end

  defp theme_of(%Variant{lineage: %Lineage{theme: theme}}) when theme not in [nil, %{}],
    do: Theme.parse(theme)

  defp theme_of(%Variant{theme: theme}), do: Theme.parse(theme)

  # Every variant on a lineage shares the overlays, so they are read once
  # and each card's numbers are written with one update.
  defp refresh_lineage!(lineage_id) do
    from(v in Variant, where: v.lineage_id == ^lineage_id, preload: [:lineage, :job_app])
    |> Repo.all()
    |> refresh_variants!()
  end

  defp refresh_variants!([]), do: :ok

  defp refresh_variants!([%Variant{lineage_id: lineage_id} | _] = variants) do
    overlays = Repo.all(from o in Overlay, where: o.lineage_id == ^lineage_id)
    counts = Mask.counts(overlays)

    variants
    |> Enum.group_by(& &1.profile_id)
    |> Enum.each(fn {profile_id, group} ->
      resolved = Mask.apply(Corpus.list_items(profile_id), overlays)

      Enum.each(group, fn %Variant{job_app: %Job{} = job} = variant ->
        coverage = Keywords.coverage(Keywords.targets(theme_of(variant), job.listing), resolved)

        Repo.update_all(from(j in Job, where: j.id == ^job.id),
          set: [
            keyword_hits: Keywords.Coverage.hit(coverage),
            keyword_total: Keywords.Coverage.total(coverage),
            mask_hidden: counts.hidden,
            mask_altered: counts.altered,
            mask_emphasized: counts.emphasized
          ]
        )
      end)
    end)
  end

  defp publish(%Signal{} = signal) do
    Phoenix.PubSub.broadcast(Hireme.PubSub, @topic, {:desk_event, signal})
  end

  defp person_name do
    case Kv.get("global", "candidate") do
      nil -> nil
      pair -> pair.value
    end
  end

  defp record!(job_id, kind, body) do
    %Event{}
    |> Event.changeset(%{job_app_id: job_id, kind: kind, body: body})
    |> Repo.insert!()
  end

  defp force_id(changeset, id) when is_integer(id), do: put_change(changeset, :id, id)
  defp force_id(changeset, nil), do: changeset
end
