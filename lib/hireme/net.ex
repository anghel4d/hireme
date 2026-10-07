defmodule Hireme.Net.Progress do
  @moduledoc """
  One reading of the networking lane.

  Not a CRM. Counts shipped posts/artifacts, open drafts, and
  Broadside Observer runs. `lane` is the Observer research URL.
  """

  @enforce_keys [:lane, :shipped_week, :drafts, :observer_runs, :recent]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          lane: String.t(),
          shipped_week: non_neg_integer(),
          drafts: non_neg_integer(),
          observer_runs: non_neg_integer(),
          recent: [Hireme.Net.Entry.t()]
        }
end

defmodule Hireme.Net do
  @moduledoc """
  Lightweight networking. Not CRM spam.

  Closed kinds: observer run, shipped artifact, public post, outreach
  draft. Closed channels: Broadside, X, other. The Broadside research
  lane URL lives in kv (`net` / `broadside_lane`).
  """

  import Ecto.Query
  alias Hireme.Kv
  alias Hireme.Net.Entry
  alias Hireme.Net.Progress
  alias Hireme.Repo

  @kinds [:observer, :artifact, :post, :draft]
  @channels [:broadside, :x, :other]
  @kind_names Map.new(@kinds, &{Atom.to_string(&1), &1})
  @channel_names Map.new(@channels, &{Atom.to_string(&1), &1})
  @week 7

  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @spec channels() :: [atom()]
  def channels, do: @channels

  @spec name(atom()) :: String.t()
  def name(key) when is_atom(key), do: Atom.to_string(key)

  @spec label(atom()) :: String.t()
  def label(:observer), do: "Observer"
  def label(:artifact), do: "Artifact"
  def label(:post), do: "Post"
  def label(:draft), do: "Draft"
  def label(:broadside), do: "Broadside"
  def label(:x), do: "X"
  def label(:other), do: "Other"

  @spec parse_kind(term()) :: {:ok, atom()} | :error
  def parse_kind(value), do: parse_closed(value, @kinds, @kind_names)

  @spec parse_channel(term()) :: {:ok, atom()} | :error
  def parse_channel(value), do: parse_closed(value, @channels, @channel_names)

  @spec lane() :: String.t()
  def lane do
    case Kv.get("net", "broadside_lane") do
      %{value: value} -> String.trim(value)
      _ -> ""
    end
  end

  @spec set_lane(term()) :: {:ok, String.t()} | {:error, :lane}
  def set_lane(url) when is_binary(url) do
    trimmed = String.trim(url)
    Kv.put("net", "broadside_lane", trimmed)
    {:ok, trimmed}
  end

  def set_lane(_), do: {:error, :lane}

  @spec log(map(), Date.t()) :: {:ok, Entry.t()} | {:error, term()}
  def log(attrs, today \\ Date.utc_today()) when is_map(attrs) do
    with {:ok, kind} <- required_closed(attrs, "kind", &parse_kind/1),
         {:ok, channel} <-
           required_closed(attrs, "channel", &parse_channel/1, default_channel(kind)),
         {:ok, title} <- required_title(attrs),
         {:ok, shipped_on} <- shipped_day(attrs, kind, today) do
      %Entry{}
      |> Entry.changeset(%{
        kind: kind,
        channel: channel,
        title: title,
        url: string(attrs, "url"),
        body: string(attrs, "body"),
        shipped_on: shipped_on
      })
      |> Repo.insert()
    end
  end

  @spec progress(Date.t()) :: Progress.t()
  def progress(today \\ Date.utc_today()) do
    week_start = Date.add(today, 1 - @week)

    %Progress{
      lane: lane(),
      shipped_week: shipped_since(week_start),
      drafts: count_kind(:draft),
      observer_runs: count_kind(:observer),
      recent: recent()
    }
  end

  @spec recent(pos_integer()) :: [Entry.t()]
  def recent(limit \\ 40) do
    Repo.all(from e in Entry, order_by: [desc: e.id], limit: ^limit)
  end

  @spec ascii(Progress.t()) :: String.t()
  def ascii(%Progress{} = progress) do
    lane = if progress.lane == "", do: "(no Broadside lane yet)", else: progress.lane

    """
    NET  shipped #{progress.shipped_week}/7d  drafts #{progress.drafts}  observer #{progress.observer_runs}
    lane #{lane}
    Not CRM. Run Observer. Ship the work. Post it.
    """
    |> String.trim()
  end

  defp shipped_since(%Date{} = day) do
    Repo.aggregate(
      from(e in Entry,
        where: e.kind in [:artifact, :post] and not is_nil(e.shipped_on) and e.shipped_on >= ^day
      ),
      :count
    )
  end

  defp count_kind(kind) do
    Repo.aggregate(from(e in Entry, where: e.kind == ^kind), :count)
  end

  defp default_channel(:observer), do: :broadside
  defp default_channel(:post), do: :x
  defp default_channel(_), do: :other

  defp shipped_day(attrs, kind, today) when kind in [:artifact, :post, :observer] do
    case Map.get(attrs, "shipped_on") || Map.get(attrs, :shipped_on) do
      nil ->
        {:ok, today}

      "" ->
        {:ok, today}

      %Date{} = date ->
        {:ok, date}

      s when is_binary(s) ->
        case Date.from_iso8601(s) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, {:argument, "shipped_on"}}
        end

      _ ->
        {:error, {:argument, "shipped_on"}}
    end
  end

  defp shipped_day(attrs, :draft, _today) do
    case Map.get(attrs, "shipped_on") || Map.get(attrs, :shipped_on) do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      %Date{} = date ->
        {:ok, date}

      s when is_binary(s) ->
        case Date.from_iso8601(s) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, {:argument, "shipped_on"}}
        end

      _ ->
        {:error, {:argument, "shipped_on"}}
    end
  end

  defp parse_closed(value, keys, names) do
    cond do
      value in keys ->
        {:ok, value}

      is_binary(value) ->
        case Map.fetch(names, value) do
          {:ok, key} -> {:ok, key}
          :error -> :error
        end

      true ->
        :error
    end
  end

  defp required_closed(attrs, name, parse) do
    case Map.get(attrs, name) || Map.get(attrs, String.to_atom(name)) do
      nil ->
        {:error, {:argument, name}}

      "" ->
        {:error, {:argument, name}}

      value ->
        case parse.(value) do
          {:ok, key} -> {:ok, key}
          :error -> {:error, {:argument, name}}
        end
    end
  end

  defp required_closed(attrs, name, parse, default) do
    case Map.get(attrs, name) || Map.get(attrs, String.to_atom(name)) do
      nil ->
        {:ok, default}

      "" ->
        {:ok, default}

      value ->
        case parse.(value) do
          {:ok, key} -> {:ok, key}
          :error -> {:error, {:argument, name}}
        end
    end
  end

  defp required_title(attrs) do
    title = string(attrs, "title")
    if title == "", do: {:error, {:argument, "title"}}, else: {:ok, title}
  end

  defp string(attrs, name) do
    case Map.get(attrs, name) || Map.get(attrs, String.to_atom(name)) do
      s when is_binary(s) -> String.trim(s)
      _ -> ""
    end
  end
end
