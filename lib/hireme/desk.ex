defmodule Hireme.Desk do
  @moduledoc """
  Applications on the desk.

  The board reads a slim projection (`Card`, no listing text). Opening a
  card builds a `Focus`: the mask resolved against the root items and the
  document composed from it. Glance numbers on the card are written back
  so the grid never resolves thousands of documents.

  Writes return `{:ok, value}` or `{:error, reason}` with `reason` a
  member of `t:refusal/0` or a changeset. Every change is broadcast as a
  `Hireme.Desk.Signal`.
  """

  import Ecto.Query
  alias Hireme.Corpus
  alias Hireme.Cv
  alias Hireme.Cv.Lineage
  alias Hireme.CvPair
  alias Hireme.Desk.Batch
  alias Hireme.Desk.Card
  alias Hireme.Desk.Event
  alias Hireme.Desk.Focus
  alias Hireme.Desk.Job
  alias Hireme.Desk.Opening
  alias Hireme.Desk.Overlay
  alias Hireme.Desk.Root
  alias Hireme.Desk.Signal
  alias Hireme.Desk.Stage
  alias Hireme.Desk.Variant
  alias Hireme.Keywords
  alias Hireme.Kv
  alias Hireme.Letterbox
  alias Hireme.LifeEv
  alias Hireme.Mask
  alias Hireme.Narrative
  alias Hireme.Pipeline
  alias Hireme.Repo
  alias Hireme.Theme

  @topic "desk"

  @type filters :: Hireme.Desk.Filters.t()

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
          | Opening.problem()

  @type command ::
          :get
          | :open_generation
          | {:set_stage, Pipeline.stage()}
          | {:set_next, String.t()}
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

  @spec list_cards(filters()) :: [Card.t()]
  def list_cards(%Hireme.Desk.Filters{} = filters) do
    filters
    |> card_query()
    |> Repo.all()
    |> Enum.map(&to_card/1)
    |> Enum.sort_by(&Card.order/1)
  end

  @spec focus(pos_integer() | nil) :: Focus.t() | nil
  def focus(nil), do: nil

  def focus(job_id) do
    case Repo.get(Job, job_id) do
      nil ->
        nil

      job ->
        job = Repo.preload(job, [:profile, :batch])
        variant = Repo.get_by!(Variant, job_app_id: job.id)
        theme = effective_theme(variant)
        items = Corpus.list_items(job.profile_id)

        build_focus(
          job,
          variant,
          theme,
          items,
          overlays(job.id),
          rail(job.id),
          recent_events(job.id)
        )
    end
  end

  @spec root(pos_integer()) :: Root.t()
  def root(profile_id) do
    profile = Corpus.get_profile!(profile_id)
    items = Corpus.list_items(profile_id)
    variant = root_variant(profile_id)

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

  @spec glance([Corpus.Item.t()], [Overlay.t()], Theme.t(), String.t() | nil) :: map()
  def glance(items, overlays, %Theme{} = theme, listing) do
    resolved = Mask.apply(items, overlays)
    coverage = Keywords.coverage(Keywords.targets(theme, listing), resolved)
    counts = Mask.counts(overlays)

    %{
      keyword_hits: Keywords.Coverage.hit(coverage),
      keyword_total: Keywords.Coverage.total(coverage),
      mask_hidden: counts.hidden,
      mask_altered: counts.altered,
      mask_emphasized: counts.emphasized
    }
  end

  @spec create_job!(map() | Opening.t()) :: Job.t()
  def create_job!(attrs) do
    {:ok, job} = create_job(attrs)
    job
  end

  @spec create_job(map() | Opening.t()) :: {:ok, Job.t()} | {:error, refusal() | term()}
  def create_job(attrs) do
    with {:ok, opening} <- Opening.new(attrs) do
      Repo.transaction(fn -> open!(opening) end)
    end
  end

  defp open!(%Opening{} = opening) do
    rail = Pipeline.initial(opening.stage)
    employer = CvPair.ensure_employer(opening.employer_id, opening.company)
    {lineage_state, lineage} = CvPair.ensure_lineage(employer.id)

    lineage =
      if lineage_state == :new and not Theme.empty?(opening.theme) do
        lineage |> Lineage.changeset(%{theme: Theme.to_map(opening.theme)}) |> Repo.update!()
      else
        lineage
      end

    job =
      %Job{}
      |> Job.changeset(%{
        profile_id: opening.profile_id,
        company: opening.company,
        role: opening.role,
        location: opening.location,
        listing_url: opening.listing_url,
        listing: opening.listing,
        heat: opening.heat,
        status: opening.status,
        next_action: opening.next_action,
        next_due: opening.next_due,
        source: opening.source,
        stage_on: opening.stage_on || Date.utc_today(),
        current_stage: opening.stage,
        pips: Pipeline.encode(rail),
        canonical_url: opening.canonical_url,
        freshness: opening.freshness,
        gate: opening.gate,
        fit: opening.fit,
        squad: opening.squad,
        score_100: opening.score_100,
        employer_id: employer.id,
        batch_id: opening.batch_id
      })
      |> maybe_force_id(opening.id)
      |> Repo.insert!()

    %Variant{}
    |> Variant.changeset(%{
      job_app_id: job.id,
      profile_id: opening.profile_id,
      lineage_id: lineage.id,
      label: opening.label || "CV#{job.id}",
      theme: Theme.to_map(opening.theme),
      note: opening.note
    })
    |> Repo.insert!()

    Enum.each(rail, fn rung ->
      %Stage{} |> Stage.changeset(Stage.from_rung(rung, job.id)) |> Repo.insert!()
    end)

    pair = CvPair.bind!(job.id)

    Enum.each(opening.overlays, fn overlay ->
      case CvPair.tailor(pair, overlay.item_id, Map.delete(overlay, :item_id)) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)

    Letterbox.open!(job.id)
    record!(job.id, "open", "Opened at #{Pipeline.label(opening.stage)}")
    refresh_lineage!(lineage.id)
    publish(Signal.application_opened(job.id, lineage.id))
    Repo.get!(Job, job.id)
  end

  @spec refresh_glance!(pos_integer()) :: Job.t()
  def refresh_glance!(job_id) do
    job = Repo.get!(Job, job_id)
    variant = Repo.get_by!(Variant, job_app_id: job.id)
    items = Corpus.list_items(job.profile_id)
    stats = glance(items, overlays(job_id), effective_theme(variant), job.listing)

    job
    |> Ecto.Changeset.change(stats)
    |> Repo.update!()
  end

  @spec set_stage(pos_integer(), Pipeline.stage()) :: {:ok, Job.t()} | {:error, refusal()}
  def set_stage(job_id, stage) do
    with :ok <- Letterbox.permit_job(job_id),
         :ok <- fire_permits(job_id, stage) do
      write_stage(job_id, stage)
    end
  end

  defp fire_permits(job_id, stage) do
    if Pipeline.fire_locked?(stage) and not batch_open?(job_id) do
      {:error, :fire_hold}
    else
      :ok
    end
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

  @spec list_batches() :: [Batch.t()]
  def list_batches do
    Repo.all(from b in Batch, order_by: b.ordinal)
  end

  defp write_stage(job_id, stage) do
    Repo.transaction(fn ->
      rows = Repo.all(from s in Stage, where: s.job_app_id == ^job_id, order_by: s.position)
      before = Enum.map(rows, &Stage.to_rung/1)
      previous = Pipeline.current(before)
      moved = Pipeline.move_to(before, stage)

      Enum.zip(rows, moved)
      |> Enum.each(fn {row, rung} ->
        if row.state != rung.state do
          row |> Ecto.Changeset.change(%{state: rung.state}) |> Repo.update!()
        end
      end)

      active = Pipeline.current(moved)
      changed? = is_nil(previous) or previous.key != active.key

      changes = %{current_stage: active.key, pips: Pipeline.encode(moved)}
      changes = if changed?, do: Map.put(changes, :stage_on, Date.utc_today()), else: changes

      job =
        Job
        |> Repo.get!(job_id)
        |> Ecto.Changeset.change(changes)
        |> Repo.update!()

      if changed?, do: record!(job.id, "stage", "Stage → #{Pipeline.label(active.key)}")

      publish(Signal.stage(job.id, active.key))
      job
    end)
  end

  defp batch_open?(job_id) do
    query =
      from j in Job,
        join: b in Batch,
        on: b.id == j.batch_id,
        where: j.id == ^job_id and b.fire == :open_fire,
        select: true

    Repo.exists?(query)
  end

  @spec set_next(pos_integer(), String.t(), Date.t() | nil) ::
          {:ok, Job.t()} | {:error, :leased | Ecto.Changeset.t()}
  def set_next(job_id, action, due) do
    with :ok <- Letterbox.permit_job(job_id) do
      Job
      |> Repo.get!(job_id)
      |> Job.changeset(%{next_action: action, next_due: due})
      |> Repo.update()
    end
  end

  @spec set_note(pos_integer(), Pipeline.stage(), String.t()) ::
          {:ok, Stage.t()} | {:error, :leased | Ecto.Changeset.t()}
  def set_note(job_id, stage, note) do
    with :ok <- Letterbox.permit_job(job_id) do
      Stage
      |> Repo.get_by!(job_app_id: job_id, key: stage)
      |> Stage.changeset(%{note: note})
      |> Repo.update()
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
  def put_overlay(job_id, item_id, :inherit) do
    with :ok <- Letterbox.permit_job(job_id),
         {:ok, pair} <- CvPair.bind(job_id),
         {:ok, _} <- CvPair.drop_line(pair, item_id) do
      after_cv_change(pair)
    end
  end

  def put_overlay(job_id, item_id, attrs) when is_map(attrs) do
    with :ok <- Letterbox.permit_job(job_id),
         {:ok, pair} <- CvPair.bind(job_id),
         {:ok, _} <- CvPair.tailor(pair, item_id, attrs) do
      after_cv_change(pair)
    end
  end

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

  defp perform_held(pair, {:tailor, item_id, attrs}) when is_integer(item_id) and is_map(attrs) do
    with {:ok, _} <- CvPair.tailor(pair, item_id, attrs),
         {:ok, _job} <- after_cv_change(pair) do
      {:ok, pair}
    end
  end

  defp perform_held(pair, :open_generation) do
    CvPair.open_generation(CvPair.employer_id(pair))
  end

  defp perform_held(%CvPair{}, _command), do: {:error, :command}

  defp to_card(row) do
    %Card{
      id: row.id,
      code: code(row.id),
      company: row.company,
      role: row.role,
      location: row.location,
      heat: row.heat,
      status: row.status,
      stage: row.current_stage,
      stage_label: Pipeline.label(row.current_stage),
      pips: row.pips,
      cv_label: row.cv_label,
      profile_name: row.profile_name,
      profile_slug: row.profile_slug,
      keyword_hits: row.keyword_hits,
      keyword_total: row.keyword_total,
      mask_hidden: row.mask_hidden,
      mask_altered: row.mask_altered,
      mask_emphasized: row.mask_emphasized,
      next_action: row.next_action,
      next_due: row.next_due,
      age: age(row.stage_on),
      batch_code: row.batch_code,
      batch_fire: row.batch_fire,
      batch_ordinal: row.batch_ordinal,
      freshness: row.freshness,
      gate: row.gate,
      fit: row.fit,
      score_100: row.score_100,
      band: LifeEv.band(row.score_100)
    }
  end

  defp build_focus(job, variant, theme, items, overlays, rail, events) do
    resolved = Mask.apply(items, overlays)
    canonical = Mask.apply(items, [])
    targets = Keywords.targets(theme, job.listing)

    %Focus{
      job: job,
      profile: job.profile,
      variant: variant,
      theme: theme,
      rail: rail,
      events: events,
      cv: Cv.compose(job.profile, resolved, theme, label: variant.label, person: person_name()),
      narrative: Narrative.for_profile(job.profile),
      coverage: Keywords.coverage(targets, resolved),
      root_coverage: Keywords.coverage(targets, canonical),
      kv: Kv.list("app:#{job.id}"),
      masks: Enum.filter(resolved, &(&1.mode != :canonical))
    }
  end

  defp card_query(filters) do
    Job
    |> join(:inner, [j], p in Corpus.Profile, on: p.id == j.profile_id)
    |> join(:inner, [j], v in Variant, on: v.job_app_id == j.id)
    |> join(:left, [j], b in Batch, on: b.id == j.batch_id)
    |> apply_status(filters.status)
    |> apply_stage(filters.stage)
    |> apply_profile(filters.profile)
    |> apply_batch(filters.batch)
    |> apply_q(filters.q)
    |> apply_band(filters.band)
    |> apply_min_score(filters.min_score)
    |> select([j, p, v, b], %{
      id: j.id,
      company: j.company,
      role: j.role,
      location: j.location,
      heat: j.heat,
      status: j.status,
      next_action: j.next_action,
      next_due: j.next_due,
      stage_on: j.stage_on,
      current_stage: j.current_stage,
      pips: j.pips,
      keyword_hits: j.keyword_hits,
      keyword_total: j.keyword_total,
      mask_hidden: j.mask_hidden,
      mask_altered: j.mask_altered,
      mask_emphasized: j.mask_emphasized,
      profile_name: p.name,
      profile_slug: p.slug,
      cv_label: v.label,
      batch_code: b.code,
      batch_fire: b.fire,
      batch_ordinal: b.ordinal,
      freshness: j.freshness,
      gate: j.gate,
      fit: j.fit,
      score_100: j.score_100
    })
  end

  defp apply_batch(query, :all), do: query
  defp apply_batch(query, :leftover), do: where(query, [j], is_nil(j.batch_id))

  defp apply_batch(query, code) when is_binary(code),
    do: where(query, [_j, _p, _v, b], b.code == ^code)

  defp apply_status(query, :all), do: query

  defp apply_status(query, status) when is_atom(status),
    do: where(query, [j], j.status == ^status)

  defp apply_stage(query, :all), do: query

  defp apply_stage(query, stage) when is_atom(stage),
    do: where(query, [j], j.current_stage == ^stage)

  defp apply_profile(query, :all), do: query
  defp apply_profile(query, slug) when is_binary(slug), do: where(query, [_j, p], p.slug == ^slug)

  defp apply_q(query, ""), do: query

  defp apply_q(query, q) when is_binary(q) do
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

  defp apply_band(query, :all), do: query

  defp apply_band(query, band) when is_atom(band) do
    row = Enum.find(LifeEv.bands(), &(&1.key == band))
    where(query, [j], j.score_100 >= ^row.min and j.score_100 <= ^row.max)
  end

  defp apply_min_score(query, 0), do: query

  defp apply_min_score(query, n) when is_integer(n) and n > 0 do
    where(query, [j], j.score_100 >= ^n)
  end

  defp rail(job_id) do
    Repo.all(from s in Stage, where: s.job_app_id == ^job_id, order_by: s.position)
    |> Enum.map(&Stage.to_rung/1)
  end

  defp overlays(job_id) do
    case CvPair.bind(job_id) do
      {:ok, pair} -> Repo.all(from o in Overlay, where: o.lineage_id == ^CvPair.lineage_id(pair))
      _ -> Repo.all(from o in Overlay, where: o.job_app_id == ^job_id)
    end
  end

  defp effective_theme(%Variant{lineage_id: nil, theme: theme}), do: Theme.parse(theme)

  defp effective_theme(%Variant{lineage_id: id, theme: theme}) do
    case Repo.get(Lineage, id) do
      %Lineage{theme: lineage_theme} when lineage_theme not in [nil, %{}] ->
        Theme.parse(lineage_theme)

      _ ->
        Theme.parse(theme)
    end
  end

  defp refresh_lineage!(lineage_id) do
    from(v in Variant, where: v.lineage_id == ^lineage_id, select: v.job_app_id)
    |> Repo.all()
    |> Enum.each(&refresh_glance!/1)
  end

  defp publish(%Signal{} = signal) do
    Phoenix.PubSub.broadcast(Hireme.PubSub, @topic, {:desk_event, signal})
  end

  defp recent_events(job_id) do
    Repo.all(from e in Event, where: e.job_app_id == ^job_id, order_by: [desc: e.id], limit: 12)
  end

  defp root_variant(profile_id) do
    Repo.one(from v in Variant, where: v.profile_id == ^profile_id and is_nil(v.job_app_id)) ||
      %Variant{
        label: "Root",
        theme: %{"accent" => "ink", "density" => "cv"},
        profile_id: profile_id
      }
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

  defp maybe_force_id(changeset, id) when is_integer(id),
    do: Ecto.Changeset.put_change(changeset, :id, id)

  defp maybe_force_id(changeset, nil), do: changeset

  defp age(nil), do: nil
  defp age(%Date{} = date), do: Date.diff(Date.utc_today(), date)
end
