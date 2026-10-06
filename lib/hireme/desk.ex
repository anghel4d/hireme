defmodule Hireme.Desk do
  @moduledoc """
  Applications on the desk.

  The board reads a slim projection (no listing text). Opening a card
  resolves that application's mask against the root items and rebuilds
  the CV variant. Glance numbers on the card are written back so the
  grid never resolves thousands of documents.
  """

  import Ecto.Query
  alias Hireme.Corpus
  alias Hireme.Cv
  alias Hireme.Cv.Lineage
  alias Hireme.CvPair
  alias Hireme.Letterbox
  alias Hireme.Desk.Batch
  alias Hireme.Desk.Event
  alias Hireme.Desk.Job
  alias Hireme.Desk.Overlay
  alias Hireme.Desk.Stage
  alias Hireme.Desk.Variant
  alias Hireme.Keywords
  alias Hireme.Kv
  alias Hireme.Narrative
  alias Hireme.Mask
  alias Hireme.Pipeline
  alias Hireme.Repo

  def code(id), do: "JobApp#{id}"

  def exists?(id), do: Repo.exists?(from j in Job, where: j.id == ^id)

  def list_cards(filters) do
    filters
    |> card_query()
    |> Repo.all()
    |> Enum.map(&to_card/1)
    |> Enum.sort_by(&{&1.batch_ordinal || 999, Pipeline.rank(&1.stage), -&1.heat, &1.company})
  end

  def focus(nil), do: nil

  def focus(job_id) do
    case Repo.get(Job, job_id) do
      nil ->
        nil

      job ->
        job = Repo.preload(job, [:profile, :batch])
        variant = Repo.get_by!(Variant, job_app_id: job.id)
        variant = %{variant | theme: lineage_theme(variant)}
        items = Corpus.list_items(job.profile_id)
        overlays = overlays(job.id)
        build_focus(job, variant, items, overlays, stages(job.id), recent_events(job.id))
    end
  end

  def root(profile_id) do
    profile = Corpus.get_profile!(profile_id)
    items = Corpus.list_items(profile_id)
    variant = root_variant(profile_id)

    %{
      profile: profile,
      cv: Cv.compose(profile, Mask.apply(items, []), variant, person: person_name()),
      kv: Kv.list("global"),
      narrative: Narrative.for_profile(profile)
    }
  end

  def glance(items, overlays, variant, listing) do
    resolved = Mask.apply(items, overlays)
    targets = Keywords.targets(variant, listing)
    coverage = Keywords.coverage(targets, resolved)
    counts = Mask.counts(overlays)

    %{
      keyword_hits: coverage.hit,
      keyword_total: coverage.total,
      mask_hidden: counts.hidden,
      mask_altered: counts.altered,
      mask_emphasized: counts.emphasized
    }
  end

  def create_job!(attrs) do
    {:ok, job} = create_job(attrs)
    job
  end

  def create_job(attrs) do
    Repo.transaction(fn ->
      stage = Map.get(attrs, :stage, "discovered")
      true = Pipeline.key?(stage)
      rows = Pipeline.initial(stage)
      employer = CvPair.ensure_employer(Map.get(attrs, :employer_id), attrs.company)
      {lineage_state, lineage} = CvPair.ensure_lineage(employer.id)
      theme = Map.get(attrs, :theme, %{})

      lineage =
        if lineage_state == :new and theme != %{} do
          lineage |> Lineage.changeset(%{theme: theme}) |> Repo.update!()
        else
          lineage
        end

      job =
        %Job{}
        |> Job.changeset(%{
          profile_id: attrs.profile_id,
          company: attrs.company,
          role: attrs.role,
          location: Map.get(attrs, :location, ""),
          listing_url: Map.get(attrs, :listing_url, ""),
          listing: Map.get(attrs, :listing, ""),
          heat: Map.get(attrs, :heat, 3),
          status: Map.get(attrs, :status, :open),
          next_action: Map.get(attrs, :next_action, ""),
          next_due: Map.get(attrs, :next_due),
          source: Map.get(attrs, :source, ""),
          stage_on: Map.get(attrs, :stage_on, Date.utc_today()),
          current_stage: stage,
          pips: Pipeline.encode(rows),
          canonical_url: Map.get(attrs, :canonical_url, ""),
          freshness: Map.get(attrs, :freshness, :unknown),
          gate: Map.get(attrs, :gate, :unset),
          fit: Map.get(attrs, :fit, ""),
          squad: Map.get(attrs, :squad, ""),
          employer_id: employer.id,
          batch_id: Map.get(attrs, :batch_id)
        })
        |> maybe_force_id(attrs)
        |> Repo.insert!()

      %Variant{}
      |> Variant.changeset(%{
        job_app_id: job.id,
        profile_id: attrs.profile_id,
        lineage_id: lineage.id,
        label: Map.get(attrs, :label, "CV#{job.id}"),
        theme: theme,
        note: Map.get(attrs, :note, "")
      })
      |> Repo.insert!()

      Enum.each(rows, fn row ->
        %Stage{}
        |> Stage.changeset(Map.put(row, :job_app_id, job.id))
        |> Repo.insert!()
      end)

      Enum.each(Map.get(attrs, :overlays, []), fn overlay ->
        case CvPair.tailor(CvPair.bind!(job.id), overlay.item_id, Map.drop(overlay, [:item_id])) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

      Letterbox.open!(job.id)
      record!(job.id, "open", "Opened at #{Pipeline.label(stage)}")
      refresh_lineage!(lineage.id)
      job = Repo.get!(Job, job.id)
      publish("application_opened", %{"job_id" => job.id, "lineage_id" => lineage.id})
      job
    end)
  end

  def refresh_glance!(job_id) do
    job = Repo.get!(Job, job_id)
    variant = Repo.get_by!(Variant, job_app_id: job.id)
    variant = %{variant | theme: lineage_theme(variant)}
    items = Corpus.list_items(job.profile_id)
    stats = glance(items, overlays(job_id), variant, job.listing)

    job
    |> Ecto.Changeset.change(stats)
    |> Repo.update!()
  end

  def set_stage(job_id, key) do
    with :ok <- Letterbox.permit_job(job_id) do
      cond do
        not Pipeline.key?(key) ->
          {:error, :stage}

        Pipeline.fire_locked?(key) and not batch_open?(job_id) ->
          {:error, :fire_hold}

        true ->
          write_stage(job_id, key)
      end
    end
  end

  def name_open_fire(code) when is_binary(code) do
    case Repo.get_by(Batch, code: code) do
      nil ->
        {:error, :batch}

      batch ->
        case batch |> Batch.changeset(%{fire: :open_fire, status: :open_fire}) |> Repo.update() do
          {:ok, updated} ->
            publish("open_fire", %{"batch" => updated.code})
            {:ok, updated}

          other ->
            other
        end
    end
  end

  def list_batches do
    Repo.all(from b in Batch, order_by: b.ordinal)
  end

  def batch_exists?(code), do: Repo.exists?(from b in Batch, where: b.code == ^code)

  defp write_stage(job_id, key) do
    Repo.transaction(fn ->
      current_rows = stages(job_id)
      previous = Pipeline.current(current_rows)
      moved = Pipeline.move_to(current_rows, key)

      Enum.zip(current_rows, moved)
      |> Enum.each(fn {old, new} ->
        if old.state != new.state do
          old
          |> Ecto.Changeset.change(%{state: new.state})
          |> Repo.update!()
        end
      end)

      active = Pipeline.current(moved)

      changes = %{
        current_stage: active.key,
        pips: Pipeline.encode(moved)
      }

      changes =
        if previous && previous.key == active.key do
          changes
        else
          Map.put(changes, :stage_on, Date.utc_today())
        end

      job =
        Job
        |> Repo.get!(job_id)
        |> Ecto.Changeset.change(changes)
        |> Repo.update!()

      if previous && previous.key != active.key do
        record!(job.id, "stage", "Stage → #{Pipeline.label(active.key)}")
      end

      publish("stage", %{"job_id" => job.id, "stage" => active.key})
      job
    end)
  end

  defp batch_open?(job_id) do
    case Repo.get(Job, job_id) do
      %{batch_id: id} when is_integer(id) ->
        case Repo.get(Batch, id) do
          %{fire: :open_fire} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  def set_next(job_id, action, due) do
    with :ok <- Letterbox.permit_job(job_id) do
      Job
      |> Repo.get!(job_id)
      |> Job.changeset(%{next_action: action, next_due: due})
      |> Repo.update()
    end
  end

  def set_note(job_id, key, note) do
    with :ok <- Letterbox.permit_job(job_id) do
      Stage
      |> Repo.get_by!(job_app_id: job_id, key: key)
      |> Stage.changeset(%{note: note})
      |> Repo.update()
    end
  end

  def perform(%CvPair{} = pair, command) do
    with :ok <- Letterbox.permit_job(CvPair.job_id(pair)) do
      perform_held(pair, command)
    end
  end

  def put_overlay(job_id, item_id, :inherit) do
    with :ok <- Letterbox.permit_job(job_id),
         {:ok, pair} <- CvPair.bind(job_id),
         {:ok, _} <- CvPair.drop_line(pair, item_id) do
      refresh_lineage!(CvPair.lineage_id(pair))
      publish("cv", %{"job_id" => job_id, "lineage_id" => CvPair.lineage_id(pair)})
      {:ok, Repo.get!(Job, job_id)}
    end
  end

  def put_overlay(job_id, item_id, attrs) when is_map(attrs) do
    with :ok <- Letterbox.permit_job(job_id),
         {:ok, pair} <- CvPair.bind(job_id),
         {:ok, _} <- CvPair.tailor(pair, item_id, attrs) do
      refresh_lineage!(CvPair.lineage_id(pair))
      publish("cv", %{"job_id" => job_id, "lineage_id" => CvPair.lineage_id(pair)})
      {:ok, Repo.get!(Job, job_id)}
    end
  end

  def to_card(row) do
    %{
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
      fit: row.fit
    }
  end

  defp build_focus(job, variant, items, overlays, stages, events) do
    resolved = Mask.apply(items, overlays)
    canonical = Mask.apply(items, [])
    targets = Keywords.targets(variant, job.listing)

    %{
      job: job,
      profile: job.profile,
      variant: variant,
      stages: stages,
      events: events,
      cv: Cv.compose(job.profile, resolved, variant, person: person_name()),
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
      fit: j.fit
    })
  end

  defp apply_batch(query, batch) when batch in [nil, "", "all"], do: query
  defp apply_batch(query, "leftover"), do: where(query, [j], is_nil(j.batch_id))

  defp apply_batch(query, code) when is_binary(code) do
    where(query, [_j, _p, _v, b], b.code == ^code)
  end

  defp apply_status(query, "all"), do: query

  defp apply_status(query, status) when is_binary(status) do
    where(query, [j], j.status == ^String.to_existing_atom(status))
  end

  defp apply_stage(query, "all"), do: query

  defp apply_stage(query, stage) when is_binary(stage) do
    where(query, [j], j.current_stage == ^stage)
  end

  defp apply_profile(query, "all"), do: query

  defp apply_profile(query, slug) when is_binary(slug) do
    where(query, [_j, p], p.slug == ^slug)
  end

  defp apply_q(query, q) when q in [nil, ""], do: query

  defp apply_q(query, q) do
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

  defp stages(job_id) do
    Repo.all(from s in Stage, where: s.job_app_id == ^job_id, order_by: s.position)
  end

  defp perform_held(pair, :get) do
    case focus(CvPair.job_id(pair)) do
      nil -> {:error, :not_found}
      focus -> {:ok, focus}
    end
  end

  defp perform_held(pair, {:set_stage, stage}) when is_binary(stage) do
    set_stage(CvPair.job_id(pair), stage)
  end

  defp perform_held(pair, {:set_next, action}) when is_binary(action) do
    set_next(CvPair.job_id(pair), action, nil)
  end

  defp perform_held(pair, {:tailor, item_id, attrs}) when is_integer(item_id) and is_map(attrs) do
    with {:ok, _} <- CvPair.tailor(pair, item_id, attrs) do
      refresh_lineage!(CvPair.lineage_id(pair))

      publish("cv", %{
        "job_id" => CvPair.job_id(pair),
        "lineage_id" => CvPair.lineage_id(pair)
      })

      {:ok, %{"job_id" => CvPair.job_id(pair), "variant_id" => CvPair.variant_id(pair)}}
    end
  end

  defp perform_held(pair, :open_generation) do
    CvPair.open_generation(CvPair.employer_id(pair))
  end

  defp perform_held(%CvPair{}, _command), do: {:error, :command}

  defp overlays(job_id) do
    case CvPair.bind(job_id) do
      {:ok, pair} ->
        Repo.all(from o in Overlay, where: o.lineage_id == ^CvPair.lineage_id(pair))

      _ ->
        Repo.all(from o in Overlay, where: o.job_app_id == ^job_id)
    end
  end

  defp lineage_theme(%{lineage_id: nil, theme: theme}), do: theme || %{}

  defp lineage_theme(%{lineage_id: id, theme: theme}) do
    case Repo.get(Lineage, id) do
      %{theme: lineage_theme} when lineage_theme not in [nil, %{}] -> lineage_theme
      _ -> theme || %{}
    end
  end

  defp refresh_lineage!(lineage_id) do
    from(v in Variant, where: v.lineage_id == ^lineage_id, select: v.job_app_id)
    |> Repo.all()
    |> Enum.each(&refresh_glance!/1)
  end

  defp publish(type, fields) do
    Phoenix.PubSub.broadcast(
      Hireme.PubSub,
      "desk",
      {:desk_event, Map.put(fields, "type", type)}
    )
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

  defp maybe_force_id(changeset, %{id: id}) when is_integer(id) do
    Ecto.Changeset.put_change(changeset, :id, id)
  end

  defp maybe_force_id(changeset, _), do: changeset

  defp age(nil), do: nil
  defp age(%Date{} = date), do: Date.diff(Date.utc_today(), date)
end
