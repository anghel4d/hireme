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
          employer_id: Map.get(attrs, :employer_id),
          batch_id: Map.get(attrs, :batch_id)
        })
        |> maybe_force_id(attrs)
        |> Repo.insert!()

      %Variant{}
      |> Variant.changeset(%{
        job_app_id: job.id,
        profile_id: attrs.profile_id,
        label: Map.get(attrs, :label, "CV#{job.id}"),
        theme: Map.get(attrs, :theme, %{}),
        note: Map.get(attrs, :note, "")
      })
      |> Repo.insert!()

      Enum.each(rows, fn row ->
        %Stage{}
        |> Stage.changeset(Map.put(row, :job_app_id, job.id))
        |> Repo.insert!()
      end)

      Enum.each(Map.get(attrs, :overlays, []), fn overlay ->
        %Overlay{}
        |> Overlay.changeset(Map.put(overlay, :job_app_id, job.id))
        |> Repo.insert!()
      end)

      record!(job.id, "open", "Opened at #{Pipeline.label(stage)}")
      refresh_glance!(job.id)
    end)
  end

  def refresh_glance!(job_id) do
    job = Repo.get!(Job, job_id)
    variant = Repo.get_by!(Variant, job_app_id: job.id)
    items = Corpus.list_items(job.profile_id)
    stats = glance(items, overlays(job_id), variant, job.listing)

    job
    |> Ecto.Changeset.change(stats)
    |> Repo.update!()
  end

  def set_stage(job_id, key) do
    cond do
      not Pipeline.key?(key) ->
        {:error, :stage}

      Pipeline.fire_locked?(key) and not batch_open?(job_id) ->
        {:error, :fire_hold}

      true ->
        write_stage(job_id, key)
    end
  end

  def name_open_fire(code) when is_binary(code) do
    case Repo.get_by(Batch, code: code) do
      nil ->
        {:error, :batch}

      batch ->
        batch
        |> Batch.changeset(%{fire: :open_fire, status: :open_fire})
        |> Repo.update()
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
    Job
    |> Repo.get!(job_id)
    |> Job.changeset(%{next_action: action, next_due: due})
    |> Repo.update()
  end

  def set_note(job_id, key, note) do
    Stage
    |> Repo.get_by!(job_app_id: job_id, key: key)
    |> Stage.changeset(%{note: note})
    |> Repo.update()
  end

  def put_overlay(job_id, item_id, :inherit) do
    Repo.delete_all(from o in Overlay, where: o.job_app_id == ^job_id and o.item_id == ^item_id)
    {:ok, refresh_glance!(job_id)}
  end

  def put_overlay(job_id, item_id, attrs) when is_map(attrs) do
    overlay =
      Repo.get_by(Overlay, job_app_id: job_id, item_id: item_id) ||
        %Overlay{job_app_id: job_id, item_id: item_id}

    case overlay |> Overlay.changeset(attrs) |> Repo.insert_or_update() do
      {:ok, _} -> {:ok, refresh_glance!(job_id)}
      other -> other
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

  defp overlays(job_id) do
    Repo.all(from o in Overlay, where: o.job_app_id == ^job_id)
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
