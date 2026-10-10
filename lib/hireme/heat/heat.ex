defmodule Hireme.Heat.Config do
  @moduledoc """
  Caps, half-lives, size tiers, and ATS overrides for the heat governor.

  Defaults are the standing order. Documented in `alchemy/heat.md`.
  A test may pass a struct; the desk uses `Hireme.Heat.Config.defaults/0`.
  """

  @enforce_keys [
    :company_half_life,
    :ats_vendor_half_life,
    :ats_tenant_half_life,
    :application_load,
    :same_department_penalty,
    :clone_penalty,
    :mega_cap,
    :large_cap,
    :mid_cap,
    :small_cap,
    :ats_vendor_cap,
    :ats_tenant_cap,
    :ats_batch_cap
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          company_half_life: pos_integer(),
          ats_vendor_half_life: pos_integer(),
          ats_tenant_half_life: pos_integer(),
          application_load: float(),
          same_department_penalty: float(),
          clone_penalty: float(),
          mega_cap: float(),
          large_cap: float(),
          mid_cap: float(),
          small_cap: float(),
          ats_vendor_cap: float(),
          ats_tenant_cap: float(),
          ats_batch_cap: pos_integer()
        }

  @spec defaults() :: t()
  def defaults do
    %__MODULE__{
      # Days to lose half the company load. 30–45 window; 35 is the middle.
      company_half_life: 35,
      # Vendor-level ATS profiling across companies.
      ats_vendor_half_life: 14,
      # One Workday/Greenhouse tenant is usually one employer.
      ats_tenant_half_life: 21,
      # One queued/submitted/rejected application.
      application_load: 1.0,
      # Same department at one company is hotter than spreading orgs.
      same_department_penalty: 0.6,
      # Near-identical titles (same role family) stack worse than distinct tracks.
      clone_penalty: 0.6,
      # Google / Amazon / Meta / NVIDIA / Microsoft: a few roles if different orgs.
      mega_cap: 4.0,
      # Other big tech, labs, frontier.
      large_cap: 2.5,
      mid_cap: 1.5,
      # Default. One seat, maybe two after decay.
      small_cap: 1.0,
      # Decaying vendor cap so one ATS is not the whole campaign.
      ats_vendor_cap: 40.0,
      # Per-tenant cap (often one company).
      ats_tenant_cap: 3.0,
      # Hard mix: one day pack does not slam a single vendor.
      ats_batch_cap: 20
    }
  end
end

defmodule Hireme.Heat.Verdict do
  @moduledoc """
  One governor decision. `decision` is `:allow` or `:defer`.
  """

  @enforce_keys [
    :decision,
    :reason,
    :company,
    :company_load,
    :company_cap,
    :company_increment,
    :size,
    :ats_vendor,
    :ats_tenant,
    :vendor_load,
    :vendor_cap,
    :tenant_load,
    :tenant_cap,
    :cooldown_days,
    :note
  ]
  defstruct @enforce_keys

  @type reason ::
          :ok
          | :override
          | :company_cap
          | :ats_vendor_cap
          | :ats_tenant_cap
          | :ats_batch_cap

  @type t :: %__MODULE__{
          decision: :allow | :defer,
          reason: reason(),
          company: String.t(),
          company_load: float(),
          company_cap: float(),
          company_increment: float(),
          size: Hireme.Heat.Org.size(),
          ats_vendor: Hireme.Heat.Ats.vendor(),
          ats_tenant: String.t() | nil,
          vendor_load: float(),
          vendor_cap: float(),
          tenant_load: float(),
          tenant_cap: float(),
          cooldown_days: non_neg_integer() | nil,
          note: String.t()
        }
end

