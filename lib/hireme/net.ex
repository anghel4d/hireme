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
  alias Hireme.Closed
  alias Hireme.Form
  alias Hireme.Kv
  alias Hireme.Net.Entry
  alias Hireme.Net.Progress
  alias Hireme.Repo

  @kinds [:observer, :artifact, :post, :draft]
  @channels [:broadside, :x, :other]
  @week 7

  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @spec channels() :: [atom()]
  def channels, do: @channels

  @spec label(atom()) :: String.t()
  def label(:x), do: "X"
  def label(key) when is_atom(key), do: key |> Atom.to_string() |> String.capitalize()

  @spec parse_kind(term()) :: {:ok, atom()} | :error
  def parse_kind(value), do: Closed.parse(@kinds, value)

  @spec parse_channel(term()) :: {:ok, atom()} | :error
  def parse_channel(value), do: Closed.parse(@channels, value)

  @spec lane() :: String.t()
  def lane do
    case Kv.get("net", "broadside_lane") do
      %Kv.Pair{value: value} -> String.trim(value)
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
    with {:ok, kind} <- Form.closed(attrs, :kind, @kinds, nil),
         {:ok, channel} <- Form.closed(attrs, :channel, @channels, default_channel(kind)),
         {:ok, title} <- Form.required(attrs, :title),
         {:ok, shipped_on} <-
           Form.day(attrs, :shipped_on, if(kind == :draft, do: nil, else: today)) do
      %Entry{}
      |> Entry.changeset(%{
        kind: kind,
        channel: channel,
        title: title,
        url: Form.string(attrs, :url),
        body: Form.string(attrs, :body),
        shipped_on: shipped_on
      })
      |> Repo.insert()
    end
  end

  @spec progress(Date.t()) :: Progress.t()
  def progress(today \\ Date.utc_today()) do
    %Progress{
      lane: lane(),
      shipped_week: shipped_since(Date.add(today, 1 - @week)),
      drafts: count_kind(:draft),
      observer_runs: count_kind(:observer),
      recent: recent()
    }
  end

  @spec recent(pos_integer()) :: [Entry.t()]
  def recent(limit \\ 40) do
    Repo.all(from e in Entry, order_by: [desc: e.id], limit: ^limit)
  end

  defp shipped_since(%Date{} = day) do
    Repo.aggregate(
      from(e in Entry,
        where: e.kind in [:artifact, :post] and not is_nil(e.shipped_on) and e.shipped_on >= ^day
      ),
      :count
    )
  end

  defp count_kind(kind), do: Repo.aggregate(from(e in Entry, where: e.kind == ^kind), :count)

  defp default_channel(:observer), do: :broadside
  defp default_channel(:post), do: :x
  defp default_channel(_), do: :other
end
