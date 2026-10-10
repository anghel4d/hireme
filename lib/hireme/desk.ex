defmodule Hireme.Desk do
  @moduledoc """
  Applications on the desk.

  Every view of an application is derived by the client from the raw
  rows; what lives here is what the server decides: opening, stage
  moves and their heat permits, naming open fire, overlays and CV
  generations, with the refusals each can answer.

  The rail is the pip string on the row. `Pipeline.decode/1` gives the
  rungs back and `stage_notes` carries the one thing the pips cannot.

  Writes return `{:ok, value}` or `{:error, reason}` with `reason` a
  member of `t:refusal/0` or a changeset. Every public write runs on the
  account's `Hireme.Ops` sequencer, which calls `execute/1` inside one
  transaction and, after commit, broadcasts the change as an
  `{:ops_delta, rev, delta}` on the account's topic.

  Every function here runs as the account on the process; the repo
  scopes each read to it and `tenant/1` stamps each row.
  """

  import Ecto.Query
  import Ecto.Changeset, only: [apply_action: 2, put_change: 3]
  alias Hireme.Cv.Lineage
  alias Hireme.CvPair
  alias Hireme.Desk.Batch
  alias Hireme.Desk.Event
  alias Hireme.Desk.Job
  alias Hireme.Desk.Variant
  alias Hireme.Heat
  alias Hireme.Heat.Verdict
  alias Hireme.Letterbox
  alias Hireme.LifeEv
  alias Hireme.Ops
  alias Hireme.Pipeline
  alias Hireme.Pipeline.Rung
  alias Hireme.Repo
  alias Hireme.Theme

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

  @typedoc "A desk write as `Hireme.Ops` sequences it; see `execute/1`."
  @type write ::
          {:create, map()}
          | {:stage, pos_integer(), Pipeline.stage()}
          | {:next, pos_integer(), String.t(), Date.t() | nil}
          | {:note, pos_integer(), Pipeline.stage(), String.t()}
          | {:score, pos_integer(), LifeEv.score()}
          | {:overlay, pos_integer(), pos_integer(), :inherit | map()}
          | {:open_fire, String.t()}
          | {:govern, Batch.t()}
          | {:generation, pos_integer()}

  @doc "The PubSub topic one account's deltas go out on."
  @spec topic(pos_integer()) :: String.t()
  def topic(account_id \\ Repo.account_id!()), do: "desk:#{account_id}"

  @doc "The applications that share `job_id`'s CV lineage, itself included."
  @spec lineage_jobs(pos_integer()) :: [pos_integer()]
  def lineage_jobs(job_id) do
    Repo.all(
      from v in Variant,
        join: mine in Variant,
        on: mine.lineage_id == v.lineage_id,
        where: mine.job_app_id == ^job_id and not is_nil(v.job_app_id),
        select: v.job_app_id
    )
    |> case do
      [] -> [job_id]
      ids -> ids
    end
  end

  @spec list_batches() :: [Batch.t()]
  def list_batches, do: Repo.all(from b in Batch, order_by: b.ordinal)

  @doc """
  Open one application. `attrs` is cast through the `Job` changeset, so
  stage, status, freshness, and gate may arrive as atoms or their names.
  `theme` is parsed once. `overlays` are tailored onto the employer's CV.
  """
  @spec create_job(map()) :: {:ok, Job.t()} | {:error, refusal() | Ecto.Changeset.t()}
  def create_job(attrs) when is_map(attrs), do: Ops.exec({:create, attrs})

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
        {:error, changeset} -> throw({:refused, changeset})
      end

    rail = Pipeline.initial(draft.current_stage)
    employer = CvPair.ensure_employer(draft.employer_id, draft.company)
    {lineage_state, lineage} = CvPair.ensure_lineage(employer.id)
    theme = Theme.parse(Map.get(attrs, :theme))

    lineage =
      if lineage_state == :new and not Theme.empty?(theme) do
        lineage |> Lineage.changeset(%{theme: Theme.to_map(theme)}) |> Repo.update!()
      else
        lineage
      end

    # Round-trip JSON note keys in the insert, without a later job reload.
    job =
      changeset
      |> put_change(:pips, Pipeline.encode(rail))
      |> put_change(:employer_id, employer.id)
      |> put_change(:stage_on, draft.stage_on || Date.utc_today())
      |> put_change(:no, Ops.number!())
      |> force_id(Map.get(attrs, :id))
      |> Repo.insert!(returning: [:stage_notes])

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

    overlays = Map.get(attrs, :overlays, [])

    if overlays != [] do
      pair = CvPair.bind!(job.id)

      Enum.each(overlays, fn overlay ->
        case CvPair.tailor(pair, overlay.item_id, Map.delete(overlay, :item_id)) do
          {:ok, _} -> :ok
          {:error, reason} -> throw({:refused, reason})
        end
      end)
    end

    record!(job.id, "open", "Opened at #{Pipeline.label(draft.current_stage)}")

    job
  end

  @spec set_score(pos_integer(), LifeEv.score()) ::
          {:ok, Job.t()} | {:error, :leased | Ecto.Changeset.t()}
  def set_score(job_id, score) when score in 0..100, do: Ops.exec({:score, job_id, score})

  @spec set_next(pos_integer(), String.t(), Date.t() | nil) ::
          {:ok, Job.t()} | {:error, :leased | Ecto.Changeset.t()}
  def set_next(job_id, action, due), do: Ops.exec({:next, job_id, action, due})

  @spec set_note(pos_integer(), Pipeline.stage(), String.t()) ::
          {:ok, Job.t()} | {:error, :leased | Ecto.Changeset.t()}
  def set_note(job_id, stage, note), do: Ops.exec({:note, job_id, stage, note})

  @doc """
  Run one desk write. Called only by `Hireme.Ops`, inside its
  transaction, on the account's sequencer; a lease is checked against
  the process that asked (`Hireme.Ops.holder/0`), not the sequencer.
  """
  @spec execute(write()) :: {:ok, term()} | {:error, refusal() | Ecto.Changeset.t()}
  # A refusal part-way through an opening is thrown, not rolled back: the
  # sequencer's transaction (or the write's savepoint in it) undoes it.
  def execute({:create, attrs}) do
    {:ok, open!(attrs)}
  catch
    {:refused, reason} -> {:error, reason}
  end

  def execute({:score, job_id, score}), do: write(job_id, %{score_100: score})

  def execute({:next, job_id, action, due}),
    do: write(job_id, %{next_action: action, next_due: due})

  def execute({:note, job_id, stage, note}),
    do: write(job_id, %{stage_notes: {:json_put, Pipeline.name(stage), note}})

  def execute({:stage, job_id, stage}) do
    with :ok <- permit(job_id),
         :ok <- fire_permits(job_id, stage),
         :ok <- heat_permits(job_id, stage) do
      {:ok, write_stage(Repo.get!(Job, job_id), stage)}
    end
  end

  def execute({:open_fire, code}), do: open_fire(code)
  def execute({:govern, %Batch{} = batch}), do: {:ok, govern(batch)}

  def execute({:overlay, job_id, item_id, change}) do
    with :ok <- permit(job_id),
         {:ok, pair} <- CvPair.bind(job_id),
         {:ok, _} <- write_line(pair, item_id, change) do
      after_cv_change(pair)
    end
  end

  def execute({:generation, job_id}) do
    with :ok <- permit(job_id),
         {:ok, pair} <- CvPair.bind(job_id),
         do: CvPair.open_generation(CvPair.employer_id(pair))
  end

  defp permit(job_id), do: Letterbox.permit_job(job_id, Ops.holder())

  # One row, one changeset, only while no agent holds the lease.
  # A set of plain columns is one statement that answers with the row.
  # A set of plain columns is one statement that answers with the row as
  # the sequencer ships it.
  defp write(job_id, attrs) do
    with :ok <- permit(job_id), do: Ops.write_row(:job_apps, job_id, Map.to_list(attrs))
  end

  @spec set_stage(pos_integer(), Pipeline.stage()) :: {:ok, Job.t()} | {:error, refusal()}
  def set_stage(job_id, stage), do: Ops.exec({:stage, job_id, stage})

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
    {:ok, result} = Ops.exec({:govern, batch})
    result
  end

  def govern_batch(code) when is_binary(code) do
    case Repo.get_by(Batch, code: code) do
      nil -> %{kept: [], deferred: []}
      batch -> govern_batch(batch)
    end
  end

  defp govern(%Batch{} = batch) do
    result = Heat.mix_batch(batch)
    Enum.each(result.deferred, fn {job, verdict} -> defer!(job, verdict) end)
    result
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
  def name_open_fire(code) when is_binary(code), do: Ops.exec({:open_fire, code})

  defp open_fire(code) do
    case Repo.get_by(Batch, code: code) do
      nil ->
        {:error, :batch}

      batch ->
        with {:ok, updated} <-
               batch |> Batch.changeset(%{fire: :open_fire, status: :open_fire}) |> Repo.update() do
          {:ok, updated}
        end
    end
  end

  @spec put_overlay(pos_integer(), pos_integer(), :inherit | map()) ::
          {:ok, Job.t()} | {:error, refusal() | Ecto.Changeset.t()}
  def put_overlay(job_id, item_id, change), do: Ops.exec({:overlay, job_id, item_id, change})

  defp write_line(pair, item_id, :inherit), do: CvPair.drop_line(pair, item_id)

  defp write_line(pair, item_id, attrs) when is_map(attrs),
    do: CvPair.tailor(pair, item_id, attrs)

  defp after_cv_change(pair), do: {:ok, Repo.get!(Job, CvPair.job_id(pair))}

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

  defp record!(job_id, kind, body) do
    %Event{}
    |> Event.changeset(%{job_app_id: job_id, kind: kind, body: body})
    |> Repo.insert!()
  end

  defp force_id(changeset, id) when is_integer(id), do: put_change(changeset, :id, id)
  defp force_id(changeset, nil), do: changeset
end