defmodule Hireme.Heat do
  @moduledoc """
  Structural heat governor. The pipeline must not snap onto a company or ATS.

  Per-company load rises with each application that is queued for submit
  (`fire_ready`, `open_fire`), submitted, in reply, or closed (rejected).
  It decays with the configured half-life. Caps scale with org size.
  Same-department and same-role-family applications cost extra.

  Per-ATS load is inferred from the apply URL. A batch mix also refuses
  more than `ats_batch_cap` of one vendor.

  Enforcement is in `mix/2`, `govern_batch/1`, and `Desk.set_stage/2`.
  FIRE HOLD still owns submit. This module only gates the queue.
  """

  import Ecto.Query
  alias Hireme.Desk.Batch
  alias Hireme.Desk.Event
  alias Hireme.Desk.Job
  alias Hireme.Heat.Ats
  alias Hireme.Heat.Config
  alias Hireme.Heat.Org
  alias Hireme.Heat.Verdict
  alias Hireme.Pipeline
  alias Hireme.Repo

  @hot_stages [:fire_ready, :open_fire, :submitted, :reply, :closed]
  # What `hot_jobs/0` reads of each hot job, besides its stage.
  @peer_fields [
    :id,
    :company,
    :role,
    :listing_url,
    :canonical_url,
    :department,
    :squad,
    :fit,
    :stage_on,
    :score_100,
    :heat_override,
    :heat_override_reason
  ]
  @queue_stages [:fire_ready, :open_fire, :submitted]

  @spec config() :: Config.t()
  def config, do: Config.defaults()

  @spec hot_stage?(term()) :: boolean()
  def hot_stage?(stage) when stage in @hot_stages, do: true
  def hot_stage?(_), do: false

  @spec entering?(Pipeline.stage(), Pipeline.stage()) :: boolean()
  def entering?(from, _to) when from in @hot_stages, do: false
  def entering?(_from, to) when to in @queue_stages, do: true
  def entering?(_, _), do: false

  @spec decay(number(), number(), pos_integer()) :: float()
  def decay(amount, days, _half_life) when days <= 0, do: amount * 1.0

  def decay(amount, days, half_life) when half_life > 0 do
    Float.round(amount * :math.pow(0.5, days / half_life), 4)
  end

  @spec cap(Org.size() | String.t(), Config.t()) :: float()
  def cap(size, %Config{} = cfg) when size in [:mega, :large, :mid, :small] do
    case size do
      :mega -> cfg.mega_cap
      :large -> cfg.large_cap
      :mid -> cfg.mid_cap
      :small -> cfg.small_cap
    end
  end

  def cap(company, %Config{} = cfg) when is_binary(company), do: cap(Org.size(company), cfg)

  @spec can_apply(pos_integer() | Job.t() | map(), keyword()) :: Verdict.t()
  def can_apply(job_id, opts \\ [])

  def can_apply(job_id, opts) when is_integer(job_id) do
    case Repo.get(Job, job_id) do
      nil ->
        %Verdict{
          decision: :defer,
          reason: :company_cap,
          company: "",
          company_load: 0.0,
          company_cap: 0.0,
          company_increment: 0.0,
          size: :small,
          ats_vendor: :unknown,
          ats_tenant: nil,
          vendor_load: 0.0,
          vendor_cap: 0.0,
          tenant_load: 0.0,
          tenant_cap: 0.0,
          cooldown_days: nil,
          note: "not_found"
        }

      job ->
        can_apply(job, opts)
    end
  end

  def can_apply(job, opts) when is_map(job) do
    today = Keyword.get(opts, :today, Date.utc_today())
    cfg = Keyword.get(opts, :config, config())
    existing = Keyword.get(opts, :existing) || hot_jobs()
    batch_kept = Keyword.get(opts, :batch_kept, [])
    evaluate(job, existing, batch_kept, today, cfg)
  end

  @spec mix([map()], keyword()) :: %{kept: [map()], deferred: [{map(), Verdict.t()}]}
  def mix(candidates, opts \\ []) when is_list(candidates) do
    today = Keyword.get(opts, :today, Date.utc_today())
    cfg = Keyword.get(opts, :config, config())
    existing = Keyword.get(opts, :existing, [])

    ordered =
      candidates
      |> Enum.sort_by(fn job ->
        {-score_of(job), Org.company_key(company_of(job)), id_of(job) || 0}
      end)

    ats = ats_index(existing ++ ordered)

    Enum.reduce(ordered, %{kept: [], deferred: []}, fn job, acc ->
      verdict = evaluate(job, existing, acc.kept, today, cfg, ats)

      if verdict.decision == :allow do
        %{acc | kept: acc.kept ++ [job]}
      else
        %{acc | deferred: [{job, verdict} | acc.deferred]}
      end
    end)
    |> Map.update!(:deferred, &Enum.reverse/1)
  end

  @spec mix_batch(Batch.t(), keyword()) :: %{kept: [Job.t()], deferred: [{Job.t(), Verdict.t()}]}
  def mix_batch(%Batch{} = batch, opts \\ []) do
    today = Keyword.get(opts, :today, Date.utc_today())
    members = Repo.all(from(j in Job, where: j.batch_id == ^batch.id))
    member_ids = MapSet.new(members, & &1.id)

    existing =
      hot_jobs()
      |> Enum.reject(&MapSet.member?(member_ids, &1.id))

    mix(members, Keyword.merge(opts, existing: existing, today: today))
  end

  defp override?(job) do
    truthy?(Map.get(job, :heat_override) || Map.get(job, "heat_override")) and
      String.trim(reason_of(job)) != ""
  end

  @doc "Let one application past the governor, with a written reason. Runs through `Hireme.Ops`."
  @spec set_override(pos_integer(), String.t()) :: {:ok, Job.t()} | {:error, :reason | :not_found}
  def set_override(job_id, reason), do: Hireme.Ops.exec({:heat_override, job_id, reason})

  @doc false
  # The write itself, on the account's `Hireme.Ops` process.
  @spec write_override(pos_integer(), term()) :: {:ok, Job.t()} | {:error, :reason | :not_found}
  def write_override(job_id, reason) when is_binary(reason) do
    case String.trim(reason) do
      "" ->
        {:error, :reason}

      trimmed ->
        case Repo.get(Job, job_id) do
          nil ->
            {:error, :not_found}

          job ->
            {:ok, updated} =
              job
              |> Job.changeset(%{heat_override: true, heat_override_reason: trimmed})
              |> Repo.update()

            %Event{}
            |> Event.changeset(%{
              job_app_id: job.id,
              kind: "heat",
              body: "HEAT OVERRIDE · #{trimmed}"
            })
            |> Repo.insert!()

            {:ok, updated}
        end
    end
  end

  def write_override(_, _), do: {:error, :reason}

  # Parse each distinct URL once per mix/snapshot, not once per candidate/peer.
  defp ats_index(jobs) do
    jobs |> Enum.map(&url_of/1) |> Enum.uniq() |> Map.new(&{&1, Ats.parse(&1)})
  end

  defp evaluate(job, existing, batch_kept, today, %Config{} = cfg, ats_index \\ nil) do
    peers = existing ++ batch_kept
    ats_index = ats_index || ats_index(peers)
    base = verdict_math(job, peers, batch_kept, today, cfg, ats_index)

    if override?(job),
      do: %{base | decision: :allow, reason: :override, note: "override · #{reason_of(job)}"},
      else: base
  end

  defp verdict_math(job, peers, batch_kept, today, cfg, ats_index) do
    ats = Ats.parse(url_of(job))
    size = Org.size(company_of(job))
    company_cap = cap(size, cfg)
    key = Org.company_key(company_of(job))
    others = Enum.reject(peers, &same_id?(&1, job))
    company_peers = Enum.filter(others, &(Org.company_key(company_of(&1)) == key))
    company_load = load(company_peers, today, cfg.company_half_life, cfg)
    increment = increment(job, company_peers, cfg)
    projected = round4(company_load + increment)
    {vendor_load, tenant_load} = ats_peer_loads(ats, others, today, cfg, ats_index)

    batch_vendor_n =
      Enum.count(
        batch_kept,
        &(ats.vendor != :unknown and ats_index[url_of(&1)].vendor == ats.vendor)
      )

    {decision, reason, note} =
      cond do
        ats.vendor != :unknown and batch_vendor_n >= cfg.ats_batch_cap ->
          {:defer, :ats_batch_cap,
           "ATS #{Ats.name(ats.vendor)} already #{batch_vendor_n} in this mix (cap #{cfg.ats_batch_cap})"}

        ats.vendor != :unknown and vendor_load + cfg.application_load > cfg.ats_vendor_cap ->
          {:defer, :ats_vendor_cap,
           "ATS vendor #{Ats.name(ats.vendor)} #{fmt(vendor_load)}/#{fmt(cfg.ats_vendor_cap)}"}

        ats.tenant && tenant_load + cfg.application_load > cfg.ats_tenant_cap ->
          {:defer, :ats_tenant_cap,
           "ATS tenant #{ats.tenant} #{fmt(tenant_load)}/#{fmt(cfg.ats_tenant_cap)}"}

        projected > company_cap ->
          {:defer, :company_cap,
           "#{company_of(job)} #{fmt(projected)}/#{fmt(company_cap)} (#{size}, +#{fmt(increment)})"}

        true ->
          {:allow, :ok, "ok"}
      end

    cooldown =
      case reason do
        :company_cap ->
          cooldown(company_load, increment, company_cap, cfg.company_half_life)

        :ats_vendor_cap ->
          cooldown(
            vendor_load,
            cfg.application_load,
            cfg.ats_vendor_cap,
            cfg.ats_vendor_half_life
          )

        :ats_tenant_cap ->
          cooldown(
            tenant_load,
            cfg.application_load,
            cfg.ats_tenant_cap,
            cfg.ats_tenant_half_life
          )

        _ ->
          nil
      end

    %Verdict{
      decision: decision,
      reason: reason,
      company: company_of(job),
      company_load: company_load,
      company_cap: company_cap,
      company_increment: increment,
      size: size,
      ats_vendor: ats.vendor,
      ats_tenant: ats.tenant,
      vendor_load: vendor_load,
      vendor_cap: cfg.ats_vendor_cap,
      tenant_load: tenant_load,
      tenant_cap: cfg.ats_tenant_cap,
      cooldown_days: cooldown,
      note: note
    }
  end

  defp ats_peer_loads(%{vendor: :unknown}, _others, _today, _cfg, _ats_index), do: {0.0, 0.0}

  defp ats_peer_loads(ats, others, today, cfg, ats_index) do
    vendor_peers = Enum.filter(others, &(ats_index[url_of(&1)].vendor == ats.vendor))

    tenant_peers =
      Enum.filter(
        vendor_peers,
        &(ats.tenant != nil and ats_index[url_of(&1)].tenant == ats.tenant)
      )

    {
      load(vendor_peers, today, cfg.ats_vendor_half_life, cfg),
      load(tenant_peers, today, cfg.ats_tenant_half_life, cfg)
    }
  end

  defp increment(_job, [], cfg), do: round4(cfg.application_load)

  defp increment(job, others, cfg) do
    base = cfg.application_load
    dept = Org.department(job)
    family = Org.family(job)

    same_dept? = Enum.any?(others, &(Org.department(&1) == dept))
    same_fam? = Enum.any?(others, &(Org.family(&1) == family))

    extra =
      if(same_dept?, do: cfg.same_department_penalty, else: 0.0) +
        if(same_fam?, do: cfg.clone_penalty, else: 0.0)

    round4(base + extra)
  end

  defp load(jobs, today, half_life, cfg) do
    jobs
    |> Enum.reduce(0, fn job, sum ->
      sum + decay(cfg.application_load, age(job, today), half_life)
    end)
    |> round4()
  end

  defp cooldown(load, increment, cap, half_life) do
    cond do
      increment > cap ->
        nil

      load + increment <= cap ->
        0

      load <= 0 ->
        0

      true ->
        room = cap - increment

        if room <= 0 do
          nil
        else
          days = half_life * :math.log2(load / room)
          max(0, ceil(days))
        end
    end
  end

  defp hot_jobs do
    Repo.all(
      from j in Job,
        where: j.current_stage in ^@hot_stages,
        order_by: j.id,
        select: map(j, ^[:current_stage | @peer_fields])
    )
  end

  defp age(job, today) do
    case Map.get(job, :stage_on) || Map.get(job, "stage_on") do
      %Date{} = date -> Date.diff(today, date)
      _ -> 0
    end
  end

  defp company_of(job), do: field(job, :company)
  defp url_of(job), do: field(job, :listing_url)
  defp reason_of(job), do: field(job, :heat_override_reason)
  defp score_of(job), do: Map.get(job, :score_100) || Map.get(job, "score_100") || 0
  defp id_of(job), do: Map.get(job, :id) || Map.get(job, "id")

  defp same_id?(a, b) do
    id_a = id_of(a)
    id_b = id_of(b)
    is_integer(id_a) and is_integer(id_b) and id_a == id_b
  end

  defp field(job, key) do
    case Map.get(job, key) || Map.get(job, Atom.to_string(key)) do
      s when is_binary(s) and s != "" ->
        s

      _ ->
        other = if key == :listing_url, do: Map.get(job, :canonical_url), else: nil
        if is_binary(other) and other != "", do: other, else: ""
    end
  end

  defp truthy?(true), do: true
  defp truthy?(1), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp round4(n) when is_integer(n), do: Float.round(n * 1.0, 4)
  defp round4(n) when is_float(n), do: Float.round(n, 4)

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
end
