defmodule Hireme.Blobs do
  @moduledoc """
  A CV's files by SHA-256, each account's own, in `blobs` (never on the
  wire; `HiremeWeb.Blobs` serves them over HTTP). `put/3` keeps the bytes
  once and reads their text then, for the rules and the agents: markdown as
  it is, a docx's paragraphs, a Word 97-2003 doc's pieces, a PDF's shown strings, each through its own font's
  ToUnicode map (a font without one reads as Latin-1). A file whose text
  cannot be read is still kept, with none. Reading runs in its own process
  under a deadline, and nothing it inflates may pass `@inflated`.
  """
  import Bitwise
  import Ecto.Query
  alias Hireme.{Repo, Schema, Security, Store}
  alias Hireme.Rows.{Blob, CvVersion}

  @max 10 <<< 20
  @types %{
    "application/pdf" => :pdf,
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => :docx,
    "application/msword" => :doc,
    "text/markdown" => :markdown
  }
  @deadline 5_000
  @inflated 32 <<< 20
  @out 512 <<< 10

  @doc "The most bytes one file may hold."
  def max, do: @max

  @doc """
  Keeps `bytes` of MIME `type` for the account: `{:ok, %{sha, bytes, type,
  new}}`, `new` false when the account already holds them.
  """
  @spec put(pos_integer(), binary(), String.t()) ::
          {:ok, %{sha: String.t(), bytes: non_neg_integer(), type: String.t(), new: boolean()}}
          | {:error, :type | :too_large | :cap}
  def put(account_id, bytes, type) do
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    answer = %{sha: sha, bytes: byte_size(bytes), type: type, new: false}

    Repo.with_account(account_id, fn ->
      cond do
        not is_map_key(@types, type) -> {:error, :type}
        byte_size(bytes) > @max -> {:error, :too_large}
        held?(sha) -> {:ok, answer}
        # Read before the writer lock: a slow file holds no one else up.
        true -> keep(answer, bytes, text(@types[type], bytes))
      end
    end)
  end

  defp keep(answer, bytes, text) do
    Store.write(fn ->
      cond do
        held?(answer.sha) ->
          {:ok, answer}

        Repo.aggregate(Blob, :count) >= Schema.table(:blobs).cap ->
          {:error, :cap}

        true ->
          now = Store.now()

          Repo.insert!(%Blob{
            account_id: Repo.account_id!(),
            sha: answer.sha,
            type: answer.type,
            bytes: answer.bytes,
            data: bytes,
            text: text,
            rev: 1,
            inserted_at: now,
            updated_at: now
          })

          {:ok, %{answer | new: true}}
      end
    end)
  end

  defp held?(sha), do: Repo.exists?(from(b in Blob, where: b.sha == ^sha))

  @doc "A file the account holds: its type, size and text, and with `:data` its bytes."
  @spec about(String.t(), [:data]) :: map() | nil
  def about(sha, with \\ []) do
    fields = if :data in with, do: [:type, :bytes, :text, :data], else: [:type, :bytes, :text]

    if sha =~ ~r/^[0-9a-f]{64}$/,
      do: Repo.one(from(b in Blob, where: b.sha == ^sha, select: map(b, ^fields)))
  end

  @doc "The name the newest version naming the file gave it."
  @spec name(String.t()) :: String.t() | nil
  def name(sha) do
    Repo.one(
      from(v in CvVersion,
        where: v.blob_sha == ^sha and not is_nil(v.blob_name),
        order_by: [desc: v.id],
        limit: 1,
        select: v.blob_name
      )
    )
  end

  # ------------------------------------------------------------------ text

  defp text(kind, data) do
    task = Task.async(fn -> read(kind, data) end)

    case Task.yield(task, @deadline) || Task.shutdown(task, :brutal_kill) do
      {:ok, text} when is_binary(text) -> clip(text)
      _ -> nil
    end
  end

  defp read(:markdown, data), do: if(String.valid?(data), do: data)
  defp read(:docx, data), do: docx(data)
  defp read(:pdf, data), do: pdf(data)
  defp read(:doc, data), do: doc(data)

  defp clip(text) do
    text =
      text
      |> String.replace(~r/[ \t]+\n/, "\n")
      |> String.replace(~r/\n{3,}/, "\n\n")
      |> String.trim()

    text =
      if byte_size(text) > @out,
        do: String.slice(binary_part(text, 0, @out), 0..-2//1),
        else: text

    if text == "", do: nil, else: text
  end

  # ------------------------------------------------------------------ docx

  defp docx(data) do
    with {:ok, entries} <- :zip.list_dir(data),
         [size] <-
           for({:zip_file, ~c"word/document.xml", info, _, _, _} <- entries, do: elem(info, 1)),
         true <- size <= @inflated,
         {:ok, [{_, xml}]} <- :zip.unzip(data, [:memory, file_list: [~c"word/document.xml"]]) do
      xml
      |> String.replace(~r{<w:tab/>}, "\t")
      |> String.replace(~r{</w:p>|<w:br/>}, "\n")
      |> String.replace(~r/<[^>]*>/, "")
      |> unescape()
    else
      _ -> nil
    end
  end

  defp unescape(s) do
    s
    |> String.replace(~r/&#x([0-9a-fA-F]+);/, fn m -> codepoint(m, 16) end)
    |> String.replace(~r/&#([0-9]+);/, fn m -> codepoint(m, 10) end)
    |> String.replace(["&lt;", "&gt;", "&quot;", "&apos;"], fn
      "&lt;" -> "<"
      "&gt;" -> ">"
      "&quot;" -> "\""
      "&apos;" -> "'"
    end)
    |> String.replace("&amp;", "&")
  end

  defp codepoint(m, base) do
    [_, n] = Regex.run(~r/&#x?([0-9a-fA-F]+);/, m)
    c = String.to_integer(n, base)
    if c in 0..0x10FFFF and c not in 0xD800..0xDFFF, do: <<c::utf8>>, else: ""
  end

  # ------------------------------------------------------------------- doc

  # A Word 97-2003 file: a compound file (CFB) whose WordDocument stream holds
  # the text and whose table stream (0Table or 1Table, by the FIB's flags)
  # holds the piece table mapping the characters onto that stream, each piece
  # 8-bit cp1252 or UTF-16LE. A field keeps its shown result, not its code.
  defp doc(<<0xD0CF11E0A1B11AE1::64, _::binary>> = data) do
    files = cfb(data)
    word = files["WordDocument"]
    <<_::binary-size(10), flags::little-16, _::binary>> = word
    <<_::binary-size(0x1A2), fc::little-32, lcb::little-32, _::binary>> = word
    table = if (flags &&& 0x0200) != 0, do: files["1Table"], else: files["0Table"]

    table
    |> binary_part(fc, lcb)
    |> pieces()
    |> Enum.map_join(fn
      {len, at, true} ->
        :unicode.characters_to_binary(binary_part(word, at, len), :latin1)

      {len, at, false} ->
        :unicode.characters_to_binary(binary_part(word, at, 2 * len), {:utf16, :little})
    end)
    |> String.replace(~r/\x13[^\x14\x15]*\x14?|\x15/u, "")
    |> String.replace(~r/[\r\x07\x0b\x0c]/u, "\n")
  rescue
    _ -> nil
  end

  defp doc(_), do: nil

  # The Clx: property runs (0x01) skipped, then the piece table (0x02):
  # n + 1 character positions and n descriptors of 8 bytes.
  defp pieces(<<1, n::little-16, _::binary-size(n), rest::binary>>), do: pieces(rest)

  defp pieces(<<2, lcb::little-32, plc::binary-size(lcb), _::binary>>) do
    n = div(lcb - 4, 12)
    {c, d} = {4 * (n + 1), 8 * n}
    <<cps::binary-size(^c), pcds::binary-size(^d), _::binary>> = plc
    cps = for <<cp::little-32 <- cps>>, do: cp
    fcs = for <<_::16, fc::little-32, _::16 <- pcds>>, do: fc

    for {{a, b}, fc} <- Enum.zip(Enum.zip(cps, tl(cps)), fcs) do
      narrow = (fc &&& 0x40000000) != 0
      at = fc &&& 0x3FFFFFFF
      {b - a, if(narrow, do: div(at, 2), else: at), narrow}
    end
  end

  # A compound file's streams by name: sectors chained through the FAT (its
  # sectors listed in the header's DIFAT and the DIFAT's own chain), the
  # directory, and the streams under the cutoff in the mini stream.
  defp cfb(data) do
    <<_::binary-size(0x1E), shift::little-16, mshift::little-16, _::binary-size(14),
      dir::little-32, _::binary-size(4), cutoff::little-32, minifat::little-32, _::binary-size(4),
      difat::little-32, _::binary-size(4), head::binary-size(436), _::binary>> = data

    size = 1 <<< shift
    sector = &binary_part(data, (&1 + 1) * size, size)

    fat =
      List.to_tuple(
        for s <- ids(head) ++ difat(difat, sector, size), <<x::little-32 <- sector.(s)>>, do: x
      )

    read = &Enum.map_join(chain(&1, fat), sector)
    entries = for <<e::binary-size(128) <- read.(dir)>>, do: e
    <<_::binary-size(116), root::little-32, _::binary>> = hd(entries)
    mini = read.(root)

    minifat =
      List.to_tuple(
        if minifat < 0xFFFFFFFA, do: for(<<x::little-32 <- read.(minifat)>>, do: x), else: []
      )

    msize = 1 <<< mshift

    for <<name::binary-size(64), len::little-16, 2, _::binary-size(49), start::little-32,
          bytes::little-32, _::binary-size(4) <- Enum.join(entries)>>,
        into: %{} do
      body =
        if bytes < cutoff,
          do: Enum.map_join(chain(start, minifat), &binary_part(mini, &1 * msize, msize)),
          else: read.(start)

      {:unicode.characters_to_binary(binary_part(name, 0, max(len - 2, 0)), {:utf16, :little}),
       binary_part(body, 0, bytes)}
    end
  end

  # Sector ids, the free and end markers left out.
  defp ids(bin), do: for(<<x::little-32 <- bin>>, x < 0xFFFFFFFA, do: x)

  # The DIFAT's own sectors: ids, the last word of each the next one.
  defp difat(n, sector, size, seen \\ 0)
  defp difat(n, _sector, _size, seen) when n >= 0xFFFFFFFA or seen > 1024, do: []

  defp difat(n, sector, size, seen) do
    words = size - 4
    <<list::binary-size(^words), next::little-32>> = sector.(n)
    ids(list) ++ difat(next, sector, size, seen + 1)
  end

  # A stream's sectors from its first, through the table; bounded by the table's length.
  defp chain(start, table) do
    start
    |> Stream.unfold(&if(&1 < tuple_size(table), do: {&1, elem(table, &1)}))
    |> Enum.take(tuple_size(table))
  end

  # ------------------------------------------------------------------- pdf

  # The pages in order, each content stream read through the fonts its page
  # names: subsets number their glyphs from the same codes, so one map merged
  # over every font reads one font's text through another's (a Skia CV had
  # every g an i). A file whose pages cannot be found has every text stream
  # read through the maps merged.
  defp pdf(<<"%PDF-", _::binary>> = data) do
    objs = data |> objects(0, 0, %{}) |> unpack()

    fonts =
      for {n, {d, _}} <- objs,
          {_, s} <- [objs[ref(d, "ToUnicode")]],
          is_binary(s),
          into: %{},
          do: {n, cmap(s, %{})}

    ctx = {objs, fonts, fonts |> Map.values() |> Enum.reduce(%{}, &Map.merge/2)}

    pages =
      for {_, {d, _}} <- objs,
          d =~ ~r{/Type\s*/Catalog},
          page <- pages(objs, ref(d, "Pages"), nil, 0),
          do: page

    texts =
      if pages == [],
        do:
          for({_, {_, s}} <- Enum.sort(objs), is_binary(s), s =~ "BT", do: shown(s, "", ctx, 0)),
        else: for({d, res} <- pages, do: shown(Enum.join(contents(objs, d), "\n"), res, ctx, 0))

    Enum.join(texts, "\n")
  end

  defp pdf(_), do: nil

  # Every object by number, a later one over an earlier (incremental updates):
  # its dictionary and its stream, inflated when its dictionary says
  # FlateDecode (nil under any other filter).
  defp objects(data, pos, budget, objs) do
    case Regex.run(~r/(\d+)\s+\d+\s+obj\b/, data, return: :index, offset: pos) do
      [{at, len}, {na, nl}] ->
        {obj, stop, budget} = object(data, at + len, budget)

        objects(
          data,
          stop,
          budget,
          Map.put(objs, String.to_integer(binary_part(data, na, nl)), obj)
        )

      nil ->
        objs
    end
  end

  defp object(data, start, budget) do
    size = byte_size(data)

    case :binary.match(data, ["endobj", "stream\r\n", "stream\n"], scope: {start, size - start}) do
      {at, 6} ->
        {{binary_part(data, start, at - start), nil}, at + 6, budget}

      {at, len} ->
        dict = binary_part(data, start, at - start)
        from = at + len

        {stop, raw} =
          case :binary.match(data, "endstream", scope: {from, size - from}) do
            {e, _} -> {e + 9, binary_part(data, from, e - from)}
            nil -> {size, binary_part(data, from, size - from)}
          end

        cond do
          budget > @inflated ->
            {{dict, nil}, stop, budget}

          dict =~ "/FlateDecode" ->
            s = Security.inflate(raw, @inflated - budget) || ""
            {{dict, s}, stop, budget + byte_size(s)}

          dict =~ "/Filter" ->
            {{dict, nil}, stop, budget}

          true ->
            {{dict, raw}, stop, budget + byte_size(raw)}
        end

      nil ->
        {{binary_part(data, start, size - start), nil}, size, budget}
    end
  end

  # The objects an object stream holds, each as its own.
  defp unpack(objs) do
    Enum.reduce(objs, objs, fn
      {_, {d, s}}, acc when is_binary(s) ->
        with true <- d =~ ~r{/Type\s*/ObjStm},
             [_, first] <- Regex.run(~r{/First\s+(\d+)}, d),
             first when first <= byte_size(s) <- String.to_integer(first),
             [_ | _] = heads <- Regex.scan(~r/\d+/, binary_part(s, 0, first)) do
          heads =
            heads
            |> Enum.map(fn [x] -> String.to_integer(x) end)
            |> Enum.chunk_every(2, 2, :discard)

          stops = Enum.map(Enum.drop(heads, 1), &List.last/1) ++ [byte_size(s) - first]

          for {[n, off], stop} <- Enum.zip(heads, stops),
              off <= stop,
              first + stop <= byte_size(s),
              into: acc,
              do: {n, {binary_part(s, first + off, stop - off), nil}}
        else
          _ -> acc
        end

      _, acc ->
        acc
    end)
  end

  # The page tree's leaves in order, each with the resources it has or inherits.
  defp pages(objs, n, res, depth) do
    case objs[n] do
      {d, _} when depth < 32 ->
        res = if d =~ "/Resources", do: entry(objs, d, "Resources"), else: res

        if d =~ ~r{/Type\s*/Pages\b} do
          kids = for [_, k] <- [Regex.run(~r{/Kids\s*\[([^\]]*)\]}, d)], n <- refs(k), do: n

          Enum.flat_map(kids, &pages(objs, &1, res, depth + 1))
        else
          [{d, res || ""}]
        end

      _ ->
        []
    end
  end

  defp contents(objs, page) do
    for [_, c] <- [Regex.run(~r{/Contents\s*(\[[^\]]*\]|\d+\s+\d+\s+R)}, page)],
        n <- refs(c),
        {_, s} <- [objs[n]],
        is_binary(s),
        do: s
  end

  # A dictionary's entry that is a dictionary, written in place or referenced.
  defp entry(objs, dict, key) do
    case Regex.run(~r{/#{key}\s*(<<|(\d+)\s+\d+\s+R)}, dict, return: :index) do
      [_, {at, _}] ->
        inner(dict, at + 2, at + 2, 1)

      [_, _, {na, nl}] ->
        case objs[String.to_integer(binary_part(dict, na, nl))] do
          {d, _} -> d
          nil -> ""
        end

      nil ->
        ""
    end
  end

  defp inner(d, from, at, depth) do
    case :binary.match(d, ["<<", ">>"], scope: {at, byte_size(d) - at}) do
      {i, 2} when binary_part(d, i, 2) == "<<" -> inner(d, from, i + 2, depth + 1)
      {i, 2} when depth == 1 -> binary_part(d, from, i - from)
      {i, 2} -> inner(d, from, i + 2, depth - 1)
      nil -> binary_part(d, from, byte_size(d) - from)
    end
  end

  defp ref(dict, key) do
    with [_, n] <- Regex.run(~r{/#{key}\s+(\d+)\s+\d+\s+R}, dict), do: String.to_integer(n)
  end

  defp refs(text),
    do: for([_, n] <- Regex.scan(~r/(\d+)\s+\d+\s+R\b/, text), do: String.to_integer(n))

  defp names(text),
    do:
      for(
        [_, k, n] <- Regex.scan(~r{/([^\s/<>\[\]()]+)\s+(\d+)\s+\d+\s+R}, text),
        do: {k, String.to_integer(n)}
      )

  # A ToUnicode map's codes: bfchar pairs and bfranges.
  defp cmap(s, map) do
    map =
      for [_, block] <- Regex.scan(~r/beginbfchar(.*?)endbfchar/s, s),
          [_, src, dst] <- Regex.scan(~r/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]*)>/, block),
          reduce: map,
          do: (m -> Map.put(m, hex(src), utf16(hex(dst))))

    for [_, block] <- Regex.scan(~r/beginbfrange(.*?)endbfrange/s, s),
        [_, lo, hi, dst] <-
          Regex.scan(~r/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(<[0-9A-Fa-f]*>|\[[^\]]*\])/, block),
        reduce: map do
      m ->
        {lo, hi, size} =
          {String.to_integer(lo, 16), String.to_integer(hi, 16), div(byte_size(lo) + 1, 2)}

        if hi - lo > 0xFFFF, do: m, else: range(m, lo, hi, size, dst)
    end
  end

  defp range(m, lo, hi, size, "[" <> _ = dsts) do
    Regex.scan(~r/<([0-9A-Fa-f]*)>/, dsts)
    |> Enum.zip(lo..hi)
    |> Enum.reduce(m, fn {[_, d], c}, m -> Map.put(m, <<c::size(size * 8)>>, utf16(hex(d))) end)
  end

  defp range(m, lo, hi, size, "<" <> dst) do
    base = dst |> String.trim_trailing(">") |> hex()

    {prefix, last} =
      if byte_size(base) >= 2,
        do:
          {binary_part(base, 0, byte_size(base) - 2),
           :binary.decode_unsigned(binary_part(base, byte_size(base) - 2, 2))},
        else: {"", 0}

    Enum.reduce(lo..hi, m, fn c, m ->
      Map.put(m, <<c::size(size * 8)>>, utf16(prefix <> <<last + c - lo::16>>))
    end)
  end

  defp hex(h),
    do: Base.decode16!(if(rem(byte_size(h), 2) == 1, do: h <> "0", else: h), case: :mixed)

  defp utf16(b) do
    case :unicode.characters_to_binary(b, {:utf16, :big}) do
      s when is_binary(s) -> s
      _ -> ""
    end
  end

  # The strings a content stream shows, a line break where text moves down
  # (a move along the line adds nothing: producers place glyph by glyph, and
  # a space is a glyph or a TJ gap), each string through its font's map and a
  # form's strings where the form is drawn.
  defp shown(s, res, {objs, fonts, merged} = ctx, depth) do
    named = for {k, n} <- names(entry(objs, res, "Font")), into: %{}, do: {k, fonts[n] || %{}}
    forms = Map.new(names(entry(objs, res, "XObject")))

    {_, _, _, out} =
      Enum.reduce(tokens(s, []), {[], nil, merged, []}, fn
        {:op, "Tf"}, {[_, {:name, f} | _], y, _, out} ->
          {[], y, Map.get(named, f, merged), out}

        {:op, "Do"}, {[{:name, x} | _], y, cmap, out} ->
          {[], y, cmap, [out | form(objs[forms[x]], res, ctx, depth)]}

        {:op, op}, {args, y, cmap, out} when op in ["Tj", "'", "\""] ->
          {[], y, cmap, [out | for({:str, b} <- Enum.take(args, 1), do: decode(b, cmap))]}

        {:op, "TJ"}, {[{:array, items} | _], y, cmap, out} ->
          {[], y, cmap,
           [
             out
             | Enum.map(items, fn
                 {:str, b} -> decode(b, cmap)
                 n when n < -250 -> " "
                 _ -> ""
               end)
           ]}

        {:op, op}, {[ty, _ | _], y, cmap, out} when op in ["Td", "TD"] and is_number(ty) ->
          {[], y, cmap, [out | if(ty != 0, do: "\n", else: "")]}

        {:op, "Tm"}, {[ty | _], y, cmap, out} when is_number(ty) ->
          {[], ty, cmap, [out | if(y != nil and abs(ty - y) > 1, do: "\n", else: "")]}

        {:op, "T*"}, {_, y, cmap, out} ->
          {[], y, cmap, [out | "\n"]}

        {:op, _}, {_, y, cmap, out} ->
          {[], y, cmap, out}

        arg, {args, y, cmap, out} ->
          {[arg | args], y, cmap, out}
      end)

    IO.iodata_to_binary(out)
  end

  defp form({d, s}, res, {objs, _, _} = ctx, depth) when is_binary(s) and depth < 8 do
    cond do
      not (d =~ ~r{/Subtype\s*/Form}) -> ""
      d =~ "/Resources" -> shown(s, entry(objs, d, "Resources"), ctx, depth + 1)
      true -> shown(s, res, ctx, depth + 1)
    end
  end

  defp form(_, _, _, _), do: ""

  defp decode(b, cmap) do
    two = for <<c::binary-2 <- b>>, do: Map.get(cmap, c)
    one = for <<c::binary-1 <- b>>, do: Map.get(cmap, c)

    cond do
      map_size(cmap) > 0 and rem(byte_size(b), 2) == 0 and two != [] and Enum.all?(two) ->
        Enum.join(two)

      map_size(cmap) > 0 and Enum.all?(one) ->
        Enum.join(one)

      true ->
        :unicode.characters_to_binary(b, :latin1)
    end
  end

  # Operands, names and operators; dictionaries and comments pass by.
  defp tokens(<<>>, acc), do: Enum.reverse(acc)
  defp tokens(<<c, r::binary>>, acc) when c in ~c" \t\r\n\f\0", do: tokens(r, acc)
  defp tokens(<<"%", r::binary>>, acc), do: tokens(r |> :binary.split("\n") |> List.last(), acc)
  defp tokens(<<"<<", r::binary>>, acc), do: tokens(r, acc)
  defp tokens(<<">>", r::binary>>, acc), do: tokens(r, acc)

  defp tokens(<<"(", r::binary>>, acc) do
    {str, r} = literal(r, 0, [])
    tokens(r, [{:str, str} | acc])
  end

  defp tokens(<<"<", r::binary>>, acc) do
    [h, r] = with([_] <- :binary.split(r, ">"), do: [r, ""])
    tokens(r, [{:str, h |> String.replace(~r/[^0-9A-Fa-f]/, "") |> hex()} | acc])
  end

  defp tokens(<<"[", r::binary>>, acc) do
    [inner, r] = with([_] <- :binary.split(r, "]"), do: [r, ""])
    tokens(r, [{:array, tokens(inner, [])} | acc])
  end

  defp tokens(<<"/", r::binary>>, acc) do
    [name] = Regex.run(~r/^[^\s\/\[\]()<>{}%]*/, r)
    tokens(binary_part(r, byte_size(name), byte_size(r) - byte_size(name)), [{:name, name} | acc])
  end

  defp tokens(<<c, _::binary>> = s, acc) when c in ~c"+-.0123456789" do
    [n | _] = Regex.run(~r/^[+-]?(\d+\.?\d*|\.\d+)/, s) || [<<c>>]
    r = binary_part(s, byte_size(n), byte_size(s) - byte_size(n))
    tokens(r, [number(n) | acc])
  end

  defp tokens(s, acc) do
    case Regex.run(~r/^[A-Za-z'"*]+/, s) do
      [op] ->
        tokens(binary_part(s, byte_size(op), byte_size(s) - byte_size(op)), [{:op, op} | acc])

      nil ->
        tokens(binary_part(s, 1, byte_size(s) - 1), acc)
    end
  end

  defp number(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0
    end
  end

  # A literal string's bytes, its escapes read and its parentheses nested.
  defp literal(<<>>, _depth, acc), do: {IO.iodata_to_binary(acc), ""}
  defp literal(<<")", r::binary>>, 0, acc), do: {IO.iodata_to_binary(acc), r}
  defp literal(<<")", r::binary>>, d, acc), do: literal(r, d - 1, [acc, ")"])
  defp literal(<<"(", r::binary>>, d, acc), do: literal(r, d + 1, [acc, "("])

  defp literal(<<"\\", c, r::binary>>, d, acc) do
    case c do
      ?n -> literal(r, d, [acc, "\n"])
      ?r -> literal(r, d, [acc, "\r"])
      ?t -> literal(r, d, [acc, "\t"])
      ?b -> literal(r, d, [acc, "\b"])
      ?f -> literal(r, d, [acc, "\f"])
      ?\n -> literal(r, d, acc)
      c when c in ?0..?7 -> octal(<<c, r::binary>>, d, acc)
      c -> literal(r, d, [acc, c])
    end
  end

  defp literal(<<c, r::binary>>, d, acc), do: literal(r, d, [acc, c])

  defp octal(s, d, acc) do
    [o] = Regex.run(~r/^[0-7]{1,3}/, s)
    r = binary_part(s, byte_size(o), byte_size(s) - byte_size(o))
    literal(r, d, [acc, String.to_integer(o, 8) &&& 0xFF])
  end
end
