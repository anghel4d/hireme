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
    :ats_batch_cap,
    :cool_ratio,
    :hot_ratio
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
          ats_batch_cap: pos_integer(),
          cool_ratio: float(),
          hot_ratio: float()
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
      ats_batch_cap: 20,
      cool_ratio: 0.5,
      hot_ratio: 0.8
    }
  end
end

defmodule Hireme.Heat.Verdict do
  @moduledoc """
  One governor decision. `decision` is `:allow` or `:defer`.
  """

  @reasons [
    :ok,
    :override,
    :company_cap,
    :ats_vendor_cap,
    :ats_tenant_cap,
    :ats_batch_cap
  ]

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

  @spec reasons() :: [reason()]
  def reasons, do: @reasons
end

defmodule Hireme.Heat.Chart do
  @moduledoc """
  Heatmap rows for companies and ATS vendors.
  """

  @enforce_keys [:companies, :vendors]
  defstruct @enforce_keys

  @type row :: %{
          key: String.t(),
          label: String.t(),
          load: float(),
          cap: float(),
          ratio: float(),
          n: non_neg_integer(),
          cooldown_days: non_neg_integer() | nil,
          size: atom() | nil
        }

  @type t :: %__MODULE__{companies: [row()], vendors: [row()]}
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
  alias Hireme.Heat.Chart
  alias Hireme.Heat.Config
  alias Hireme.Heat.Org
  alias Hireme.Heat.Verdict
  alias Hireme.Pipeline
  alias Hireme.Repo

  @hot_stages [:fire_ready, :open_fire, :submitted, :reply, :closed]
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

  @spec snapshot(Date.t(), Config.t()) :: map()
  def snapshot(today \\ Date.utc_today(), cfg \\ config()) do
    jobs = hot_jobs()
    build_snapshot(jobs, today, cfg)
  end

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

  @spec override?(map() | struct()) :: boolean()
  def override?(job) do
    truthy?(Map.get(job, :heat_override) || Map.get(job, "heat_override")) and
      String.trim(reason_of(job)) != ""
  end

  @spec set_override(pos_integer(), String.t()) :: {:ok, Job.t()} | {:error, :reason | :not_found}
  def set_override(job_id, reason) when is_binary(reason) do
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

  def set_override(_, _), do: {:error, :reason}

  @spec chart(Date.t(), Config.t()) :: Chart.t()
  def chart(today \\ Date.utc_today(), cfg \\ config()) do
    snap = snapshot(today, cfg)

    companies =
      snap.companies
      |> Enum.map(fn {key, row} ->
        chart_row(key, row.label, row, row.cap, row.size, cfg.company_half_life, cfg)
      end)
      |> Enum.sort_by(&{-&1.ratio, &1.label})

    vendors =
      snap.vendors
      |> Enum.map(fn {vendor, row} ->
        chart_row(
          Ats.name(vendor),
          Ats.name(vendor),
          row,
          cfg.ats_vendor_cap,
          nil,
          cfg.ats_vendor_half_life,
          cfg
        )
      end)
      |> Enum.reject(&(&1.key == "unknown"))
      |> Enum.sort_by(&{-&1.ratio, &1.label})

    %Chart{companies: companies, vendors: vendors}
  end

  @spec ascii(Chart.t()) :: String.t()
  def ascii(%Chart{} = chart) do
    """
    HEAT companies
    #{ascii_rows(chart.companies, 12)}
    HEAT ATS
    #{ascii_rows(chart.vendors, 8)}
    FIRE HOLD. Governor gates the queue. It does not submit.
    """
    |> String.trim()
  end

  @doc "Decorate a board while classifying each hot peer only once."
  @spec decorate_all([map()], map(), Config.t(), Date.t()) :: [map()]
  def decorate_all(cards, snapshot, cfg \\ config(), today \\ Date.utc_today()) do
    traits =
      Map.new(snapshot.jobs, fn job ->
        {id_of(job), {Org.department(job), Org.family(job)}}
      end)

    snapshot = Map.put(snapshot, :traits, traits)
    Enum.map(cards, &decorate(&1, snapshot, cfg, today))
  end

  @spec decorate(map(), map(), Config.t(), Date.t()) :: map()
  def decorate(card, snapshot, cfg \\ config(), today \\ Date.utc_today())

  def decorate(card, snapshot, cfg, today) do
    job = %{
      id: Map.get(card, :id),
      company: Map.get(card, :company),
      role: Map.get(card, :role),
      listing_url: Map.get(card, :listing_url) || "",
      canonical_url: Map.get(card, :canonical_url) || "",
      department: Map.get(card, :department) || "",
      squad: Map.get(card, :squad) || "",
      fit: Map.get(card, :fit) || "",
      current_stage: Map.get(card, :stage) || Map.get(card, :current_stage),
      stage_on: Map.get(card, :stage_on),
      score_100: Map.get(card, :score_100) || 0,
      heat_override: Map.get(card, :heat_override) || false,
      heat_override_reason: Map.get(card, :heat_override_reason) || ""
    }

    existing = Map.get(snapshot, :jobs, [])
    verdict = evaluate(job, existing, [], today, cfg, Map.get(snapshot, :ats), snapshot)
    ratio = ratio(verdict.company_load, verdict.company_cap)

    state =
      cond do
        verdict.decision == :defer -> :blocked
        ratio >= cfg.hot_ratio -> :hot
        ratio >= cfg.cool_ratio -> :warm
        true -> :cool
      end

    card
    |> Map.put(:load, verdict.company_load)
    |> Map.put(:cap, verdict.company_cap)
    |> Map.put(:heat_state, state)
    |> Map.put(:ats_vendor, verdict.ats_vendor)
    |> Map.put(:cooldown_days, verdict.cooldown_days)
  end

  @spec state_name(atom()) :: String.t()
  def state_name(state) when state in [:cool, :warm, :hot, :blocked, :all],
    do: Atom.to_string(state)

  @spec parse_state(term()) :: {:ok, atom()} | :error
  def parse_state(state), do: Hireme.Closed.parse([:all, :cool, :warm, :hot, :blocked], state)

  defp chart_row(key, label, row, cap, size, half_life, cfg) do
    %{
      key: key,
      label: label,
      load: row.load,
      cap: cap,
      size: size,
      n: row.n,
      ratio: ratio(row.load, cap),
      cooldown_days: cooldown(row.load, cfg.application_load, cap, half_life)
    }
  end

  defp ascii_rows([], _limit), do: "(none)"

  defp ascii_rows(rows, limit) do
    rows
    |> Enum.take(limit)
    |> Enum.map_join("\n", fn row ->
      "#{String.pad_trailing(row.label, 22)} #{fmt(row.load)}/#{fmt(row.cap)}  n=#{row.n}"
    end)
  end

  # Parse each distinct URL once per mix/snapshot, not once per candidate/peer.
  defp ats_index(jobs) do
    jobs |> Enum.map(&url_of/1) |> Enum.uniq() |> Map.new(&{&1, Ats.parse(&1)})
  end

  defp evaluate(
         job,
         existing,
         batch_kept,
         today,
         %Config{} = cfg,
         ats_index \\ nil,
         snapshot \\ nil
       ) do
    peers = existing ++ batch_kept
    ats_index = ats_index || ats_index(peers)
    base = verdict_math(job, peers, batch_kept, today, cfg, ats_index, snapshot)

    if override?(job),
      do: %{base | decision: :allow, reason: :override, note: "override · #{reason_of(job)}"},
      else: base
  end

  defp verdict_math(job, peers, batch_kept, today, cfg, ats_index, snapshot) do
    ats = Ats.parse(url_of(job))
    size = Org.size(company_of(job))
    company_cap = cap(size, cfg)
    key = Org.company_key(company_of(job))
    others = if is_nil(snapshot), do: Enum.reject(peers, &same_id?(&1, job)), else: []

    company_peers =
      case snapshot do
        nil ->
          Enum.filter(others, &(Org.company_key(company_of(&1)) == key))

        %{companies: companies} ->
          companies
          |> Map.get(key, %{jobs: []})
          |> Map.fetch!(:jobs)
          |> Enum.reject(&same_id?(&1, job))
      end

    company_load = load(company_peers, today, cfg.company_half_life, cfg)
    increment = increment(job, company_peers, cfg, snapshot && Map.get(snapshot, :traits))
    projected = round4(company_load + increment)

    vendor_peers =
      case snapshot do
        nil ->
          Enum.filter(
            others,
            &(ats.vendor != :unknown and ats_index[url_of(&1)].vendor == ats.vendor)
          )

        %{vendors: vendors} ->
          vendors
          |> Map.get(ats.vendor, %{jobs: []})
          |> Map.fetch!(:jobs)
          |> Enum.reject(&same_id?(&1, job))
      end

    tenant_peers =
      Enum.filter(
        vendor_peers,
        &(ats.tenant != nil and ats_index[url_of(&1)].tenant == ats.tenant)
      )

    vendor_load = load(vendor_peers, today, cfg.ats_vendor_half_life, cfg)
    tenant_load = load(tenant_peers, today, cfg.ats_tenant_half_life, cfg)

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

  defp increment(_job, [], cfg, _traits), do: round4(cfg.application_load)

  defp increment(job, others, cfg, traits) do
    base = cfg.application_load
    dept = Org.department(job)
    family = Org.family(job)

    same_dept? = Enum.any?(others, &(peer_department(&1, traits) == dept))
    same_fam? = Enum.any?(others, &(peer_family(&1, traits) == family))

    extra =
      if(same_dept?, do: cfg.same_department_penalty, else: 0.0) +
        if(same_fam?, do: cfg.clone_penalty, else: 0.0)

    round4(base + extra)
  end

  defp peer_department(job, nil), do: Org.department(job)
  defp peer_department(job, traits), do: elem(Map.fetch!(traits, id_of(job)), 0)
  defp peer_family(job, nil), do: Org.family(job)
  defp peer_family(job, traits), do: elem(Map.fetch!(traits, id_of(job)), 1)

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

  defp build_snapshot(jobs, today, cfg) do
    ats = ats_index(jobs)

    companies =
      jobs
      |> Enum.group_by(&Org.company_key(company_of(&1)))
      |> Map.new(fn {key, group} ->
        label = company_of(hd(group))
        size = Org.size(label)

        {key,
         %{
           label: label,
           size: size,
           load: load(group, today, cfg.company_half_life, cfg),
           cap: cap(size, cfg),
           n: length(group),
           jobs: group
         }}
      end)

    vendors =
      jobs
      |> Enum.reject(&(ats[url_of(&1)].vendor == :unknown))
      |> Enum.group_by(&ats[url_of(&1)].vendor)
      |> Map.new(fn {vendor, group} ->
        {vendor,
         %{load: load(group, today, cfg.ats_vendor_half_life, cfg), n: length(group), jobs: group}}
      end)

    %{jobs: jobs, companies: companies, vendors: vendors, ats: ats}
  end

  defp hot_jobs do
    Repo.all(
      from j in Job,
        where: j.current_stage in ^@hot_stages,
        select:
          map(j, [
            :id,
            :company,
            :role,
            :listing_url,
            :canonical_url,
            :department,
            :squad,
            :fit,
            :current_stage,
            :stage_on,
            :score_100,
            :heat_override,
            :heat_override_reason
          ])
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

  defp ratio(_load, cap) when cap <= 0, do: 1.0
  defp ratio(load, cap), do: round4(load / cap)

  defp round4(n) when is_integer(n), do: Float.round(n * 1.0, 4)
  defp round4(n) when is_float(n), do: Float.round(n, 4)

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp fmt(n), do: to_string(n)
end
