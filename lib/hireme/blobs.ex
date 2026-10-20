defmodule Hireme.Blobs do
  @moduledoc """
  A CV's files by SHA-256, each account's own, in `blobs` (never on the
  wire; `HiremeWeb.Blobs` serves them over HTTP). `put/3` keeps the bytes
  once and reads their text then, for the rules and the agents: markdown as
  it is, a docx's paragraphs, a Word 97-2003 doc's pieces, a PDF's shown strings through its fonts'
  ToUnicode maps (a font without one reads as Latin-1). A file whose text
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

  defp pdf(<<"%PDF-", _::binary>> = data) do
    streams = streams(data)
    cmap = for s <- streams, String.contains?(s, "begincmap"), reduce: %{}, do: (m -> cmap(s, m))
    for(s <- streams, String.contains?(s, "BT"), do: shown(s, cmap)) |> Enum.join("\n")
  end

  defp pdf(_), do: nil

  # Every stream's bytes, inflated when its dictionary says FlateDecode;
  # images and other filters are left out.
  defp streams(data) do
    {_, out} =
      data
      |> :binary.matches(["stream\r\n", "stream\n"])
      |> Enum.reduce({0, []}, fn {at, len}, {budget, acc} ->
        dict = binary_part(data, max(at - 512, 0), min(at, 512))
        dict = dict |> :binary.split("obj") |> List.last()
        body = binary_part(data, at + len, byte_size(data) - at - len)
        [body | _] = :binary.split(body, "endstream")

        cond do
          budget > @inflated or String.ends_with?(binary_part(data, 0, at), "end") ->
            {budget, acc}

          dict =~ "/FlateDecode" ->
            s = Security.inflate(body, @inflated - budget) || ""
            {budget + byte_size(s), [s | acc]}

          dict =~ "/Filter" ->
            {budget, acc}

          true ->
            {budget + byte_size(body), [body | acc]}
        end
      end)

    Enum.reverse(out)
  end

  # A ToUnicode map's codes, merged over every font: bfchar pairs and bfranges.
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
  # a space is a glyph or a TJ gap).
  defp shown(s, cmap) do
    {_, _, out} =
      Enum.reduce(tokens(s, []), {[], nil, []}, fn
        {:op, op}, {args, y, out} when op in ["Tj", "'", "\""] ->
          {[], y, [out | for({:str, b} <- Enum.take(args, 1), do: decode(b, cmap))]}

        {:op, "TJ"}, {[{:array, items} | _], y, out} ->
          {[], y,
           [
             out
             | Enum.map(items, fn
                 {:str, b} -> decode(b, cmap)
                 n when n < -250 -> " "
                 _ -> ""
               end)
           ]}

        {:op, op}, {[ty, _ | _], y, out} when op in ["Td", "TD"] and is_number(ty) ->
          {[], y, [out | if(ty != 0, do: "\n", else: "")]}

        {:op, "Tm"}, {[ty | _], y, out} when is_number(ty) ->
          {[], ty, [out | if(y != nil and abs(ty - y) > 1, do: "\n", else: "")]}

        {:op, "T*"}, {_, y, out} ->
          {[], y, [out | "\n"]}

        {:op, _}, {_, y, out} ->
          {[], y, out}

        arg, {args, y, out} ->
          {[arg | args], y, out}
      end)

    IO.iodata_to_binary(out)
  end

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

  # Operands and operators; dictionaries, names and comments pass by.
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

  defp tokens(<<"/", r::binary>>, acc), do: tokens(skip_word(r), acc)

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

  defp skip_word(s), do: Regex.replace(~r/^[^\s\/\[\]()<>{}%]*/, s, "")

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
