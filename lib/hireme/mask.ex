defmodule Hireme.Mask do
  @moduledoc """
  Resolves one canonical item through an application's overlay.

  No overlay means the root line is what the CV shows. `:hidden` drops
  the line from the variant. `:altered` replaces title or body and keeps
  the root text beside it. `:emphasized` leaves the words and marks the
  line for the theme.
  """

  def apply(items, overlays) do
    by_item = Map.new(overlays, &{item_id(&1), &1})

    items
    |> Enum.map(fn item -> resolve(item, Map.get(by_item, item.id)) end)
    |> Enum.sort_by(&{&1.position, &1.id})
  end

  def resolve(item, nil), do: line(item, :canonical, item.title, item.body, nil)

  def resolve(item, overlay) do
    case mode(overlay) do
      :hidden ->
        line(item, :hidden, item.title, item.body, reason(overlay))
        |> Map.put(:shown, false)

      :altered ->
        line(
          item,
          :altered,
          blank_to(overlay_get(overlay, :title), item.title),
          blank_to(overlay_get(overlay, :body), item.body),
          reason(overlay)
        )

      :emphasized ->
        line(item, :emphasized, item.title, item.body, reason(overlay))

      _ ->
        line(item, :canonical, item.title, item.body, nil)
    end
  end

  def counts(overlays) do
    Enum.reduce(overlays, %{hidden: 0, altered: 0, emphasized: 0}, fn overlay, acc ->
      case mode(overlay) do
        :hidden -> %{acc | hidden: acc.hidden + 1}
        :altered -> %{acc | altered: acc.altered + 1}
        :emphasized -> %{acc | emphasized: acc.emphasized + 1}
        _ -> acc
      end
    end)
  end

  defp line(item, mode, title, body, reason) do
    %{
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

  defp mode(%{mode: mode}), do: normalize_mode(mode)
  defp mode(other), do: normalize_mode(other)

  defp normalize_mode(mode) when mode in [:hidden, :altered, :emphasized, :canonical], do: mode

  defp normalize_mode(mode) when is_binary(mode) do
    case mode do
      "hidden" -> :hidden
      "altered" -> :altered
      "emphasized" -> :emphasized
      _ -> :canonical
    end
  end

  defp normalize_mode(_), do: :canonical

  defp reason(overlay), do: overlay_get(overlay, :reason)

  defp overlay_get(overlay, key) when is_struct(overlay) do
    Map.get(overlay, key)
  end

  defp overlay_get(overlay, key) when is_map(overlay) do
    Map.get(overlay, key) || Map.get(overlay, Atom.to_string(key))
  end

  defp item_id(%{item_id: id}), do: id
  defp item_id(%{"item_id" => id}), do: id

  defp blank_to(nil, fallback), do: fallback
  defp blank_to("", fallback), do: fallback
  defp blank_to(value, _fallback), do: value
end
