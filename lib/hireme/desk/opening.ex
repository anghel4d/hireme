defmodule Hireme.Desk.Opening do
  @moduledoc """
  Everything needed to open one application on the desk.

  `new/1` reads a loose map once: the caller may hand over strings for
  stage, freshness, and gate, and overlays as maps. Past this struct the
  stage is a `Hireme.Pipeline.stage()`, overlay modes are atoms, and the
  theme is a `Hireme.Theme`.
  """

  alias Hireme.Desk.Overlay
  alias Hireme.LifeEv
  alias Hireme.Pipeline
  alias Hireme.Theme

  @freshness [:unknown, :open, :thin, :closed, :blocked]
  @gates [:unset, :pursue, :maybe, :skip]
  @statuses [:open, :paused, :hired, :closed]

  @enforce_keys [:profile_id, :company, :role]
  defstruct [
    :profile_id,
    :company,
    :role,
    :id,
    :employer_id,
    :batch_id,
    :next_due,
    location: "",
    listing_url: "",
    listing: "",
    heat: 3,
    status: :open,
    next_action: "",
    source: "",
    stage_on: nil,
    stage: :discovered,
    canonical_url: "",
    freshness: :unknown,
    gate: :unset,
    fit: "",
    squad: "",
    score_100: 50,
    label: nil,
    note: "",
    theme: %Theme{},
    overlays: []
  ]

  @type overlay :: %{
          item_id: pos_integer(),
          mode: :hidden | :altered | :emphasized,
          title: String.t() | nil,
          body: String.t() | nil,
          reason: String.t() | nil
        }

  @type t :: %__MODULE__{
          profile_id: pos_integer(),
          company: String.t(),
          role: String.t(),
          id: pos_integer() | nil,
          employer_id: pos_integer() | nil,
          batch_id: pos_integer() | nil,
          next_due: Date.t() | nil,
          location: String.t(),
          listing_url: String.t(),
          listing: String.t(),
          heat: 1..5,
          status: :open | :paused | :hired | :closed,
          next_action: String.t(),
          source: String.t(),
          stage_on: Date.t() | nil,
          stage: Pipeline.stage(),
          canonical_url: String.t(),
          freshness: :unknown | :open | :thin | :closed | :blocked,
          gate: :unset | :pursue | :maybe | :skip,
          fit: String.t(),
          squad: String.t(),
          score_100: LifeEv.score(),
          label: String.t() | nil,
          note: String.t(),
          theme: Theme.t(),
          overlays: [overlay()]
        }

  @type problem ::
          {:missing, :profile_id | :company | :role}
          | {:stage, term()}
          | {:freshness, term()}
          | {:gate, term()}
          | {:status, term()}
          | {:overlay, term()}

  @spec new(map()) :: {:ok, t()} | {:error, problem()}
  def new(%__MODULE__{} = opening), do: {:ok, opening}

  def new(attrs) when is_map(attrs) do
    with {:ok, profile_id} <- required(attrs, :profile_id),
         {:ok, company} <- required(attrs, :company),
         {:ok, role} <- required(attrs, :role),
         {:ok, stage} <- stage(Map.get(attrs, :stage, :discovered)),
         {:ok, freshness} <- enum(:freshness, Map.get(attrs, :freshness, :unknown), @freshness),
         {:ok, gate} <- enum(:gate, Map.get(attrs, :gate, :unset), @gates),
         {:ok, status} <- enum(:status, Map.get(attrs, :status, :open), @statuses),
         {:ok, overlays} <- overlays(Map.get(attrs, :overlays, [])) do
      {:ok,
       %__MODULE__{
         profile_id: profile_id,
         company: company,
         role: role,
         id: Map.get(attrs, :id),
         employer_id: Map.get(attrs, :employer_id),
         batch_id: Map.get(attrs, :batch_id),
         next_due: Map.get(attrs, :next_due),
         location: Map.get(attrs, :location) || "",
         listing_url: Map.get(attrs, :listing_url) || "",
         listing: Map.get(attrs, :listing) || "",
         heat: Map.get(attrs, :heat) || 3,
         status: status,
         next_action: Map.get(attrs, :next_action) || "",
         source: Map.get(attrs, :source) || "",
         stage_on: Map.get(attrs, :stage_on),
         stage: stage,
         canonical_url: Map.get(attrs, :canonical_url) || "",
         freshness: freshness,
         gate: gate,
         fit: Map.get(attrs, :fit) || "",
         squad: Map.get(attrs, :squad) || "",
         score_100: life_ev(attrs),
         label: Map.get(attrs, :label),
         note: Map.get(attrs, :note) || "",
         theme: Theme.parse(Map.get(attrs, :theme)),
         overlays: overlays
       }}
    end
  end

  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, opening} -> opening
      {:error, problem} -> raise ArgumentError, "cannot open application: #{inspect(problem)}"
    end
  end

  defp required(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:error, {:missing, key}}
      "" -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp stage(value) do
    case Pipeline.parse(value) do
      {:ok, stage} -> {:ok, stage}
      :error -> {:error, {:stage, value}}
    end
  end

  defp enum(field, value, allowed) when is_atom(value) and value != nil do
    if value in allowed, do: {:ok, value}, else: {:error, {field, value}}
  end

  defp enum(field, value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {field, value}}
      atom -> {:ok, atom}
    end
  end

  defp enum(field, value, _allowed), do: {:error, {field, value}}

  defp overlays(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn overlay, {:ok, acc} ->
      case overlay(overlay) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp overlays(other), do: {:error, {:overlay, other}}

  defp overlay(%{item_id: item_id} = overlay) when is_integer(item_id) do
    case Overlay.parse_mode(Map.get(overlay, :mode)) do
      {:ok, mode} ->
        {:ok,
         %{
           item_id: item_id,
           mode: mode,
           title: Map.get(overlay, :title),
           body: Map.get(overlay, :body),
           reason: Map.get(overlay, :reason)
         }}

      :error ->
        {:error, {:overlay, overlay}}
    end
  end

  defp overlay(other), do: {:error, {:overlay, other}}

  defp life_ev(attrs) do
    LifeEv.score(%{
      company: Map.get(attrs, :company) || "",
      role: Map.get(attrs, :role) || "",
      fit: Map.get(attrs, :fit) || "",
      location: Map.get(attrs, :location) || "",
      comp: Map.get(attrs, :comp),
      score_100: Map.get(attrs, :score_100),
      score: Map.get(attrs, :score)
    })
  end
end
