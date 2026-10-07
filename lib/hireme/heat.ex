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

    Enum.reduce(ordered, %{kept: [], deferred: []}, fn job, acc ->
      verdict = evaluate(job, existing, acc.kept, today, cfg)

      if verdict.decision == :allow do
        %{acc | kept: acc.kept ++ [job]}
      else
        %{acc | deferred: acc.deferred ++ [{job, verdict}]}
      end
    end)
  end

  @spec mix_batch(Batch.t(), keyword()) :: %{kept: [Job.t()], deferred: [{Job.t(), Verdict.t()}]}
  def mix_batch(%Batch{} = batch, opts \\ []) do
    today = Keyword.get(opts, :today, Date.utc_today())
    members = Repo.all(from j in Job, where: j.batch_id == ^batch.id)
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
        %{
          key: key,
          label: row.label,
          load: row.load,
          cap: row.cap,
          ratio: ratio(row.load, row.cap),
          n: row.n,
          cooldown_days: cooldown(row.load, cfg.application_load, row.cap, cfg.company_half_life),
          size: row.size
        }
      end)
      |> Enum.sort_by(&{-&1.ratio, &1.label})

    vendors =
      snap.vendors
      |> Enum.map(fn {vendor, row} ->
        %{
          key: Ats.name(vendor),
          label: Ats.name(vendor),
          load: row.load,
          cap: cfg.ats_vendor_cap,
          ratio: ratio(row.load, cfg.ats_vendor_cap),
          n: row.n,
          cooldown_days:
            cooldown(row.load, cfg.application_load, cfg.ats_vendor_cap, cfg.ats_vendor_half_life),
          size: nil
        }
      end)
      |> Enum.reject(&(&1.key == "unknown"))
      |> Enum.sort_by(&{-&1.ratio, &1.label})

    %Chart{companies: companies, vendors: vendors}
  end

  @spec ascii(Chart.t()) :: String.t()
  def ascii(%Chart{} = chart) do
    companies =
      chart.companies
      |> Enum.take(12)
      |> Enum.map_join("\n", fn row ->
        "#{String.pad_trailing(row.label, 22)} #{fmt(row.load)}/#{fmt(row.cap)}  n=#{row.n}"
      end)

    vendors =
      chart.vendors
      |> Enum.take(8)
      |> Enum.map_join("\n", fn row ->
        "#{String.pad_trailing(row.label, 22)} #{fmt(row.load)}/#{fmt(row.cap)}  n=#{row.n}"
      end)

    companies = if companies == "", do: "(none)", else: companies
    vendors = if vendors == "", do: "(none)", else: vendors

    """
    HEAT companies
    #{companies}
    HEAT ATS
    #{vendors}
    FIRE HOLD. Governor gates the queue. It does not submit.
    """
    |> String.trim()
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
    verdict = evaluate(job, existing, [], today, cfg)
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
  def parse_state(:all), do: {:ok, :all}
  def parse_state("all"), do: {:ok, :all}

  def parse_state(state) when state in [:cool, :warm, :hot, :blocked], do: {:ok, state}

  def parse_state(name) when is_binary(name) do
    case name do
      "cool" -> {:ok, :cool}
      "warm" -> {:ok, :warm}
      "hot" -> {:ok, :hot}
      "blocked" -> {:ok, :blocked}
      _ -> :error
    end
  end

  def parse_state(_), do: :error

  defp evaluate(job, existing, batch_kept, today, %Config{} = cfg) do
    if override?(job) do
      base = verdict_math(job, existing, batch_kept, today, cfg)
      %{base | decision: :allow, reason: :override, note: "override · #{reason_of(job)}"}
    else
      verdict_math(job, existing, batch_kept, today, cfg)
    end
  end

  defp verdict_math(job, existing, batch_kept, today, cfg) do
    ats = Ats.parse(url_of(job))
    size = Org.size(company_of(job))
    company_cap = cap(size, cfg)
    key = Org.company_key(company_of(job))
    peers = Enum.filter(existing ++ batch_kept, &(Org.company_key(company_of(&1)) == key))
    others = Enum.reject(peers, &same_id?(&1, job))

    company_load = company_load(others, today, cfg)
    increment = increment(job, others, cfg)
    projected = round4(company_load + increment)

    vendor_peers =
      Enum.filter(existing ++ batch_kept, fn other ->
        Ats.parse(url_of(other)).vendor == ats.vendor and ats.vendor != :unknown
      end)
      |> Enum.reject(&same_id?(&1, job))

    tenant_peers =
      if ats.tenant do
        Enum.filter(vendor_peers, &(Ats.parse(url_of(&1)).tenant == ats.tenant))
      else
        []
      end

    vendor_load = ats_load(vendor_peers, today, cfg.ats_vendor_half_life, cfg)
    tenant_load = ats_load(tenant_peers, today, cfg.ats_tenant_half_life, cfg)

    batch_vendor_n =
      Enum.count(
        batch_kept,
        &(Ats.parse(url_of(&1)).vendor == ats.vendor and ats.vendor != :unknown)
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

  defp company_load(jobs, today, cfg) do
    jobs
    |> Enum.map(fn job -> decay(cfg.application_load, age(job, today), cfg.company_half_life) end)
    |> Enum.sum()
    |> round4()
  end

  defp ats_load(jobs, today, half_life, cfg) do
    jobs
    |> Enum.map(fn job -> decay(cfg.application_load, age(job, today), half_life) end)
    |> Enum.sum()
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
           load: company_load(group, today, cfg),
           cap: cap(size, cfg),
           n: length(group)
         }}
      end)

    vendors =
      jobs
      |> Enum.map(&{&1, Ats.parse(url_of(&1))})
      |> Enum.reject(fn {_job, ats} -> ats.vendor == :unknown end)
      |> Enum.group_by(fn {_job, ats} -> ats.vendor end)
      |> Map.new(fn {vendor, group} ->
        members = Enum.map(group, &elem(&1, 0))

        {vendor,
         %{
           load: ats_load(members, today, cfg.ats_vendor_half_life, cfg),
           n: length(members)
         }}
      end)

    %{jobs: jobs, companies: companies, vendors: vendors}
  end

  defp hot_jobs do
    Repo.all(from j in Job, where: j.current_stage in ^@hot_stages)
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
