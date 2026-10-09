defmodule HiremeWeb.Packet do
  @moduledoc """
  The desk as frames of columns.

  SQLite is the last place a card is a row. Everything the desk sends, the
  cards and their lookups, the scoreboard, the lanes, root CVs and one
  job's focus, travels as columnar table blocks in frames whose layout
  `priv/wire/schema.txt` states once for this encoder, the Rust codec and,
  through the kernel, the browser. Every column starts 8-aligned from the
  frame's first byte, so a reader views it in place.
  """

  alias Hireme.Desk.Card
  alias Hireme.Desk.Job
  alias Hireme.LifeEv
  alias Hireme.Pipeline

  @epoch ~D[1970-01-01]
  @none 0xFFFFFFFF
  @heat_states [:cool, :warm, :hot, :blocked]

  defp index_of(list), do: list |> Enum.with_index() |> Map.new()

  # ---- The wire: frames of columnar tables, as priv/wire/schema.txt says ----
  #
  # Frame: u32 len (whole frame, header included, a multiple of 8) | u8 kind
  # | u8 flags | u16 schema_hash | u64 rev | body. A table body is a run of
  # blocks, u16 table | u16 ncols | u32 nrows | col*, each col u16 id | u8
  # type | u8 0 | u32 byte_len | data | zero pad to 8, so every column starts
  # 8-aligned from the frame's first byte and a reader views it in place.
  # The schema file is the one source for this encoder, the Rust codec and,
  # through the kernel, the browser; its hash rides in every header.

  @schema_file Path.expand("../../priv/wire/schema.txt", __DIR__)
  @external_resource @schema_file
  @schema_bytes File.read!(@schema_file)

  @schema_hash (fn bytes ->
                  h =
                    for <<b <- bytes>>, reduce: 0x811C9DC5 do
                      h -> Bitwise.band(Bitwise.bxor(h, b) * 0x01000193, 0xFFFFFFFF)
                    end

                  Bitwise.bxor(Bitwise.bsr(h, 16), Bitwise.band(h, 0xFFFF))
                end).(@schema_bytes)

  @schema (for line <- String.split(@schema_bytes, "\n"),
               words = String.split(line),
               words != [] and not String.starts_with?(line, "#"),
               reduce: %{frames: %{}, tables: %{}, ops: %{}, refusals: %{}} do
             acc ->
               case words do
                 ["frame", name, kind] ->
                   put_in(
                     acc,
                     [:frames, String.to_atom(String.downcase(name))],
                     String.to_integer(kind)
                   )

                 ["table", name, id] ->
                   put_in(acc, [:tables, String.to_atom(name)], {String.to_integer(id), []})

                 ["col", table, name, id, type] ->
                   update_in(acc, [:tables, String.to_atom(table)], fn {tid, cols} ->
                     {tid,
                      cols ++
                        [{String.to_atom(name), String.to_integer(id), String.to_atom(type)}]}
                   end)

                 ["op", name, kind | _] ->
                   put_in(acc, [:ops, String.to_integer(kind)], String.to_atom(name))

                 ["refusal", name, code] ->
                   put_in(acc, [:refusals, String.to_atom(name)], String.to_integer(code))
               end
           end)

  @frames @schema.frames
  @kinds Map.new(@schema.frames, fn {name, kind} -> {kind, name} end)
  @tables @schema.tables
  @op_kinds @schema.ops
  @refusals @schema.refusals
  @nan <<0, 0, 0, 0, 0, 0, 248, 127>>

  @doc "The 16-bit schema hash every frame header carries."
  @spec schema_hash() :: non_neg_integer()
  def schema_hash, do: @schema_hash

  @doc "The op kind atom for a wire kind number, or `nil`."
  @spec op_kind(non_neg_integer()) :: atom() | nil
  def op_kind(n), do: Map.get(@op_kinds, n)

  @doc "The refusal code for a refusal atom; anything unnamed is `internal`."
  @spec refusal_code(atom()) :: non_neg_integer()
  def refusal_code(name), do: Map.get(@refusals, name, @refusals.internal)

  @doc """
  One frame of `kind` at `rev` around `body`. With `deflate: true` the body
  travels as `u32 raw_len | u32 deflate_len | raw deflate | pad` and the
  0x01 flag is set; `flags` adds the rest (0x02 END).
  """
  @spec frame(atom(), non_neg_integer(), iodata(), keyword()) :: iodata()
  def frame(kind, rev, body, opts \\ []) do
    {flags, body} =
      if opts[:deflate] do
        raw = IO.iodata_to_binary(body)
        packed = :zlib.zip(raw)
        {0x01, [<<byte_size(raw)::little-32, byte_size(packed)::little-32>>, packed]}
      else
        {0, body}
      end

    flags = Bitwise.bor(flags, Keyword.get(opts, :flags, 0))
    size = IO.iodata_length(body)
    pad = pad8(size)

    [
      <<16 + size + byte_size(pad)::little-32, Map.fetch!(@frames, kind)::8, flags::8,
        @schema_hash::little-16, rev::little-64>>,
      body,
      pad
    ]
  end

  @doc """
  One table block: every row is a map holding each schema column by name
  (or the subset named in `only`, for a partial PATCH).
  """
  @spec table(atom(), [map()], [atom()] | nil) :: iodata()
  def table(name, rows, only \\ nil) do
    {id, cols} = Map.fetch!(@tables, name)
    cols = if only, do: Enum.filter(cols, fn {c, _, _} -> c in only end), else: cols
    n = length(rows)

    [
      <<id::little-16, length(cols)::little-16, n::little-32>>
      | Enum.map(cols, fn {col, cid, type} ->
          column(cid, type, Enum.map(rows, &Map.fetch!(&1, col)))
        end)
    ]
  end

  defp column(cid, type, values) do
    {wire, data} = encode(type, values)
    size = IO.iodata_length(data)
    [<<cid::little-16, wire::8, 0::8, size::little-32>>, data, pad8(size)]
  end

  defp encode(type, values) when type in [:u32, :day, :time],
    do: {1, for(v <- values, into: <<>>, do: <<u32(v)::little-32>>)}

  defp encode(:u64, values), do: {3, for(v <- values, into: <<>>, do: <<v::little-64>>)}

  defp encode(:f64, values) do
    {4,
     for v <- values, into: <<>> do
       if is_number(v), do: <<v * 1.0::little-float-64>>, else: @nan
     end}
  end

  defp encode(:str, values) do
    strings = Enum.map(values, &text/1)

    {offsets, total} =
      Enum.reduce(strings, {[<<0::little-32>>], 0}, fn s, {acc, at} ->
        at = at + byte_size(s)
        {[acc, <<at::little-32>>], at}
      end)

    _ = total
    {2, [offsets, strings]}
  end

  defp u32(nil), do: @none
  defp u32(true), do: 1
  defp u32(false), do: 0
  defp u32(%Date{} = d), do: Date.diff(d, @epoch)
  defp u32(%DateTime{} = t), do: DateTime.to_unix(t)
  defp u32(%NaiveDateTime{} = t), do: t |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
  defp u32(n) when is_integer(n) and n >= 0 and n < @none, do: n
  defp u32(n) when is_float(n), do: round(n)

  defp text(nil), do: ""
  defp text(s) when is_binary(s), do: s
  defp text(a) when is_atom(a), do: Atom.to_string(a)
  defp text(n) when is_number(n), do: to_string(n)
  defp text(list) when is_list(list), do: Enum.map_join(list, "\n", &text/1)
  defp text(%Date{} = d), do: Date.to_iso8601(d)

  # ---- What the desk sends ----

  @doc "Card rows, keyed for the `cards` table."
  @spec card_rows([Card.t()], [map()], [map()]) :: [map()]
  def card_rows(cards, batches, profiles) do
    batch_ids = Map.new(batches, &{&1.code, &1.id})
    profile_ids = Map.new(profiles, &{&1.slug, &1.id})
    stages = index_of(Pipeline.keys())
    statuses = index_of(Job.statuses())
    freshness = index_of(~w(unknown open thin closed blocked)a)
    gates = index_of(~w(unset pursue maybe skip)a)
    heat_states = index_of(@heat_states)

    Enum.map(cards, fn c ->
      %{
        id: c.id,
        score: c.score_100,
        heat: c.heat,
        stage: Map.fetch!(stages, c.stage),
        status: Map.fetch!(statuses, c.status),
        freshness: Map.get(freshness, c.freshness, 0),
        gate: Map.get(gates, c.gate, 0),
        batch: Map.get(batch_ids, c.batch_code, 0),
        profile: Map.get(profile_ids, c.profile_slug, 0),
        hits: c.keyword_hits,
        total: c.keyword_total,
        hidden: c.mask_hidden,
        altered: c.mask_altered,
        emphasized: c.mask_emphasized,
        stage_on: c.stage_on,
        next_due: c.next_due,
        heat_state: Map.get(heat_states, c.heat_state, 0),
        load_pct: if(c.cap <= 0, do: 100, else: round(c.load / c.cap * 100)),
        cooldown: c.cooldown_days,
        leased: Map.get(c, :leased, false),
        company: c.company,
        role: c.role,
        location: c.location,
        next_action: c.next_action,
        cv_label: c.cv_label,
        fit: c.fit,
        pips: c.pips
      }
    end)
  end

  @doc "The lookup tables the card columns index into, plus batches and profiles."
  @spec lookups([map()], [map()]) :: iodata()
  def lookups(batches, profiles) do
    keyed = fn list ->
      list |> Enum.with_index() |> Enum.map(fn {k, i} -> %{ix: i, key: k} end)
    end

    [
      table(
        :stages,
        Enum.with_index(Pipeline.stages(), fn s, i ->
          %{
            ix: i,
            key: s.key,
            label: s.label,
            hint: s.hint,
            rank: Pipeline.rank(s.key),
            fire_locked: Pipeline.fire_locked?(s.key),
            hot: Hireme.Heat.hot_stage?(s.key),
            queue: Hireme.Heat.entering?(:discovered, s.key)
          }
        end)
      ),
      table(:statuses, keyed.(Job.statuses())),
      table(:freshness, keyed.(~w(unknown open thin closed blocked))),
      table(:gates, keyed.(~w(unset pursue maybe skip))),
      table(:heat_states, keyed.(@heat_states)),
      table(
        :bands,
        Enum.with_index(LifeEv.bands(), fn b, i ->
          %{ix: i, key: LifeEv.name(b.key), label: b.label, min: b.min, max: b.max}
        end)
      ),
      batch_table(batches),
      table(
        :profiles,
        Enum.map(
          profiles,
          &%{id: &1.id, slug: &1.slug, name: &1.name, headline: &1.headline, summary: &1.summary}
        )
      )
    ]
  end

  @spec batch_table([map()]) :: iodata()
  def batch_table(batches) do
    table(
      :batches,
      Enum.map(batches, fn b ->
        %{
          id: b.id,
          code: b.code,
          ordinal: b.ordinal,
          fire: b.fire == :open_fire,
          status: b.status
        }
      end)
    )
  end

  @doc "The scoreboard (`HiremeWeb.JSON.scoreboard/1` shape) as its four tables."
  @spec score_tables(map()) :: iodata()
  def score_tables(s) do
    chart = s.chart

    [
      table(:score, [
        Map.merge(
          Map.take(s, ~w(leftover_unique leftover_noted_on batches_today batches_target apps_today
          apps_target submitted_today cumulative target_total target_on)a),
          %{
            fire: s.fire == :open_fire,
            chart_n: chart.n,
            chart_mean: chart.mean,
            chart_max: Map.get(chart, :max),
            chart_min: Map.get(chart, :min)
          }
        )
      ]),
      table(:varieties, s.varieties),
      table(
        :chart_bands,
        Enum.map(chart.bands, &Map.update(&1, :key, nil, fn k -> LifeEv.name(k) end))
      ),
      table(:chart_bins, chart.bins)
    ]
  end

  @doc "The lanes (`HiremeWeb.JSON.lanes/0` shape) as their tables."
  @spec lane_tables(map()) :: iodata()
  def lane_tables(%{gym: gym, net: net, heat: heat}) do
    options =
      for {group, list} <- [
            platform: gym.platforms,
            topic: gym.topics_all,
            difficulty: gym.difficulties,
            outcome: gym.outcomes,
            net_kind: net.kinds,
            net_channel: net.channels
          ],
          o <- list,
          do: Map.put(o, :group, group)

    [
      table(:gym, [Map.take(gym, ~w(today target streak solved_today solved_week score)a)]),
      table(:gym_topics, gym.topics),
      table(:gym_reps, gym.recent),
      table(:options, options),
      table(:net, [Map.take(net, ~w(lane shipped_week drafts observer_runs)a)]),
      table(:net_entries, net.recent),
      table(
        :heat_rows,
        Enum.map(heat.companies, &Map.put(&1, :group, 0)) ++
          Enum.map(heat.vendors, &Map.put(&1, :group, 1))
      )
    ]
  end

  @doc """
  Interning of CV lines for one session. A line's `ix` comes from its
  content (`:erlang.phash2/2`, stable across nodes and releases), so a
  browser that restores yesterday's snapshot still finds the same line at
  the same ix; a collision within a session probes on. Answers the ix,
  the interning, and whether this session has not sent the line yet.
  """
  @spec intern(map(), map()) :: {non_neg_integer(), map(), boolean()}
  def intern(intern, line) do
    case intern do
      %{^line => ix} -> {ix, intern, false}
      _ -> probe(intern, line, 0)
    end
  end

  defp probe(intern, line, attempt) do
    ix = :erlang.phash2({attempt, line}, 0xFFFFFFFF)

    if Map.has_key?(intern, {:ix, ix}),
      do: probe(intern, line, attempt + 1),
      else: {ix, intern |> Map.put(line, ix) |> Map.put({:ix, ix}, line), true}
  end

  defp line_row(line, ix), do: Map.put(line, :ix, ix) |> Map.put(:item, line.id)

  defp doc_lines(doc, intern) do
    slots =
      Enum.map(doc.facts, &{0, 0, &1}) ++
        Enum.flat_map(Enum.with_index(doc.sections), fn {s, i} ->
          Enum.map(s.lines, &{1, i, &1})
        end) ++
        Enum.map(doc.hidden, &{2, 0, &1})

    Enum.map_reduce(slots, {intern, []}, fn {slot, section, line}, {intern, fresh} ->
      {ix, intern, new?} = intern(intern, line)
      fresh = if new?, do: [line_row(line, ix) | fresh], else: fresh
      {%{slot: slot, section: section, line: ix}, {intern, fresh}}
    end)
  end

  defp cv_fields(doc) do
    %{
      cv_label: doc.label,
      cv_person: doc.person,
      cv_headline: doc.headline,
      cv_summary: doc.summary,
      cv_summary_canonical: doc.summary_canonical,
      cv_summary_reason: doc.summary_reason,
      cv_accent: doc.accent,
      cv_density: doc.density
    }
  end

  @doc """
  One job's focus (`HiremeWeb.JSON.focus/1` shape) at `rev`: a LINES frame
  for lines this session has not been sent (unless `resend` names them all)
  and the FOCUS frame. Returns the frames and the session's interning.
  """
  @spec focus_frames(map(), non_neg_integer(), map(), boolean()) :: {iodata(), map()}
  def focus_frames(f, rev, intern, resend \\ false) do
    {refs, {intern, fresh}} = doc_lines(f.cv, intern)

    {mask_refs, {intern, fresh}} =
      Enum.map_reduce(f.masks, {intern, fresh}, fn line, {intern, fresh} ->
        {ix, intern, new?} = intern(intern, line)

        {%{slot: 3, section: 0, line: ix},
         {intern, if(new?, do: [line_row(line, ix) | fresh], else: fresh)}}
      end)

    fresh =
      if resend,
        do:
          Enum.map(
            f.cv.facts ++ Enum.flat_map(f.cv.sections, & &1.lines) ++ f.cv.hidden ++ f.masks,
            &line_row(&1, Map.fetch!(intern, &1))
          )
          |> Enum.uniq_by(& &1.ix),
        else: Enum.reverse(fresh)

    theme = f.theme
    heat = f.heat

    row =
      Map.merge(cv_fields(f.cv), %{
        job: f.job.id,
        listing: f.job.listing,
        listing_url: f.job.listing_url,
        variant_id: f.variant.id,
        variant_label: f.variant.label,
        theme_lead: theme["lead"],
        theme_lead_reason: theme["lead_reason"],
        theme_accent: theme["accent"],
        theme_density: theme["density"],
        theme_targets: theme["targets"],
        heat_decision: heat[:decision],
        heat_reason: heat[:reason],
        heat_company: heat[:company],
        heat_company_load: heat[:company_load],
        heat_company_cap: heat[:company_cap],
        heat_company_increment: heat[:company_increment],
        heat_size: heat[:size],
        heat_ats_vendor: heat[:ats_vendor],
        heat_ats_tenant: heat[:ats_tenant],
        heat_vendor_load: heat[:vendor_load],
        heat_vendor_cap: heat[:vendor_cap],
        heat_tenant_load: heat[:tenant_load],
        heat_tenant_cap: heat[:tenant_cap],
        heat_cooldown_days: heat[:cooldown_days],
        heat_note: heat[:note],
        heat_override: heat[:override],
        heat_override_reason: heat[:override_reason]
      })

    cover =
      for {root, c} <- [{0, f.coverage}, {1, f.root_coverage}],
          {hit, words} <- [{1, c.hits}, {0, c.misses}],
          w <- words,
          do: %{root: root, hit: hit, word: w}

    focus =
      packed(:focus, rev, [
        table(:focus, [row]),
        table(:focus_rungs, f.rail),
        table(:focus_events, f.events),
        table(:focus_cover, cover),
        table(:focus_sections, Enum.map(f.cv.sections, &Map.take(&1, [:kind, :label]))),
        table(:focus_lines, refs ++ mask_refs),
        table(:focus_kv, f.kv)
      ])

    lines = if fresh == [], do: [], else: packed(:lines, rev, table(:lines, fresh))
    {[lines, focus], intern}
  end

  # A focus is mostly its listing and one-row columns: deflated it is a
  # third of the bytes, for about 50 µs, so anything over 1 KiB travels so.
  defp packed(kind, rev, body),
    do: frame(kind, rev, body, deflate: IO.iodata_length(body) > 1024)

  @doc """
  One profile's root CV (`HiremeWeb.JSON.root/1` shape) as rows of the
  `roots`, `root_sections`, `root_lines` and `lines` tables.
  """
  @spec root_rows(non_neg_integer(), map(), map()) :: {map(), map()}
  def root_rows(profile_id, r, intern) do
    {refs, {intern, fresh}} = doc_lines(r.cv, intern)

    rows = %{
      roots: [Map.merge(cv_fields(r.cv), %{profile: profile_id, variant_label: r.cv.label})],
      root_sections:
        Enum.map(r.cv.sections, &%{profile: profile_id, kind: &1.kind, label: &1.label}),
      root_lines: Enum.map(refs, &Map.put(&1, :profile, profile_id)),
      lines: Enum.reverse(fresh)
    }

    {rows, intern}
  end

  @doc """
  Cut whole frames off the front of a stream buffer. Answers the frames as
  `{kind_atom | integer, flags, rev, body}` in order and the bytes left
  over, or `{:error, reason}` for a frame no reader should keep going past:
  a length below 16 or not a multiple of 8, or another schema.
  """
  @spec split(binary()) :: {:ok, [tuple()], binary()} | {:error, atom()}
  def split(buffer), do: split(buffer, [])

  defp split(<<len::little-32, _::binary>>, _acc) when len < 16 or rem(len, 8) != 0,
    do: {:error, :frame_length}

  defp split(
         <<len::little-32, kind::8, flags::8, hash::little-16, rev::little-64, rest::binary>> =
           buffer,
         acc
       )
       when byte_size(buffer) >= len do
    if hash != @schema_hash do
      {:error, :schema}
    else
      body_len = len - 16
      <<body::binary-size(^body_len), rest::binary>> = rest
      split(rest, [{Map.get(@kinds, kind, kind), flags, rev, body} | acc])
    end
  end

  defp split(buffer, acc), do: {:ok, Enum.reverse(acc), buffer}

  defp pad8(len) do
    case rem(len, 8) do
      0 -> <<>>
      r -> :binary.copy(<<0>>, 8 - r)
    end
  end
end
