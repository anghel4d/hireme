defmodule Hireme.Oracle do
  @moduledoc """
  The reference the client's predictions are checked against: for one
  account and one pinned day, the raw tables a session ships, the raw
  delta and refusal of each op run over them, and the heat decisions the
  server makes from them, as JSON lines. The kernel replays the ops from
  the same tables and compares.

  Run it with `test/oracle/run.exs`. Values are plain JSON: a date is its
  day number since 1970-01-01, a datetime its unix second, an atom its
  name, a struct its fields (Ecto meta and unloaded associations
  dropped), a float Jason's shortest round-trip form.

  `generate/2` writes a seeded random desk aimed at the derivations'
  edges; `ops/2` a seeded random op sequence over it.
  """

  import Ecto.Query

  alias Hireme.Corpus
  alias Hireme.Desk
  alias Hireme.Desk.Batch
  alias Hireme.Desk.Employer
  alias Hireme.Desk.Event
  alias Hireme.Desk.Job
  alias Hireme.Desk.Overlay
  alias Hireme.Desk.Snapshot
  alias Hireme.Desk.Variant
  alias Hireme.Cv.Lineage
  alias Hireme.Gym
  alias Hireme.Heat
  alias Hireme.Kv
  alias Hireme.Net
  alias Hireme.Ops
  alias Hireme.Pipeline
  alias Hireme.Repo

  @epoch ~D[1970-01-01]

  # -- the dump ---------------------------------------------------------------

  @doc """
  The tables of the account on this process, the ops run over them, and
  what the server still decides from them on `today`: each job's heat
  verdict (a stage write's refusal) and each batch's mix (its deferrals).
  """
  @spec dump(Date.t(), keyword()) :: [map()]
  def dump(today, opts \\ []) do
    jobs = Repo.all(from j in Job, order_by: j.id)

    meta = %{
      kind: "meta",
      today: day(today),
      rev: Repo.one!(rev_query(), skip_account: true),
      account: Repo.account_id!(),
      seed: Keyword.get(opts, :seed)
    }

    [meta] ++
      Keyword.get(opts, :before, []) ++
      tables("table") ++
      Keyword.get(opts, :ops, []) ++
      Enum.map(jobs, fn job ->
        Map.merge(%{kind: "verdict", id: job.id}, plain(Heat.can_apply(job, today: today)))
      end) ++
      Enum.map(Desk.list_batches(), &mix_batch(&1, today))
  end

  @doc """
  The raw tables as `kind` lines, rows in id order: `"table"` for the
  dumped state, `"table_before"` for the state an op sequence starts from.
  """
  @spec tables(String.t()) :: [map()]
  def tables(kind) do
    Ops.read_tables()
    |> Enum.sort()
    |> Enum.map(fn {name, rows} ->
      %{
        kind: kind,
        table: name,
        rows: rows |> Enum.sort_by(& &1.id) |> Enum.map(&typed(name, &1))
      }
    end)
  end

  # The sequencer ships rows as SQLite holds them; the oracle writes them
  # typed (a date its day number, a map decoded), as it always has.
  @schemas Map.new(
             [Job, Corpus.Profile, Corpus.Item, Variant, Lineage, Overlay, Batch, Event, Kv.Pair] ++
               [Corpus.Narrative, Snapshot, Gym.Problem, Gym.Rep, Net.Entry],
             &{String.to_atom(&1.__schema__(:source)), &1}
           )

  defp typed(table, row) do
    case Map.fetch(@schemas, table) do
      {:ok, schema} ->
        Map.new(row, fn {col, value} ->
          type = schema.__schema__(:type, col)
          {:ok, loaded} = Ecto.Type.adapter_load(Repo.__adapter__(), type, value)
          {col, loaded}
        end)

      :error ->
        row
    end
  end

  defp typed_rows(rows), do: Map.new(rows, fn {t, list} -> {t, Enum.map(list, &typed(t, &1))} end)

  defp rev_query do
    from a in Hireme.Accounts.Account, where: a.id == ^Repo.account_id!(), select: a.desk_rev
  end

  defp mix_batch(%Batch{} = batch, today) do
    result = Heat.mix_batch(batch, today: today)

    %{
      kind: "mix_batch",
      code: batch.code,
      kept: Enum.map(result.kept, & &1.id),
      deferred: Enum.map(result.deferred, fn {job, v} -> Map.put(plain(v), "id", job.id) end)
    }
  end

  @doc "One line as JSON text, values made plain."
  @spec encode(map()) :: iodata()
  def encode(line), do: Jason.encode_to_iodata!(plain(line))

  @doc "A value as plain JSON terms."
  def plain(%Date{} = d), do: day(d)
  def plain(%DateTime{} = t), do: DateTime.to_unix(t)
  def plain(%NaiveDateTime{} = t), do: t |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
  def plain(%Ecto.Association.NotLoaded{}), do: nil

  def plain(%{__struct__: _} = struct),
    do: struct |> Map.from_struct() |> Map.drop([:__meta__]) |> plain()

  def plain(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), plain(v)} end)
  def plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  def plain(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> plain()
  def plain(atom) when atom in [nil, true, false], do: atom
  def plain(atom) when is_atom(atom), do: Atom.to_string(atom)
  def plain(other), do: other

  defp day(%Date{} = d), do: Date.diff(d, @epoch)

  # -- the seeded desk --------------------------------------------------------

  @companies [
    "Google",
    "Alphabet Inc.",
    "Meta Platforms",
    "NVIDIA",
    "Microsoft",
    "go ogle",
    "megagoogle",
    "OpenAI",
    "Anthropic, PBC",
    "Deep-Mind",
    "Stripe",
    "X.AI",
    "Acme Labs",
    "Runtime Systems GmbH",
    "Zürich Infra AG",
    "A Small Lab",
    "Café Rust",
    "Obscure Shop LLC",
    "  Padded  Co ",
    "Ünïcode Ünlimited"
  ]

  @roles [
    "Software Engineer",
    "Senior Software Engineer II",
    "Staff Research Engineer",
    "Research Scientist",
    "Applied Scientist, L5",
    "Site Reliability Engineer",
    "SRE",
    "Data Engineer",
    "Security Engineer",
    "Frontend Developer",
    "iOS Engineer",
    "Product Engineer",
    "Machine Learning Engineer",
    "Kernel Developer (Rust)",
    "Intern, SWE",
    "Account Manager",
    "  staff   SWE  "
  ]

  @departments [
    "",
    "",
    "Infrastructure",
    "ML",
    "Security",
    "Data",
    "Mobile",
    "Engineering",
    "Sales",
    " eng "
  ]

  @urls [
    "https://boards.greenhouse.io/acme/jobs/1",
    "https://job-boards.greenhouse.io/globex/jobs/2",
    "https://acme.greenhouse.net/careers/3",
    "HTTPS://BOARDS.GREENHOUSE.IO/Upper/jobs/4",
    "https://jobs.lever.co/initech/abc",
    "https://lever.co/",
    "https://jobs.ashbyhq.com/anthropic/role",
    "https://nvidia.wd5.myworkdayjobs.com/NVIDIAExternal/job/x",
    "https://acme.myworkdayjobs.com/en-US/careers",
    "https://foo.wd1.myworkdaysite.com/recruiting/foo/jobs",
    "https://careers-acme.icims.com/jobs/1",
    "https://www.icims.com/jobs/2",
    "https://jobs.smartrecruiters.com/Acme/123",
    "https://apply.workable.com/acme/j/1",
    "https://jobs.jobvite.com/acme/job/1",
    "https://acme.taleo.net/careersection/1",
    "https://career5.successfactors.eu/career?company=acme",
    "https://acme.sapsf.com/jobs",
    "https://acme.bamboohr.com/careers/1",
    "https://ats.rippling.com/acme/jobs/1",
    "https://acme.eightfold.ai/careers",
    "https://jobs.gem.com/acme/1",
    "https://example.com/careers/1",
    "not a url",
    "ftp://files.example.com/x",
    ""
  ]

  @words ~w(rust c++ c# .net kubernetes distributed systems latency kernel compiler agents
            python typescript wasm infra storage the and with team golang erlang elixir
            postgres sqlite tracing observability Ünïcode café)

  @doc "Write a seeded random desk for the account on this process, around `today`."
  @spec generate(integer(), Date.t()) :: :ok
  def generate(seed, today) do
    {:ok, :ok} = Ops.exec({:bulk, fn -> write_desk(seed, today) end})
    :ok
  end

  defp write_desk(seed, today) do
    :rand.seed(:exsss, {seed, seed * 31 + 7, seed * 101 + 3})
    user = Hireme.Narrative.create_user!(%{name: "Seed #{seed}"})
    Hireme.Narrative.write!(user, pick(["A private narrative.", "Ünïcode — narrative."]))
    if chance(0.8), do: Kv.put("global", "candidate", pick(["Ada Lovelace", "Zoë Ü"]))
    if chance(0.7), do: Kv.put("gym", "daily_target", pick(["1", "3", "30", "31", "0", "x"]))

    if chance(0.7),
      do: Kv.put("net", "broadside_lane", pick(["https://broadside.example/lane", ""]))

    profiles =
      for n <- 1..rand(1, 3)//1 do
        Corpus.create_profile!(%{
          slug: "p#{n}",
          name: "Profile #{n}",
          headline: pick(["Engineer", "Systems person"]),
          summary: sentence(),
          user_id: user.id
        })
      end

    items =
      for profile <- [nil | profiles], n <- 1..rand(2, 7)//1 do
        Corpus.create_item!(%{
          profile_id: profile && profile.id,
          kind: pick([:experience, :project, :education, :skill, :timeline, :fact]),
          key: "k#{(profile && profile.id) || 0}.#{n}",
          title: sentence(3),
          body: sentence(),
          org: pick(["", "Acme", "Café"]),
          span: pick(["", "2020–2024"]),
          position: rand(0, 5),
          keywords: Enum.take_random(@words, rand(0, 3))
        })
      end

    for _ <- 1..rand(0, 2)//1 do
      Repo.insert!(
        Snapshot.changeset(%Snapshot{}, %{
          noted_on: Date.add(today, -rand(0, 20)),
          leftover_unique: rand(0, 5000),
          target_total: rand(1000, 20_000),
          target_on: pick([nil, Date.add(today, rand(10, 90))]),
          daily_batches: rand(1, 10),
          daily_apps: rand(10, 500),
          note: ""
        })
      )
    end

    batches =
      for n <- 1..rand(1, 4)//1 do
        fire = pick([:hold, :open_fire])

        Repo.insert!(
          Batch.changeset(%Batch{}, %{
            code: "B-#{seed}-#{n}",
            ordinal: n,
            kind: pick([:day_pack, :leftover, :universe_gaps, :linkedin]),
            status:
              if(fire == :open_fire, do: :open_fire, else: pick([:draft_prep, :fire_ready])),
            fire: fire,
            target_size: pick([5, 55]),
            queued_on: pick([today, Date.add(today, -1), nil]),
            squad: pick(["", "infra"])
          })
        )
      end

    lineages =
      @companies
      |> Enum.take_random(rand(4, length(@companies)))
      |> Map.new(fn company ->
        employer = Repo.insert!(Employer.changeset(%Employer{}, %{name: company}))

        lineage =
          Repo.insert!(
            Lineage.changeset(%Lineage{}, %{
              employer_id: employer.id,
              generation: rand(1, 3),
              opened_on: Date.add(today, -rand(0, 200)),
              rewrites_allowed: chance(0.5),
              theme: theme()
            })
          )

        {company, {employer, lineage}}
      end)

    for n <- 1..rand(25, 70)//1 do
      {company, {employer, lineage}} = Enum.random(lineages)
      profile = Enum.random(profiles)
      stage = pick(Pipeline.keys())

      job =
        Repo.insert!(
          Job.changeset(%Job{}, %{
            profile_id: profile.id,
            employer_id: employer.id,
            batch_id: if(chance(0.4), do: Enum.random(batches).id),
            company: company,
            role: pick(@roles),
            location: pick(["", "Remote", "Montréal, QC", "onsite only, no remote"]),
            listing_url: pick(@urls),
            canonical_url: "https://canon.example/#{seed}/#{n}",
            listing: sentence(rand(0, 60)),
            heat: rand(1, 5),
            status: pick(Job.statuses()),
            next_action: pick(["", "Call back", "FIRE HOLD · B-1"]),
            next_due: pick([nil, Date.add(today, rand(-5, 20))]),
            stage_on: pick([nil, Date.add(today, rand(-400, 5))]),
            current_stage: stage,
            pips: Pipeline.encode(Pipeline.move_to(Pipeline.initial(:discovered), stage)),
            stage_notes: pick([%{}, %{"gated" => "pursue", "reply" => "Ünïcode"}]),
            freshness: pick([:unknown, :open, :thin, :closed, :blocked]),
            gate: pick([:unset, :pursue, :maybe, :skip]),
            fit: pick(["", "strong fit", "research"]),
            squad: pick(["", "kernel", "agents"]),
            department: pick(@departments),
            score_100: pick([0, 1, 49, 50, 69, 70, 84, 85, 99, 100, rand(0, 100)]),
            heat_override: chance(0.15),
            heat_override_reason: pick(["", "  ", "warm intro"])
          })
        )

      Repo.insert!(
        Variant.changeset(%Variant{}, %{
          job_app_id: job.id,
          profile_id: profile.id,
          lineage_id: lineage.id,
          label: "CV#{job.id}",
          theme: theme(),
          note: ""
        })
      )

      for _ <- 1..rand(0, 3)//1 do
        Repo.insert!(
          Event.changeset(%Event{}, %{
            job_app_id: job.id,
            kind: pick(["open", "stage", "heat"]),
            body: sentence(4)
          })
        )
      end

      if chance(0.2), do: Kv.put("app:#{job.id}", pick(["contact", "salary"]), sentence(2))

      # Overlays live on the lineage; the first job on it names them.
      if chance(0.4) do
        for item <- Enum.take_random(items, rand(1, 3)) do
          mode = pick([:hidden, :altered, :emphasized])

          Repo.insert(
            Overlay.changeset(%Overlay{}, %{
              job_app_id: job.id,
              item_id: item.id,
              lineage_id: lineage.id,
              mode: mode,
              title: if(mode == :altered and chance(0.5), do: sentence(3)),
              body: if(mode == :altered, do: sentence()),
              reason: pick([nil, "fits"]),
              generation: lineage.generation
            })
          )
        end
      end
    end

    problems =
      for n <- 1..rand(0, 8)//1 do
        Repo.insert!(
          Gym.Problem.changeset(%Gym.Problem{}, %{
            platform: pick([:leetcode, :codeforces, :other]),
            slug: "p-#{n}",
            title: "Problem #{n}",
            topic: pick([:arrays, :graphs, :strings, :dp, :trees, :systems, :other]),
            difficulty: pick([:easy, :medium, :hard, :unknown]),
            url: ""
          })
        )
      end

    for _ <- 1..rand(0, 25)//1, problems != [] do
      Repo.insert!(
        Gym.Rep.changeset(%Gym.Rep{}, %{
          problem_id: Enum.random(problems).id,
          done_on: Date.add(today, -rand(0, 40)),
          minutes: rand(0, 90),
          outcome: pick([:solved, :attempt, :skip]),
          note: ""
        })
      )
    end

    for _ <- 1..rand(0, 10)//1 do
      kind = pick(Net.kinds())

      Repo.insert!(
        Net.Entry.changeset(%Net.Entry{}, %{
          kind: kind,
          channel: pick(Net.channels()),
          title: sentence(3),
          url: pick(["", "https://x.example/1"]),
          body: "",
          shipped_on: if(kind == :draft, do: nil, else: Date.add(today, -rand(0, 40)))
        })
      )
    end

    :ok
  end

  @doc """
  `n` seeded random client ops over the account's desk, run through
  `Hireme.Ops.run/2`; each comes back as an `op` line with its result
  and the raw rows its delta carried.
  """
  @spec ops(integer(), non_neg_integer()) :: [map()]
  def ops(seed, n) do
    :rand.seed(:exsss, {seed * 7, seed + 11, seed * 13 + 5})
    account = Repo.account_id!()
    jobs = Repo.all(from j in Job, select: j.id)
    items = Repo.all(from i in Corpus.Item, select: i.id)
    codes = Repo.all(from b in Batch, select: b.code)
    narratives = Repo.all(from r in Corpus.Narrative, select: r.id)
    :ok = Phoenix.PubSub.subscribe(Hireme.PubSub, Desk.topic(account))

    for k <- 1..n//1, jobs != [] do
      op = op(seed * 100_000 + k, jobs, items, codes, narratives)

      {result, delta} =
        case Ops.run(account, op) do
          {:ok, rev} ->
            receive do
              {:ops_delta, ^rev, delta} -> {%{ok: rev}, Map.take(delta, [:rows, :gone])}
            after
              5_000 -> raise "no delta for #{rev}"
            end

          {:error, {:argument, name}} ->
            {%{error: "argument", argument: name}, %{rows: %{}, gone: %{}}}

          {:error, reason} ->
            {%{error: reason}, %{rows: %{}, gone: %{}}}
        end

      flush()
      %{kind: "op", op: op, result: result, rows: typed_rows(delta.rows), gone: delta.gone}
    end
  end

  defp flush do
    receive do
      {:desk_event, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp op(op_id, jobs, items, codes, narratives) do
    job = Enum.random(jobs)

    {kind, target, fields} =
      case rand(1, 12) do
        1 ->
          {:stage, job, [pick(Enum.map(Pipeline.keys(), &Pipeline.name/1) ++ ["nope"])]}

        2 ->
          {:next, job, [sentence(2), pick(["", "2026-11-03", "bad"])]}

        3 ->
          {:note, job, [Pipeline.name(pick(Pipeline.keys())), sentence(2)]}

        4 ->
          {:score, job, [pick(["0", "55", "100", "101", "x"])]}

        5 ->
          {:overlay, job,
           [
             "#{pick(items ++ [999_999])}",
             pick(~w(hidden emphasized altered inherit bogus)),
             pick(["", "Rewritten"]),
             ""
           ]}

        6 ->
          {:heat_override, job, [pick(["", "warm intro"])]}

        7 ->
          {:open_fire, 0, [pick(codes ++ ["missing"])]}

        8 ->
          {:narrative, pick(narratives ++ [999_999]), [sentence(3)]}

        9 ->
          {:gym_log, 0, ["title", "Two sum", "slug", pick(["two-sum", "p-1"]), "minutes", "15"]}

        10 ->
          {:gym_target, 0, [pick(["5", "40", "x"])]}

        11 ->
          {:net_log, 0, ["kind", pick(["post", "draft", "nope"]), "title", "Shipped"]}

        12 ->
          {:stage, job, [pick(~w(fire_ready open_fire submitted reply closed gated))]}
      end

    %{op_id: op_id, kind: kind, target: target, fields: fields}
  end

  defp theme do
    pick([
      %{},
      %{"accent" => "signal", "density" => "tight"},
      %{"targets" => Enum.take_random(@words, 3), "lead" => "Systems", "accent" => "bogus"}
    ])
  end

  defp sentence(n \\ 12), do: Enum.map_join(1..max(n, 1)//1, " ", fn _ -> pick(@words) end)
  defp pick(list), do: Enum.random(list)
  defp rand(lo, hi), do: lo + :rand.uniform(hi - lo + 1) - 1
  defp chance(p), do: :rand.uniform() < p
end
