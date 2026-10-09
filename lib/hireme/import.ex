defmodule Hireme.Import.Report do
  @moduledoc "What one import did. `kind` is the shape that was recognised."

  @enforce_keys [:kind, :count]
  defstruct [:kind, :count, :source, :wave, :nested]

  @type kind :: :snapshot | :claims | :batches | :apps | :freshness

  @type t :: %__MODULE__{
          kind: kind(),
          count: non_neg_integer(),
          source: String.t() | nil,
          wave: String.t() | nil,
          nested: t() | nil
        }
end

defmodule Hireme.Import do
  @moduledoc """
  Idempotent ingest for application packs.

  The same canonical job URL updates the existing card. A second import
  does not mint a second application.
  Nonempty URL lookups use the account-scoped partial unique index; rows
  still commit individually, so a later invalid row leaves earlier imports intact.

  Accepted shapes:

  * batch pack — `{batch, status, fire, apps: [...]}`, or a markdown table
  * leftover pursue table — `Company | Role | Location | Fit | Source | URL`, optional `Score`
  * any application row may carry `score_100` (or `score`), an integer 0–100
  * freshness note — OPEN/THIN/CLOSED/BLOCKED counts and URL lists
  * scoreboard snapshot — `{noted_on, leftover_unique, ...}`
  * claims — `{"claims": [{"squad", "slice", "note"}]}`

  Stage names in a pack are parsed once by `Hireme.Pipeline.parse/1`.
  An unknown stage is an error for that pack, not a silent default.

  Passwords are never read or stored.
  """

  import Ecto.Query
  alias Hireme.Corpus.Profile
  alias Hireme.Desk
  alias Hireme.Desk.Batch
  alias Hireme.Desk.Claim
  alias Hireme.Desk.Employer
  alias Hireme.Desk.FreshnessVerdict
  alias Hireme.Desk.Job
  alias Hireme.Desk.Snapshot
  alias Hireme.Import.Report
  alias Hireme.LifeEv
  alias Hireme.Pipeline
  alias Hireme.Repo

  @type result :: {:ok, Report.t()} | {:error, :unrecognized}

  @verdicts ~w(open thin closed blocked)a

  @spec import_path(Path.t(), keyword()) :: result()
  def import_path(path, opts \\ []) do
    profile = Keyword.get(opts, :profile) || default_profile!()
    import_body(File.read!(path), Path.basename(path), profile)
  end

  @spec import_body(String.t(), String.t(), Profile.t()) :: result()
  def import_body(body, filename, %Profile{} = profile) do
    # An import writes batches and snapshots around the sequencer; one
    # revision after it re-reads every table, so tabs and boots see them.
    try do
      import_trimmed(body, filename, profile)
    after
      {:ok, :ok} = Hireme.Ops.exec({:bulk, fn -> :ok end})
    end
  end

  defp import_trimmed(body, filename, profile) do
    trimmed = String.trim(body)

    cond do
      json?(trimmed, filename) -> import_json(Jason.decode!(trimmed), profile, filename)
      freshness_markdown?(trimmed) -> import_freshness(trimmed, profile, filename)
      table_markdown?(trimmed) -> import_table(trimmed, profile, filename)
      true -> {:error, :unrecognized}
    end
  end

  # Lowercased scheme and host, no query, no trailing slash: the idempotency key.
  defp canonical_url(url) when is_binary(url) do
    url = url |> String.trim() |> String.trim_trailing("/")

    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        path = uri.path |> to_string() |> String.trim_trailing("/")

        URI.to_string(%{
          uri
          | scheme: String.downcase(scheme),
            host: String.downcase(host),
            path: if(path in ["", "/"], do: nil, else: path),
            userinfo: nil,
            query: nil,
            fragment: nil
        })

      _ ->
        String.downcase(url)
    end
  end

  defp canonical_url(_), do: ""

  defp import_json(%{"leftover_unique" => _} = doc, _profile, _filename) do
    noted = date!(doc["noted_on"])

    (Repo.get_by(Snapshot, noted_on: noted) || %Snapshot{})
    |> Snapshot.changeset(%{
      noted_on: noted,
      leftover_unique: doc["leftover_unique"],
      target_total: doc["target_total"] || 10_000,
      target_on: date!(doc["target_on"] || "2026-10-31"),
      daily_batches: doc["daily_batches"] || 8,
      daily_apps: doc["daily_apps"] || 440,
      note: doc["note"] || ""
    })
    |> Repo.insert_or_update!()

    {:ok, %Report{kind: :snapshot, count: 1}}
  end

  defp import_json(%{"claims" => claims}, _profile, _filename) when is_list(claims) do
    Enum.each(claims, fn claim ->
      (Repo.get_by(Claim, squad: claim["squad"], slice: claim["slice"]) || %Claim{})
      |> Claim.changeset(%{
        squad: claim["squad"],
        slice: claim["slice"],
        note: claim["note"] || ""
      })
      |> Repo.insert_or_update!()
    end)

    {:ok, %Report{kind: :claims, count: length(claims)}}
  end

  defp import_json(%{"batches" => batches}, _profile, _filename) when is_list(batches) do
    Enum.each(batches, &upsert_batch/1)
    {:ok, %Report{kind: :batches, count: length(batches)}}
  end

  defp import_json(%{"apps" => apps} = doc, profile, filename) when is_list(apps) do
    batch = if doc["batch"], do: upsert_batch(doc), else: nil
    count = Enum.reduce(apps, 0, fn app, n -> upsert_app(profile, app, batch, doc) + n end)

    if batch, do: Desk.govern_batch(batch)

    {:ok, %Report{kind: :apps, count: count, source: filename}}
  end

  defp import_json(apps, profile, filename) when is_list(apps) do
    import_json(%{"apps" => apps}, profile, filename)
  end

  defp import_json(_other, _profile, _filename), do: {:error, :unrecognized}

  defp import_table(text, profile, filename) do
    {header, rows} = split_table(text)
    header = Enum.map(header, &(&1 |> String.downcase() |> String.trim()))
    apps = Enum.map(rows, &Map.new(Enum.zip(header, &1)))
    import_json(%{"apps" => apps, "stage" => "gated", "gate" => "pursue"}, profile, filename)
  end

  defp import_freshness(text, profile, filename) do
    wave = freshness_wave(text, filename)
    lines = text |> String.split("\n") |> Enum.map(&String.trim/1)
    lists = url_lists(lines)

    # A stated count wins; a listed verdict without one is counted.
    counts =
      (counts_from_lines(lines) ++
         Enum.map(lists, fn {verdict, urls} -> {verdict, length(urls)} end))
      |> Enum.uniq_by(&elem(&1, 0))

    Enum.each(counts, fn {verdict, n} ->
      (Repo.get_by(FreshnessVerdict, wave: wave, verdict: verdict) || %FreshnessVerdict{})
      |> FreshnessVerdict.changeset(%{
        wave: wave,
        verdict: verdict,
        eng_urls: n,
        noted_on: Date.utc_today(),
        source: filename
      })
      |> Repo.insert_or_update!()
    end)

    apps =
      for {verdict, urls} <- lists, url <- urls do
        %{
          "company" => host_company(url),
          "role" => "Engineer",
          "location" => "Remote",
          "fit" => "systems",
          "source" => "universe-gaps",
          "url" => url,
          "freshness" => Atom.to_string(verdict),
          "gate" => "pursue",
          "stage" => "freshness"
        }
      end

    {:ok, nested} = import_json(%{"apps" => apps}, profile, filename)
    {:ok, %Report{kind: :freshness, count: length(apps), wave: wave, nested: nested}}
  end

  defp upsert_batch(doc) do
    code = doc["batch"] || doc["code"]
    ordinal = ordinal_of(code)
    existing = Repo.get_by(Batch, code: code) || %Batch{code: code, ordinal: ordinal}

    existing
    |> Batch.changeset(%{
      code: code,
      ordinal: existing.ordinal || ordinal,
      kind: doc["kind"] || "day_pack",
      status: doc["status"] || "draft_prep",
      fire: doc["fire"] || "hold",
      target_size: doc["target_size"] || 55,
      queued_on: blank_date(doc["queued_on"]),
      squad: doc["squad"] || "",
      note: doc["note"] || existing.note || ""
    })
    |> Repo.insert_or_update!()
  end

  # A row's keys are read case-insensitively: a pursue table says
  # `Company` and `URL`, a pack says `company` and `url`.
  defp upsert_app(profile, app, batch, defaults) do
    app = Map.new(app, fn {key, value} -> {String.downcase(key), value} end)
    url = canonical_url(app["url"] || "")
    if url == "", do: raise(ArgumentError, "application is missing a URL")

    stage = Pipeline.parse!(app["stage"] || defaults["stage"] || :discovered)
    fire = (batch && batch.fire) || :hold
    stage = if Pipeline.fire_locked?(stage) and fire != :open_fire, do: :fire_ready, else: stage
    employer = upsert_employer(app["company"], app["freshness"])

    attrs = %{
      company: app["company"],
      role: app["role"] || "Engineer",
      location: app["location"] || "",
      fit: app["fit"] || "",
      source: app["source"] || "",
      listing_url: app["url"] || "",
      canonical_url: url,
      listing: app["listing"] || "",
      heat: app["heat"] || 3,
      freshness: app["freshness"] || "unknown",
      gate: app["gate"] || defaults["gate"] || "unset",
      squad: app["squad"] || (batch && batch.squad) || "",
      department: app["department"] || "",
      score_100: app["score_100"] || app["score"],
      employer_id: employer && employer.id,
      batch_id: batch && batch.id,
      stage: stage,
      next_action: app["next_action"] || hold_action(batch)
    }

    # The URL is nonempty above; spell out the partial unique index's predicate
    # so SQLite can seek by account and canonical URL instead of scanning its jobs.
    existing = from j in Job, where: j.canonical_url == ^url and j.canonical_url != ""

    case Repo.one(existing) do
      nil ->
        {:ok, _job} = Desk.create_job(Map.put(attrs, :profile_id, profile.id))

      job ->
        # A pack without a score leaves the one already on the card alone.
        attrs = Map.put(attrs, :score_100, score!(attrs.score_100, job.score_100))
        job |> Job.changeset(Map.delete(attrs, :stage)) |> Repo.update!()

        if job.current_stage != stage do
          case Desk.set_stage(job.id, stage) do
            {:ok, _} -> :ok
            {:error, :fire_hold} -> :held
          end
        end
    end

    1
  end

  defp score!(nil, current), do: current
  defp score!(value, _current) when is_integer(value), do: LifeEv.clamp(value)
  defp score!(value, _current) when is_float(value), do: LifeEv.clamp(round(value))

  defp score!(value, _current) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> LifeEv.clamp(n)
      _ -> raise ArgumentError, "bad score #{inspect(value)}"
    end
  end

  defp hold_action(%{fire: :hold, code: code}), do: "FIRE HOLD · #{code}"
  defp hold_action(_), do: ""

  defp upsert_employer(name, freshness) when is_binary(name) and name != "" do
    (Repo.get_by(Employer, name: name) || %Employer{})
    |> Employer.changeset(%{name: name, freshness: freshness || "unknown"})
    |> Repo.insert_or_update!()
  end

  defp upsert_employer(_name, _freshness), do: nil

  defp default_profile! do
    Repo.one(from p in Profile, order_by: p.id, limit: 1) ||
      raise "no profile. Add seed/profile.json and run mix ecto.setup."
  end

  defp json?(body, filename) do
    String.ends_with?(filename, ".json") or String.starts_with?(body, "{") or
      String.starts_with?(body, "[")
  end

  defp table_markdown?(text) do
    String.contains?(text, "|") and
      (String.contains?(String.downcase(text), "company") and String.contains?(text, "URL"))
  end

  defp freshness_markdown?(text) do
    upper = String.upcase(text)

    String.contains?(upper, "OPEN") and String.contains?(upper, "CLOSED") and
      not table_markdown?(text)
  end

  defp split_table(text) do
    rows =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, "|"))
      |> Enum.map(fn line ->
        line |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)
      end)
      |> Enum.reject(fn cells -> Enum.all?(cells, &(&1 =~ ~r/^:?-+:?$/)) end)

    case rows do
      [header | data] -> {header, data}
      _ -> {[], []}
    end
  end

  defp freshness_wave(text, filename) do
    case Regex.run(~r/universe-gaps[^\s#]*/i, text) do
      [wave | _] -> String.downcase(wave)
      nil -> filename |> Path.basename() |> String.replace(~r/\.md$/, "")
    end
  end

  defp counts_from_lines(lines) do
    Enum.flat_map(lines, fn line ->
      case Regex.run(~r/^(OPEN|THIN|CLOSED|BLOCKED)\s+(\d+)\s*$/i, line) do
        [_, name, n] -> [{verdict!(name), String.to_integer(n)}]
        _ -> []
      end
    end)
  end

  defp url_lists(lines) do
    {lists, verdict, urls} =
      Enum.reduce(lines, {%{}, nil, []}, fn line, {lists, verdict, urls} ->
        cond do
          match = Regex.run(~r/^##\s+(OPEN|THIN|CLOSED|BLOCKED)\s*$/i, line) ->
            {store_urls(lists, verdict, urls), verdict!(Enum.at(match, 1)), []}

          String.match?(line, ~r/^[-*]\s+https?:\/\//) ->
            {lists, verdict, [String.trim(String.replace(line, ~r/^[-*]\s*/, "")) | urls]}

          true ->
            {lists, verdict, urls}
        end
      end)

    store_urls(lists, verdict, urls)
    |> Enum.map(fn {verdict, urls} -> {verdict, Enum.reverse(urls)} end)
  end

  defp store_urls(lists, nil, _), do: lists
  defp store_urls(lists, _verdict, []), do: lists
  defp store_urls(lists, verdict, urls), do: Map.update(lists, verdict, urls, &(urls ++ &1))

  defp verdict!(name), do: Hireme.Closed.get(@verdicts, String.downcase(name), :open)

  defp host_company(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.replace(host, ~r/^www\./, "")
      _ -> "Unknown"
    end
  end

  defp ordinal_of(code) do
    case Regex.run(~r/(\d+)/, code || "") do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  defp date!(nil), do: nil
  defp date!(%Date{} = date), do: date

  defp date!(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> raise ArgumentError, "bad date #{value}"
    end
  end

  defp blank_date(""), do: nil
  defp blank_date(value), do: date!(value)
end

defmodule Hireme.Seed do
  @moduledoc """
  Load a local `seed/` directory into the desk.

  `seed/` is not tracked. If it is missing, the desk stays empty.
  """

  import Ecto.Query
  alias Hireme.Corpus
  alias Hireme.Corpus.Profile
  alias Hireme.Desk
  alias Hireme.Desk.Batch
  alias Hireme.Desk.Job
  alias Hireme.Desk.Overlay
  alias Hireme.Desk.Variant
  alias Hireme.Import
  alias Hireme.Kv
  alias Hireme.Narrative
  alias Hireme.Repo
  alias Hireme.Theme

  @type outcome :: :empty | :already_seeded | :ok

  @spec run() :: outcome()
  def run do
    Hireme.Accounts.use_default!()
    dir = seed_dir()
    profile_path = Path.join(dir, "profile.json")

    cond do
      not File.regular?(profile_path) ->
        IO.puts("No #{profile_path}. The desk starts empty. See README.")
        :empty

      Repo.exists?(Profile) ->
        IO.puts("Desk already seeded. mix ecto.reset to start over.")
        :already_seeded

      true ->
        {:ok, _} =
          Hireme.Ops.exec(
            {:bulk,
             fn ->
               profile = load_profile!(profile_path, dir)
               import_manifest(dir, profile)
               maybe_overlay(dir)
             end}
          )

        IO.puts("Seeded the desk from #{dir}.")
        :ok
    end
  end

  @doc "Add `n` generated applications above the showcase ids."
  @spec flood(non_neg_integer()) :: non_neg_integer()
  def flood(0), do: 0

  def flood(n) when is_integer(n) and n > 0 do
    Hireme.Accounts.use_default!()
    profile = hd(Corpus.list_profiles())
    start = max(Repo.aggregate(Job, :max, :id) || 0, 19_999) + 1

    for i <- 0..(n - 1), id = start + i do
      Desk.create_job!(%{
        id: id,
        profile_id: profile.id,
        company: "Flood #{rem(i, 40)}",
        role: "Engineer",
        location: "Remote",
        stage: :discovered,
        heat: rem(i, 5) + 1,
        fit: "systems",
        gate: :pursue,
        freshness: :open,
        canonical_url: "https://jobs.example.test/flood/#{id}",
        listing_url: "https://jobs.example.test/flood/#{id}",
        source: "flood"
      })
    end

    n
  end

  def seed_dir, do: Path.expand("seed", File.cwd!())

  defp load_profile!(path, dir) do
    doc = path |> File.read!() |> Jason.decode!()
    user = Narrative.create_user!(%{name: doc["name"], email: doc["email"] || ""})
    narrative_path = Path.join(dir, doc["narrative"] || "narrative.md")

    if File.regular?(narrative_path) do
      Narrative.write!(user, narrative_path |> File.read!() |> String.trim())
    end

    profile =
      Corpus.create_profile!(%{
        slug: doc["slug"] || "candidate",
        name: doc["name"],
        headline: doc["headline"] || "",
        summary: doc["summary"] || "",
        user_id: user.id
      })

    items_path = Path.join(dir, "items.json")

    if File.regular?(items_path) do
      items_path |> File.read!() |> Jason.decode!() |> Enum.each(&insert_item!(&1, profile.id))
    end

    %Variant{}
    |> Variant.changeset(%{
      profile_id: profile.id,
      label: "Root",
      theme: doc["theme"] |> Theme.parse() |> Theme.to_map(),
      note: ""
    })
    |> Repo.insert!()

    Enum.each(doc["kv"] || %{}, fn {key, value} -> Kv.put("global", key, to_string(value)) end)
    profile
  end

  defp insert_item!(row, profile_id) do
    Corpus.create_item!(%{
      profile_id: if(row["profile"] == "shared", do: nil, else: profile_id),
      kind: row["kind"],
      key: row["key"],
      title: row["title"],
      body: row["body"] || "",
      org: row["org"] || "",
      span: row["span"] || "",
      position: row["position"] || 0,
      keywords: row["keywords"] || []
    })
  end

  defp import_manifest(dir, profile) do
    manifest = Path.join(dir, "manifest.json")
    files = if File.regular?(manifest), do: manifest |> File.read!() |> Jason.decode!(), else: []

    Enum.each(files, fn file ->
      path = Path.join(dir, file)

      if File.regular?(path) do
        {:ok, _} = Import.import_path(path, profile: profile)
      else
        IO.puts("seed manifest skipped missing #{file}")
      end
    end)
  end

  defp maybe_overlay(dir) do
    path = Path.join(dir, "overlay.json")
    if File.regular?(path), do: apply_overlay!(path |> File.read!() |> Jason.decode!())
  end

  defp apply_overlay!(doc) do
    batch = Repo.get_by!(Batch, code: doc["batch"])
    job = Repo.one!(from j in Job, where: j.batch_id == ^batch.id, order_by: j.id, limit: 1)
    item = Corpus.get_item_by_key!(doc["item_key"])

    case Overlay.parse_mode(doc["mode"]) do
      {:ok, mode} ->
        {:ok, _} =
          Desk.put_overlay(job.id, item.id, %{
            mode: mode,
            body: doc["body"],
            reason: doc["reason"]
          })

      :error ->
        raise ArgumentError, "seed/overlay.json: unknown mode #{inspect(doc["mode"])}"
    end

    if is_map(doc["theme"]) do
      variant = Repo.get_by!(Variant, job_app_id: job.id)
      merged = Map.merge(variant.theme || %{}, doc["theme"]) |> Theme.parse() |> Theme.to_map()
      variant |> Variant.changeset(%{theme: merged}) |> Repo.update!()
    end
  end
end
