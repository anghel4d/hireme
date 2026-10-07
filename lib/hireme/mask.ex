defmodule Hireme.Mask.Line do
  @moduledoc """
  One canonical item after the overlay has spoken.

  `mode` is `:canonical` when no overlay touches the line. `shown` is
  false only for `:hidden`. The canonical title and body ride along so
  an altered line can show the root text beside it.
  """

  @enforce_keys [
    :id,
    :key,
    :kind,
    :title,
    :body,
    :org,
    :span,
    :position,
    :shown,
    :mode,
    :reason,
    :canonical_title,
    :canonical_body
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: pos_integer(),
          key: String.t(),
          kind: atom(),
          title: String.t(),
          body: String.t(),
          org: String.t(),
          span: String.t(),
          position: integer(),
          shown: boolean(),
          mode: Hireme.Mask.mode(),
          reason: String.t() | nil,
          canonical_title: String.t(),
          canonical_body: String.t()
        }
end

defmodule Hireme.Mask do
  @moduledoc """
  Resolves canonical items through an application's overlays.

  No overlay means the root line is what the CV shows. `:hidden` drops
  the line from the variant. `:altered` replaces title or body and keeps
  the root text beside it. `:emphasized` leaves the words and marks the
  line for the theme.

  An overlay is anything with `item_id`, `mode`, and optional `title`,
  `body`, `reason` under atom keys: the `Overlay` schema or a plain map
  built in code. Strings from the outside are parsed by
  `Hireme.Desk.Overlay.parse_mode/1` before they get here.
  """

  alias Hireme.Mask.Line

  @modes [:hidden, :altered, :emphasized]

  @type mode :: :canonical | :hidden | :altered | :emphasized
  @type overlay :: %{
          required(:item_id) => pos_integer(),
          required(:mode) => :hidden | :altered | :emphasized,
          optional(atom()) => term()
        }
  @type counts :: %{
          hidden: non_neg_integer(),
          altered: non_neg_integer(),
          emphasized: non_neg_integer()
        }

  @spec modes() :: [:hidden | :altered | :emphasized]
  def modes, do: @modes

  @spec apply([struct() | map()], [overlay()]) :: [Line.t()]
  def apply(items, overlays) do
    by_item = Map.new(overlays, &{&1.item_id, &1})

    items
    |> Enum.map(fn item -> resolve(item, Map.get(by_item, item.id)) end)
    |> Enum.sort_by(&{&1.position, &1.id})
  end

  @spec resolve(struct() | map(), overlay() | nil) :: Line.t()
  def resolve(item, nil), do: line(item, :canonical, item.title, item.body, nil)

  def resolve(item, %{mode: :hidden} = overlay) do
    line(item, :hidden, item.title, item.body, reason(overlay))
  end

  def resolve(item, %{mode: :altered} = overlay) do
    line(
      item,
      :altered,
      blank_to(Map.get(overlay, :title), item.title),
      blank_to(Map.get(overlay, :body), item.body),
      reason(overlay)
    )
  end

  def resolve(item, %{mode: :emphasized} = overlay) do
    line(item, :emphasized, item.title, item.body, reason(overlay))
  end

  @spec counts([overlay()]) :: counts()
  def counts(overlays) do
    Enum.reduce(overlays, %{hidden: 0, altered: 0, emphasized: 0}, fn
      %{mode: mode}, acc when mode in @modes -> Map.update!(acc, mode, &(&1 + 1))
    end)
  end

  defp line(item, mode, title, body, reason) do
    %Line{
      id: item.id,
      key: item.key,
      kind: item.kind,
      title: title,
      body: body,
      org: item.org || "",
      span: item.span || "",
      position: item.position,
      shown: mode != :hidden,
      mode: mode,
      reason: reason,
      canonical_title: item.title,
      canonical_body: item.body
    }
  end

  defp reason(overlay), do: Map.get(overlay, :reason)

  defp blank_to(nil, fallback), do: fallback
  defp blank_to("", fallback), do: fallback
  defp blank_to(value, _fallback), do: value
end
