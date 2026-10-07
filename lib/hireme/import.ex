defmodule Hireme.Import.Report do
  @moduledoc """
  What one import did. `kind` is the shape that was recognised.
  """

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
  alias Hireme.Pipeline
  alias Hireme.Repo
  alias Hireme.Variety

  @type result :: {:ok, Report.t()} | {:error, :unrecognized}

  @spec import_path(Path.t(), keyword()) :: result()
  def import_path(path, opts \\ []) do
    profile = Keyword.get(opts, :profile) || default_profile!()
    body = File.read!(path)
    import_body(body, Path.basename(path), profile)
  end

  @spec import_body(String.t(), String.t(), Profile.t()) :: result()
  def import_body(body, filename, %Profile{} = profile) do
    trimmed = String.trim(body)

    cond do
      json?(trimmed, filename) -> import_json(Jason.decode!(trimmed), profile, filename)
      freshness_markdown?(trimmed) -> import_freshness(trimmed, profile, filename)
      table_markdown?(trimmed) -> import_table(trimmed, profile, filename)
      true -> {:error, :unrecognized}
    end
  end

  def canonical_url(url) when is_binary(url) do
    url = url |> String.trim() |> String.trim_trailing("/")

    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        path = uri.path |> to_string() |> String.trim_trailing("/")
        path = if(path in ["", "/"], do: nil, else: path)

        URI.to_string(%URI{
          scheme: String.downcase(scheme),
          host: String.downcase(host),
          port: uri.port,
          path: path
        })

      _ ->
        String.downcase(url)
    end
  end

  def canonical_url(_), do: ""

  defp import_json(%{"leftover_unique" => _} = doc, _profile, _filename) do
    noted = date!(doc["noted_on"])

    snap =
      Repo.get_by(Snapshot, noted_on: noted) ||
        %Snapshot{}

    snap
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
      existing = Repo.get_by(Claim, squad: claim["squad"], slice: claim["slice"]) || %Claim{}

      existing
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
    if batch, do: refresh_variety(batch)
    {:ok, %Report{kind: :apps, count: count, source: filename}}
  end

  defp import_json(apps, profile, filename) when is_list(apps) do
    import_json(%{"apps" => apps}, profile, filename)
  end

  defp import_json(_other, _profile, _filename), do: {:error, :unrecognized}

  defp import_table(text, profile, filename) do
    {header, rows} = split_table(text)

    apps =
      Enum.map(rows, fn cells ->
        Map.new(Enum.zip(header, cells), fn {key, value} -> {normalize_header(key), value} end)
      end)

    import_json(%{"apps" => apps, "stage" => "gated", "gate" => "pursue"}, profile, filename)
  end

  defp import_freshness(text, profile, filename) do
    wave = freshness_wave(text, filename)
    {counts, lists} = freshness_sections(text)

    Enum.each(counts, fn {verdict, n} ->
      existing =
        Repo.get_by(FreshnessVerdict, wave: wave, verdict: verdict) || %FreshnessVerdict{}

      existing
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
      Enum.flat_map(lists, fn {verdict, urls} ->
        Enum.map(urls, fn url ->
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
        end)
      end)

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

  defp upsert_app(profile, app, batch, defaults) do
    url = canonical_url(app["url"] || app["URL"] || "")
    if url == "", do: raise(ArgumentError, "application is missing a URL")

    stage = Pipeline.parse!(app["stage"] || defaults["stage"] || :discovered)
    fire = (batch && batch.fire) || :hold

    stage =
      if Pipeline.fire_locked?(stage) and fire != :open_fire do
        :fire_ready
      else
        stage
      end

    employer = upsert_employer(app["company"] || app["Company"], app["freshness"])

    attrs = %{
      company: app["company"] || app["Company"],
      role: app["role"] || app["Role"] || "Engineer",
      location: app["location"] || app["Location"] || "",
      fit: app["fit"] || app["Fit"] || "",
      source: app["source"] || app["Source"] || "",
      listing_url: app["url"] || app["URL"] || "",
      canonical_url: url,
      listing: app["listing"] || "",
      heat: app["heat"] || 3,
      freshness: app["freshness"] || "unknown",
      gate: app["gate"] || defaults["gate"] || "unset",
      squad: app["squad"] || (batch && batch.squad) || "",
      score_100: app["score_100"] || app["score"] || app["Score"],
      employer_id: employer && employer.id,
      batch_id: batch && batch.id,
      stage: stage,
      next_action: app["next_action"] || hold_action(batch)
    }

    case Repo.get_by(Job, canonical_url: url) do
      nil ->
        {:ok, _job} =
          Desk.create_job(Map.put(attrs, :profile_id, profile.id))

        1

      job ->
        attrs = Map.put(attrs, :score_100, score!(attrs.score_100, job.score_100))

        job
        |> Job.changeset(Map.delete(attrs, :stage))
        |> Repo.update!()

        if job.current_stage != stage do
          case Desk.set_stage(job.id, stage) do
            {:ok, _} -> :ok
            {:error, :fire_hold} -> :held
          end
        end

        1
    end
  end

  # A pack without a score leaves the one already on the card alone.
  defp score!(nil, current), do: current

  defp score!(value, _current) when is_integer(value), do: Hireme.LifeEv.clamp(value)
  defp score!(value, _current) when is_float(value), do: Hireme.LifeEv.clamp(round(value))

  defp score!(value, _current) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> Hireme.LifeEv.clamp(n)
      _ -> raise ArgumentError, "bad score #{inspect(value)}"
    end
  end

  defp hold_action(%{fire: :hold, code: code}), do: "FIRE HOLD · #{code}"
  defp hold_action(_), do: ""

  defp refresh_variety(%Batch{} = batch) do
    apps =
      Repo.all(
        from j in Job,
          where: j.batch_id == ^batch.id,
          select: %{company: j.company, role: j.role, location: j.location, fit: j.fit}
      )

    variety = apps |> Variety.summarize(batch.target_size) |> Variety.to_map()

    batch
    |> Batch.changeset(%{variety: variety})
    |> Repo.update!()
  end

  defp upsert_employer(nil, _freshness), do: nil
  defp upsert_employer("", _freshness), do: nil

  defp upsert_employer(name, freshness) do
    existing = Repo.get_by(Employer, name: name) || %Employer{}

    existing
    |> Employer.changeset(%{name: name, freshness: freshness || "unknown"})
    |> Repo.insert_or_update!()
  end

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
        line
        |> String.trim("|")
        |> String.split("|")
        |> Enum.map(&String.trim/1)
      end)
      |> Enum.reject(fn cells -> Enum.all?(cells, &separator?/1) end)

    case rows do
      [header | data] -> {header, data}
      _ -> {[], []}
    end
  end

  defp separator?(cell), do: cell =~ ~r/^:?-+:?$/

  defp normalize_header(header) do
    header
    |> String.downcase()
    |> String.trim()
  end

  defp freshness_wave(text, filename) do
    cond do
      Regex.match?(~r/universe-gaps[^\n]*/i, text) ->
        text
        |> then(fn body -> Regex.run(~r/universe-gaps[^\s#]*/i, body) end)
        |> hd()
        |> String.downcase()

      true ->
        filename |> Path.basename() |> String.replace(~r/\.md$/, "")
    end
  end

  defp freshness_sections(text) do
    lines = text |> String.split("\n") |> Enum.map(&String.trim/1)
    counts = counts_from_lines(lines)
    lists = url_lists(lines)
    counts = fill_counts(counts, lists)
    {counts, lists}
  end

  defp counts_from_lines(lines) do
    Enum.flat_map(lines, fn line ->
      case Regex.run(~r/^(OPEN|THIN|CLOSED|BLOCKED)\s+(\d+)\s*$/i, line) do
        [_, name, n] -> [{verdict!(name), String.to_integer(n)}]
        _ -> []
      end
    end)
  end

  defp url_lists(lines), do: url_lists_plain(lines)

  defp url_lists_plain(lines) do
    {lists, verdict, urls} =
      Enum.reduce(lines, {%{}, nil, []}, fn line, {lists, verdict, urls} ->
        cond do
          Regex.match?(~r/^##\s+(OPEN|THIN|CLOSED|BLOCKED)\s*$/i, line) ->
            lists = store_urls(lists, verdict, urls)
            name = Regex.run(~r/(OPEN|THIN|CLOSED|BLOCKED)/i, line) |> Enum.at(1)
            {lists, verdict!(name), []}

          String.match?(line, ~r/^[-*]\s+https?:\/\//) ->
            url = String.replace(line, ~r/^[-*]\s*/, "")
            {lists, verdict, [String.trim(url) | urls]}

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

  defp fill_counts(counts, lists) do
    from_lists =
      Enum.map(lists, fn {verdict, urls} -> {verdict, length(urls)} end)

    (counts ++ from_lists)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp verdict!(name), do: name |> String.downcase() |> String.to_existing_atom()

  defp host_company(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host |> String.replace(~r/^www\./, "")
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

  defp blank_date(nil), do: nil
  defp blank_date(""), do: nil
  defp blank_date(value), do: date!(value)
end
