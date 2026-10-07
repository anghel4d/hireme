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
        profile = load_profile!(profile_path, dir)
        import_manifest(dir, profile)
        maybe_overlay(dir)
        IO.puts("Seeded the desk from #{dir}.")
        :ok
    end
  end

  @spec flood(non_neg_integer()) :: non_neg_integer()
  def flood(0), do: 0

  def flood(n) when is_integer(n) and n > 0 do
    profile = hd(Corpus.list_profiles())
    start = max(Repo.aggregate(Job, :max, :id) || 0, 19_999) + 1

    Enum.each(0..(n - 1), fn i ->
      id = start + i

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
    end)

    n
  end

  def seed_dir do
    Path.expand("seed", File.cwd!())
  end

  defp load_profile!(path, dir) do
    doc = path |> File.read!() |> Jason.decode!()

    user =
      Narrative.create_user!(%{
        name: doc["name"],
        email: doc["email"] || ""
      })

    narrative_path = Path.join(dir, doc["narrative"] || "narrative.md")

    if File.regular?(narrative_path) do
      Narrative.write!(user, File.read!(narrative_path) |> String.trim())
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
      items_path
      |> File.read!()
      |> Jason.decode!()
      |> Enum.each(&insert_item!(&1, profile.id))
    end

    %Variant{}
    |> Variant.changeset(%{
      profile_id: profile.id,
      label: "Root",
      theme: doc["theme"] |> Theme.parse() |> Theme.to_map(),
      note: ""
    })
    |> Repo.insert!()

    Enum.each(doc["kv"] || %{}, fn {key, value} ->
      Kv.put("global", key, to_string(value))
    end)

    profile
  end

  defp insert_item!(row, profile_id) do
    owner =
      case row["profile"] do
        "shared" -> nil
        nil -> profile_id
        _ -> profile_id
      end

    Corpus.create_item!(%{
      profile_id: owner,
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

    files =
      if File.regular?(manifest) do
        manifest |> File.read!() |> Jason.decode!()
      else
        []
      end

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

      variant
      |> Variant.changeset(%{theme: merged})
      |> Repo.update!()
    end

    Desk.refresh_glance!(job.id)
  end
end
