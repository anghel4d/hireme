defmodule HiremeWeb.Packet do
  @moduledoc """
  The desk as one columnar packet.

  SQLite is the last place a card is a row. This packet is columns: every
  `u32` column is `n` little-endian words, every `str` column is `n + 1`
  offsets followed by UTF-8 bytes, and the rows are already in board
  order so a selection over the columns is a selection over the board.

  Layout:

      "HDP1" | u32 header_len | header JSON | body (4-byte aligned)

  The header names each column with its kind and byte offset into the
  body, and carries the small lookup tables the columns index into:
  stages, statuses, freshness, gates, bands, batches, profiles. A
  consumer that knows the directory knows the packet.
  """

  alias Hireme.Corpus
  alias Hireme.Desk
  alias Hireme.Desk.Card
  alias Hireme.Desk.Filters
  alias Hireme.Desk.Job
  alias Hireme.LifeEv
  alias Hireme.Pipeline

  @magic "HDP1"
  @epoch ~D[1970-01-01]
  @none 0xFFFFFFFF

  @heat_states [:cool, :warm, :hot, :blocked]
  @u32_columns ~w(id score heat stage status freshness gate batch profile hits total hidden altered emphasized stage_on next_due heat_state load_pct cooldown)a
  @str_columns ~w(company role location next_action cv_label fit pips search)a

  @spec magic() :: String.t()
  def magic, do: @magic

  @spec build() :: iodata()
  def build do
    cards = Desk.list_cards(%Filters{status: :all})
    batches = Desk.list_batches()
    profiles = Corpus.list_profiles()

    tables = %{
      "stages" =>
        Enum.map(
          Pipeline.stages(),
          &%{"key" => Pipeline.name(&1.key), "label" => &1.label, "hint" => &1.hint}
        ),
      "statuses" => Enum.map(Job.statuses(), &Atom.to_string/1),
      "freshness" => ~w(unknown open thin closed blocked),
      "gates" => ~w(unset pursue maybe skip),
      "bands" =>
        Enum.map(
          LifeEv.bands(),
          &%{"key" => LifeEv.name(&1.key), "label" => &1.label, "min" => &1.min, "max" => &1.max}
        ),
      "batches" =>
        Enum.map(
          batches,
          &%{
            "code" => &1.code,
            "ordinal" => &1.ordinal,
            "fire" => Atom.to_string(&1.fire),
            "status" => Atom.to_string(&1.status)
          }
        ),
      "profiles" => Enum.map(profiles, &%{"id" => &1.id, "slug" => &1.slug, "name" => &1.name}),
      "heat_states" => Enum.map(@heat_states, &Atom.to_string/1)
    }

    index = %{
      stage: index_of(Pipeline.keys()),
      status: index_of(Job.statuses()),
      freshness: index_of(~w(unknown open thin closed blocked)a),
      gate: index_of(~w(unset pursue maybe skip)a),
      batch: Map.new(batches, &{&1.code, &1.ordinal + 1}),
      profile: index_of(Enum.map(profiles, & &1.slug))
    }

    n = length(cards)
    {columns, body} = encode_columns(cards, index)

    header =
      Jason.encode!(%{
        "v" => 1,
        "n" => n,
        "columns" => columns,
        "tables" => tables
      })

    [@magic, <<byte_size(header)::little-32>>, header, pad(byte_size(header)), body]
  end

  defp encode_columns(cards, index) do
    {dir, chunks, _at} =
      Enum.reduce(@u32_columns ++ @str_columns, {[], [], 0}, fn name, {dir, chunks, at} ->
        {kind, chunk} =
          if name in @u32_columns do
            {"u32", Enum.map(cards, &<<u32(name, &1, index)::little-32>>)}
          else
            {"str", str_column(Enum.map(cards, &str(name, &1)))}
          end

        size = IO.iodata_length(chunk)
        entry = %{"name" => Atom.to_string(name), "kind" => kind, "at" => at, "size" => size}
        {[entry | dir], [chunk | chunks], at + size}
      end)

    {Enum.reverse(dir), Enum.reverse(chunks)}
  end

  defp str_column(strings) do
    {offsets, total} =
      Enum.map_reduce(strings, 0, fn s, acc -> {<<acc::little-32>>, acc + byte_size(s)} end)

    [offsets, <<total::little-32>>, strings, pad(total)]
  end

  defp u32(:id, %Card{id: id}, _), do: id
  defp u32(:score, %Card{score_100: s}, _), do: s
  defp u32(:heat, %Card{heat: h}, _), do: h
  defp u32(:stage, %Card{stage: s}, idx), do: Map.fetch!(idx.stage, s)
  defp u32(:status, %Card{status: s}, idx), do: Map.fetch!(idx.status, s)
  defp u32(:freshness, %Card{freshness: f}, idx), do: Map.get(idx.freshness, f, 0)
  defp u32(:gate, %Card{gate: g}, idx), do: Map.get(idx.gate, g, 0)
  defp u32(:batch, %Card{batch_code: nil}, _), do: 0
  defp u32(:batch, %Card{batch_code: code}, idx), do: Map.get(idx.batch, code, 0)
  defp u32(:profile, %Card{profile_slug: slug}, idx), do: Map.get(idx.profile, slug, 0)
  defp u32(:hits, %Card{keyword_hits: v}, _), do: v
  defp u32(:total, %Card{keyword_total: v}, _), do: v
  defp u32(:hidden, %Card{mask_hidden: v}, _), do: v
  defp u32(:altered, %Card{mask_altered: v}, _), do: v
  defp u32(:emphasized, %Card{mask_emphasized: v}, _), do: v
  defp u32(:stage_on, %Card{stage_on: d}, _), do: days(d)
  defp u32(:next_due, %Card{next_due: d}, _), do: days(d)

  defp u32(:heat_state, %Card{heat_state: s}, _),
    do: Enum.find_index(@heat_states, &(&1 == s)) || 0

  defp u32(:load_pct, %Card{load: load, cap: cap}, _), do: round(load / max(cap, 0.01) * 100)
  defp u32(:cooldown, %Card{cooldown_days: nil}, _), do: @none
  defp u32(:cooldown, %Card{cooldown_days: d}, _), do: d

  defp str(:company, c), do: c.company
  defp str(:role, c), do: c.role
  defp str(:location, c), do: c.location || ""
  defp str(:next_action, c), do: c.next_action || ""
  defp str(:cv_label, c), do: c.cv_label
  defp str(:fit, c), do: c.fit || ""
  defp str(:pips, c), do: c.pips

  defp str(:search, c) do
    [
      c.company,
      c.role,
      c.location,
      c.next_action,
      c.profile_name,
      c.cv_label,
      Desk.code(c.id),
      "cv#{c.id}",
      Integer.to_string(c.id)
    ]
    |> Enum.map_join("\n", &String.downcase(to_string(&1 || "")))
  end

  defp days(nil), do: @none
  defp days(%Date{} = d), do: Date.diff(d, @epoch)

  defp index_of(list), do: list |> Enum.with_index() |> Map.new()

  defp pad(len) do
    case rem(len, 4) do
      0 -> <<>>
      r -> :binary.copy(<<0>>, 4 - r)
    end
  end
end
