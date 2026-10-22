defmodule Hireme.Gmail.Mime do
  @moduledoc """
  A mail as data: an RFC 5322 message, or its header block alone (the IMAP
  envelope pass), read into what the filer correlates. `parse/1` answers
  `{:error, :too_large}` past 25 MiB and `{:ok, message}` for anything else,
  however malformed. Inbound mail is someone else's bytes, so the parser
  never raises, never fetches anything (no remote content; attachments are
  listed, never decoded), and its work is linear in the input.

  Bounds, each cut setting `truncated`: 1000 header lines; 8 KiB per decoded
  header value and per list of addresses; 8 KiB of References (the first id
  and as many of the newest as fit); 200 parts; multipart nesting 10 deep
  (deeper is opaque); 2 MiB of text parts read and 256 KiB of text kept.

  The key is the Message-ID when there is one, else a SHA-256 over the From
  address, the Date header, the subject and the first 4 KiB of text: the same
  for one mail through the Gmail link and the domain pipe, whatever transport
  headers or line endings each copy carries.
  """
  import Bitwise
  require Logger

  @type address :: %{name: String.t() | nil, addr: String.t()}
  @type attachment :: %{name: String.t() | nil, type: String.t(), size: non_neg_integer()}
  @type report :: %{
          kind: :bounce | :delay | :delivered | :other,
          original_message_id: String.t() | nil,
          status: String.t() | nil,
          action: String.t() | nil,
          diagnostic: String.t() | nil,
          recipient: String.t() | nil
        }
  @type t :: %{
          message_id: String.t() | nil,
          key: String.t(),
          in_reply_to: String.t() | nil,
          refs: [String.t()],
          from: address() | nil,
          sender: address() | nil,
          reply_to: [address()],
          to: [address()],
          cc: [address()],
          subject: String.t(),
          date: integer() | nil,
          headers: %{String.t() => String.t()},
          text: String.t(),
          truncated: boolean(),
          attachments: [attachment()],
          report: report() | nil
        }

  @max 25 * 1024 * 1024
  @parts 200
  @depth 10
  @lines 1000
  @field 8 * 1024
  # The raw bytes one header may contribute before decoding: encoded words
  # and folding make the raw text longer than the 8 KiB kept.
  @raw 64 * 1024
  @refs 8 * 1024
  @text 256 * 1024
  @key_text 4096
  # Text part bytes read per message; past it no more is read as text.
  @text_in 2 * 1024 * 1024
  @href 2048
  # Parameters read from one header (a long name's RFC 2231 sections included).
  @params 64
  @epoch_days 719_528
  @bad <<0xFFFD::utf8>>
  @nbsp <<0xA0::utf8>>

  @kept ~w(list-id list-unsubscribe auto-submitted precedence return-path x-autoreply
           x-auto-response-suppress x-failed-recipients)
  @status ~w(message/delivery-status message/global-delivery-status)
  @original ~w(message/rfc822 text/rfc822-headers message/global message/global-headers)

  @wsp [?\s, ?\t, ?\r, ?\n]
  # Where a word in an address ends; "=?" may open an encoded word, "[" a domain literal.
  @stops [" ", "\t", "\r", "\n", "\"", "(", ")", "<", ">", ",", ";", ":", "=?", "["]
  # C0 but tab and newline, DEL, and C1 (U+0080..U+009F, <<0xC2, b>> in UTF-8).
  @controls Enum.map(Enum.to_list(0..8) ++ Enum.to_list(11..31) ++ [127], &<<&1>>) ++
              Enum.map(0x80..0x9F, &<<0xC2, &1>>)

  @charsets for {canonical, names} <- [
                  utf8: ~w(utf-8 utf8 unicode-1-1-utf-8),
                  ascii:
                    ~w(us-ascii ascii us ansi_x3.4-1968 iso-ir-6 iso646-us cp367 ibm367 csascii),
                  # Labels for ISO-8859-1 read as windows-1252, as the WHATWG
                  # Encoding Standard has browsers do: mail declaring latin1
                  # routinely carries cp1252 quotes and dashes in 0x80-0x9F.
                  cp1252:
                    ~w(windows-1252 cp1252 x-cp1252 win-1252 cp-1252 windows1252 iso-8859-1 iso8859-1
                        iso_8859-1 iso_8859-1:1987 latin1 latin-1 l1 cp819 ibm819 iso-ir-100 csisolatin1),
                  latin9: ~w(iso-8859-15 iso8859-15 iso_8859-15 latin9 latin-9 l9 csisolatin9),
                  utf16: ~w(utf-16 utf16),
                  utf16le: ~w(utf-16le utf16le),
                  utf16be: ~w(utf-16be utf16be)
                ],
                name <- names,
                into: %{"" => :ascii},
                do: {name, canonical}

  # windows-1252 where it differs from Latin-1; 0x81, 0x8D, 0x8F, 0x90 and
  # 0x9D stay C1, as WHATWG maps them.
  @cp1252 %{
    0x80 => 0x20AC,
    0x82 => 0x201A,
    0x83 => 0x0192,
    0x84 => 0x201E,
    0x85 => 0x2026,
    0x86 => 0x2020,
    0x87 => 0x2021,
    0x88 => 0x02C6,
    0x89 => 0x2030,
    0x8A => 0x0160,
    0x8B => 0x2039,
    0x8C => 0x0152,
    0x8E => 0x017D,
    0x91 => 0x2018,
    0x92 => 0x2019,
    0x93 => 0x201C,
    0x94 => 0x201D,
    0x95 => 0x2022,
    0x96 => 0x2013,
    0x97 => 0x2014,
    0x98 => 0x02DC,
    0x99 => 0x2122,
    0x9A => 0x0161,
    0x9B => 0x203A,
    0x9C => 0x0153,
    0x9E => 0x017E,
    0x9F => 0x0178
  }
  @latin9 %{
    0xA4 => 0x20AC,
    0xA6 => 0x0160,
    0xA8 => 0x0161,
    0xB4 => 0x017D,
    0xB8 => 0x017E,
    0xBC => 0x0152,
    0xBD => 0x0153,
    0xBE => 0x0178
  }
  @cp1252_bytes List.to_tuple(for b <- 0..255, do: <<Map.get(@cp1252, b, b)::utf8>>)
  @latin9_bytes List.to_tuple(for b <- 0..255, do: <<Map.get(@latin9, b, b)::utf8>>)

  # Base64 values by byte, "=" as :pad; any other byte is skipped.
  @b64 ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
       |> Enum.with_index()
       |> Map.new()
       |> then(fn values ->
         List.to_tuple(for c <- 0..255, do: Map.get(values, c, if(c == ?=, do: :pad)))
       end)

  @months Map.new(Enum.with_index(~w(jan feb mar apr may jun jul aug sep oct nov dec), 1))
  @zones %{
    "ut" => 0,
    "utc" => 0,
    "gmt" => 0,
    "z" => 0,
    "est" => -300,
    "edt" => -240,
    "cst" => -360,
    "cdt" => -300,
    "mst" => -420,
    "mdt" => -360,
    "pst" => -480,
    "pdt" => -420
  }

  # What a tag does to the text; any other tag does nothing. A paragraph
  # stands apart by an empty line, a line (a div, a table row) by a line
  # break, and each <br> breaks once more.
  @tags Map.merge(
          Map.merge(
            Map.new(
              ~w(p h1 h2 h3 h4 h5 h6 table ul ol dl blockquote hr section article header footer
                 form nav main aside figure),
              &{&1, :para}
            ),
            Map.new(~w(div tr dt dd center address caption figcaption), &{&1, :line})
          ),
          %{
            "br" => :br,
            "script" => :raw,
            "style" => :raw,
            "head" => :head,
            "template" => :template,
            "body" => :body,
            "a" => :a,
            "li" => :li,
            "td" => :cell,
            "th" => :cell,
            "pre" => :pre
          }
        )
  # Named references by code point (nil: nothing shown).
  @entities Map.new(
              [
                amp: ?&,
                lt: ?<,
                gt: ?>,
                quot: ?",
                apos: ?',
                nbsp: ?\s,
                ensp: ?\s,
                emsp: ?\s,
                thinsp: ?\s,
                shy: nil,
                zwnj: nil,
                zwj: nil,
                ndash: 0x2013,
                mdash: 0x2014,
                hellip: 0x2026,
                lsquo: 0x2018,
                rsquo: 0x2019,
                sbquo: 0x201A,
                ldquo: 0x201C,
                rdquo: 0x201D,
                bdquo: 0x201E,
                lsaquo: 0x2039,
                rsaquo: 0x203A,
                laquo: 0xAB,
                raquo: 0xBB,
                copy: 0xA9,
                reg: 0xAE,
                trade: 0x2122,
                euro: 0x20AC,
                pound: 0xA3,
                yen: 0xA5,
                cent: 0xA2,
                sect: 0xA7,
                para: 0xB6,
                deg: 0xB0,
                plusmn: 0xB1,
                micro: 0xB5,
                middot: 0xB7,
                bull: 0x2022,
                dagger: 0x2020,
                permil: 0x2030,
                times: 0xD7,
                divide: 0xF7,
                frac12: 0xBD,
                frac14: 0xBC,
                frac34: 0xBE,
                iexcl: 0xA1,
                iquest: 0xBF,
                larr: 0x2190,
                rarr: 0x2192,
                agrave: 0xE0,
                aacute: 0xE1,
                acirc: 0xE2,
                atilde: 0xE3,
                auml: 0xE4,
                aring: 0xE5,
                aelig: 0xE6,
                ccedil: 0xE7,
                egrave: 0xE8,
                eacute: 0xE9,
                ecirc: 0xEA,
                euml: 0xEB,
                igrave: 0xEC,
                iacute: 0xED,
                icirc: 0xEE,
                iuml: 0xEF,
                ntilde: 0xF1,
                ograve: 0xF2,
                oacute: 0xF3,
                ocirc: 0xF4,
                otilde: 0xF5,
                ouml: 0xF6,
                oslash: 0xF8,
                ugrave: 0xF9,
                uacute: 0xFA,
                ucirc: 0xFB,
                uuml: 0xFC,
                yacute: 0xFD,
                yuml: 0xFF,
                szlig: 0xDF,
                oelig: 0x153,
                scaron: 0x161,
                Agrave: 0xC0,
                Aacute: 0xC1,
                Auml: 0xC4,
                Aring: 0xC5,
                AElig: 0xC6,
                Ccedil: 0xC7,
                Egrave: 0xC8,
                Eacute: 0xC9,
                Iacute: 0xCD,
                Ntilde: 0xD1,
                Oacute: 0xD3,
                Ouml: 0xD6,
                Oslash: 0xD8,
                Uacute: 0xDA,
                Uuml: 0xDC,
                OElig: 0x152,
                Scaron: 0x160
              ],
              fn {name, cp} -> {Atom.to_string(name), if(cp, do: <<cp::utf8>>, else: "")} end
            )

  defguardp hex?(c) when c in ?0..?9 or c in ?A..?F or c in ?a..?f

  @doc """
  The mail in `raw` (a whole message or its header block) as `t:t/0`, or
  `{:error, :too_large}` past 25 MiB.

  `message_id`, `in_reply_to` and `refs` are canonical ids: angle brackets
  and whitespace stripped, case kept. Addresses are lowercased, display names
  decoded. `date` is unix seconds. `text` is the plain text of the inline
  text parts (HTML converted, a link kept as `text (url)`). `report` reads a
  delivery status notification (RFC 3464), else nil.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, :too_large}
  def parse(raw) when is_binary(raw) and byte_size(raw) > @max, do: {:error, :too_large}

  def parse(raw) when is_binary(raw) do
    {:ok, message(raw)}
  rescue
    # Every rule here is total; should one still raise, the mail is kept as
    # an opaque one rather than taking its mailbox's sync down with it.
    e ->
      at =
        case __STACKTRACE__ do
          [frame | _] -> Exception.format_stacktrace_entry(frame)
          [] -> "?"
        end

      Logger.error(
        "a mail read as opaque: the MIME parser raised #{inspect(e.__struct__)} at #{at}"
      )

      {:ok, opaque(raw)}
  end

  defp message(raw) do
    {head, body} = split(raw)
    {fields, cut} = fields(head)

    read = %{
      subject: unstructured(fields, "subject"),
      date: value(fields, "date", @field),
      message_id: value(fields, "message-id", @field),
      in_reply_to: value(fields, "in-reply-to", @field),
      refs: refs(fields),
      from: addresses(first(fields, "from")),
      sender: addresses(first(fields, "sender")),
      reply_to: addresses(first(fields, "reply-to")),
      to: addresses(all(fields, "to")),
      cc: addresses(all(fields, "cc")),
      headers: kept(fields),
      body: body(fields, body)
    }

    v = Map.new(read, fn {k, {value, _}} -> {k, value} end)
    {text, attachments, report} = v.body
    id = msg_id(v.message_id)
    from = List.first(v.from)
    subject = v.subject || ""
    date = if v.date, do: String.trim(v.date), else: ""
    head = binary_part(text, 0, min(byte_size(text), @key_text))

    %{
      message_id: id,
      key: id || sha_key([if(from, do: from.addr, else: ""), date, subject, head]),
      in_reply_to: msg_id(v.in_reply_to),
      refs: v.refs,
      from: from,
      sender: List.first(v.sender),
      reply_to: v.reply_to,
      to: v.to,
      cc: v.cc,
      subject: subject,
      date: date(date),
      headers: v.headers,
      text: text,
      truncated: cut or Enum.any?(read, fn {_, {_, cut}} -> cut end),
      attachments: attachments,
      report: report
    }
  end

  defp sha_key(parts) do
    digest = :crypto.hash(:sha256, Enum.intersperse(parts, "\n"))
    "sha256-" <> Base.encode16(digest, case: :lower) <> "@hireme.invalid"
  end

  defp opaque(raw) do
    %{
      message_id: nil,
      key: sha_key([raw]),
      in_reply_to: nil,
      refs: [],
      from: nil,
      sender: nil,
      reply_to: [],
      to: [],
      cc: [],
      subject: "",
      date: nil,
      headers: %{},
      text: "",
      truncated: true,
      attachments: [],
      report: nil
    }
  end

  ## The header block

  # The header block ends at the first empty line; a message without one is
  # all headers.
  defp split(<<"\r\n", body::binary>>), do: {"", body}
  defp split(<<"\n", body::binary>>), do: {"", body}

  defp split(raw) do
    case :binary.match(raw, ["\n\n", "\n\r\n"]) do
      {at, n} -> {binary_part(raw, 0, at), binary_part(raw, at + n, byte_size(raw) - at - n)}
      :nomatch -> {raw, ""}
    end
  end

  # [{name, pieces}] in order, names lowercased; a value is its line pieces,
  # unfolded by joining them. A line that names no header keeps its
  # continuations to itself and is dropped.
  defp fields(head) do
    {lines, cut} = lines(head, 0, @lines, [])
    fields = Enum.reduce(lines, [], &field/2)

    {for({name, pieces} <- Enum.reverse(fields), name != nil, do: {name, Enum.reverse(pieces)}),
     cut}
  end

  defp lines(head, at, _left, acc) when at >= byte_size(head), do: {Enum.reverse(acc), false}
  defp lines(_head, _at, 0, acc), do: {Enum.reverse(acc), true}

  defp lines(head, at, left, acc) do
    size = byte_size(head)

    case :binary.match(head, "\n", scope: {at, size - at}) do
      {nl, 1} -> lines(head, nl + 1, left - 1, [chomp(binary_part(head, at, nl - at)) | acc])
      :nomatch -> {Enum.reverse([chomp(binary_part(head, at, size - at)) | acc]), false}
    end
  end

  defp chomp(line) do
    n = byte_size(line)
    if n > 0 and :binary.last(line) == ?\r, do: binary_part(line, 0, n - 1), else: line
  end

  defp field(<<c, _::binary>> = line, [{name, pieces} | rest]) when c in [?\s, ?\t],
    do: [{name, [line | pieces]} | rest]

  defp field(line, acc) do
    with {at, 1} <- :binary.match(line, ":", scope: {0, min(byte_size(line), 129)}),
         name = trim_wsp(binary_part(line, 0, at)),
         true <- name != "" and printable?(name) do
      [{ascii_downcase(name), [binary_part(line, at + 1, byte_size(line) - at - 1)]} | acc]
    else
      _ -> [{nil, []} | acc]
    end
  end

  defp printable?(<<c, rest::binary>>) when c in 33..126, do: printable?(rest)
  defp printable?(rest), do: rest == ""

  defp trim_wsp(name) do
    n = byte_size(name)

    if n > 0 and :binary.last(name) in [?\s, ?\t],
      do: trim_wsp(binary_part(name, 0, n - 1)),
      else: name
  end

  defp first(fields, name) do
    case List.keyfind(fields, name, 0) do
      {_, pieces} -> [pieces]
      nil -> []
    end
  end

  defp all(fields, name), do: for({^name, pieces} <- fields, do: pieces)

  # The first `name` header's value, unfolded, at most `max` bytes: {text |
  # nil, cut}.
  defp value(fields, name, max) do
    case List.keyfind(fields, name, 0) do
      {_, pieces} -> join(pieces, max)
      nil -> {nil, false}
    end
  end

  defp join(pieces, max) do
    {bin, cut} = take(pieces, max, [])
    {utf8(bin), cut}
  end

  defp take([], _left, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), false}

  defp take([p | rest], left, acc) when byte_size(p) <= left,
    do: take(rest, left - byte_size(p), [p | acc])

  defp take([p | _], left, acc),
    do: {IO.iodata_to_binary(Enum.reverse([clip(p, left) | acc])), true}

  ## Header values

  # A decoded, unfolded one-line value: {text | nil, cut}.
  defp unstructured(fields, name) do
    case value(fields, name, @raw) do
      {nil, cut} ->
        {nil, cut}

      {raw, cut} ->
        {text, cut2} = raw |> words() |> line() |> String.trim() |> bounded(@field)
        {text, cut or cut2}
    end
  end

  defp kept(fields) do
    {type, cut} = value(fields, "content-type", @field)
    read = [{"content-type", {type && type |> line() |> String.trim(), cut}}]
    read = read ++ for(name <- @kept, do: {name, unstructured(fields, name)})

    {for({name, {v, _}} <- read, v != nil, into: %{}, do: {name, v}),
     Enum.any?(read, fn {_, {_, cut}} -> cut end)}
  end

  defp msg_id(nil), do: nil

  defp msg_id(v) do
    inner =
      case :binary.split(v, "<") do
        [_, rest] -> rest |> :binary.split(">") |> hd()
        [_] -> v |> uncomment() |> String.split() |> List.first("")
      end

    case id_chars(inner) do
      "" -> nil
      id -> id
    end
  end

  defp id_chars(s), do: for(<<c <- s>>, c > 0x20 and c not in [0x7F, ?<, ?>], into: "", do: <<c>>)

  # References past the raw bound keep its first id and its newest end.
  defp refs(fields) do
    case List.keyfind(fields, "references", 0) do
      nil ->
        {[], false}

      {_, pieces} ->
        if IO.iodata_length(pieces) <= @raw do
          {v, _} = join(pieces, @raw)
          bound(ids(v))
        else
          {head, _} = join(pieces, @field)
          {ids, _} = bound(Enum.uniq(Enum.take(ids(head), 1) ++ ids(tail(pieces, @raw - @field))))
          {ids, true}
        end
    end
  end

  defp ids(v) do
    ids =
      if :binary.match(v, "<") == :nomatch,
        do: v |> uncomment() |> String.split() |> Enum.map(&id_chars/1),
        else: angled(v, [])

    ids |> Enum.reject(&(&1 == "")) |> Enum.uniq()
  end

  defp angled(v, acc) do
    with [_, rest] <- :binary.split(v, "<"),
         [inner, rest] <- :binary.split(rest, ">") do
      id = inner |> :binary.split("<", [:global]) |> List.last() |> id_chars()
      angled(rest, [id | acc])
    else
      _ -> Enum.reverse(acc)
    end
  end

  defp tail(pieces, n) do
    {kept, _} =
      pieces
      |> Enum.reverse()
      |> Enum.reduce({[], n}, fn
        _, {acc, 0} -> {acc, 0}
        p, {acc, left} when byte_size(p) <= left -> {[p | acc], left - byte_size(p)}
        p, {acc, left} -> {[binary_part(p, byte_size(p) - left, left) | acc], 0}
      end)

    utf8(IO.iodata_to_binary(kept))
  end

  defp bound([]), do: {[], false}

  defp bound([first | rest] = ids) do
    if Enum.sum_by(ids, &byte_size/1) <= @refs do
      {ids, false}
    else
      {newest, _} =
        rest
        |> Enum.reverse()
        |> Enum.reduce_while({[], @refs - byte_size(first)}, fn id, {acc, left} ->
          if byte_size(id) <= left,
            do: {:cont, {[id | acc], left - byte_size(id)}},
            else: {:halt, {acc, left}}
        end)

      {[first | newest], true}
    end
  end

  ## Addresses (RFC 5322 address lists)

  # Mailboxes from the header's occurrences in order, each address once, at
  # most 8 KiB of names and addresses together, read from at most twice that.
  defp addresses(occurrences) do
    stops = :binary.compile_pattern(@stops)

    {lists, cut, _} =
      Enum.reduce(occurrences, {[], false, 2 * @field}, fn
        _, {acc, _, 0} ->
          {acc, true, 0}

        pieces, {acc, cut, left} ->
          {v, c} = join(pieces, left)
          {[mailboxes(v, stops) | acc], cut or c, max(left - byte_size(v), 0)}
      end)

    {list, cut2} = keep(lists |> Enum.reverse() |> Enum.concat(), MapSet.new(), @field, [])
    {list, cut or cut2}
  end

  defp keep([], _seen, _left, acc), do: {Enum.reverse(acc), false}

  defp keep([m | rest], seen, left, acc) do
    n = byte_size(m.addr) + byte_size(m.name || "")

    cond do
      MapSet.member?(seen, m.addr) -> keep(rest, seen, left, acc)
      n > left -> {Enum.reverse(acc), true}
      true -> keep(rest, MapSet.put(seen, m.addr), left - n, [m | acc])
    end
  end

  defp mailboxes(v, stops) do
    v |> lex(stops, []) |> entries([], false, []) |> Enum.flat_map(&mailbox/1)
  end

  # Tokens: {:w, word}, {:q, quoted text}, {:c, comment}, {:a, angle-addr},
  # :sp, :comma, :semi, :colon. An encoded word is one word even when its
  # text holds specials, as broken mailers write them.
  defp lex(<<>>, _stops, acc), do: Enum.reverse(acc)
  defp lex(<<c, rest::binary>>, stops, [:sp | _] = acc) when c in @wsp, do: lex(rest, stops, acc)
  defp lex(<<c, rest::binary>>, stops, acc) when c in @wsp, do: lex(rest, stops, [:sp | acc])

  defp lex(<<?", rest::binary>>, stops, acc) do
    {text, rest} = quoted(rest, [])
    lex(rest, stops, [{:q, text} | acc])
  end

  defp lex(<<?(, rest::binary>>, stops, acc) do
    {text, rest} = comment(rest, 1, [])
    lex(rest, stops, [{:c, text} | acc])
  end

  defp lex(<<?<, rest::binary>>, stops, acc) do
    case :binary.split(rest, ">") do
      [inner, rest] -> lex(rest, stops, [{:a, inner} | acc])
      [inner] -> lex("", stops, [{:a, inner} | acc])
    end
  end

  defp lex(<<?,, rest::binary>>, stops, acc), do: lex(rest, stops, [:comma | acc])
  defp lex(<<?;, rest::binary>>, stops, acc), do: lex(rest, stops, [:semi | acc])
  defp lex(<<?:, rest::binary>>, stops, acc), do: lex(rest, stops, [:colon | acc])
  defp lex(<<c, rest::binary>>, stops, acc) when c in [?), ?>], do: lex(rest, stops, acc)

  defp lex(s, stops, acc) do
    {word, rest} = word(s, 0, stops)
    lex(rest, stops, [{:w, word} | acc])
  end

  defp word(s, from, stops) do
    size = byte_size(s)

    case :binary.match(s, stops, scope: {from, size - from}) do
      :nomatch ->
        {s, ""}

      {p, 2} ->
        case encoded(s, p + 2) do
          {:ok, _, _, _, next} -> word(s, next, stops)
          :error -> word(s, p + 2, stops)
        end

      {p, 1} ->
        if :binary.at(s, p) == ?[,
          do: word(s, skip(s, p + 1, "]"), stops),
          else: {binary_part(s, 0, p), binary_part(s, p, size - p)}
    end
  end

  defp quoted(s, acc) do
    case :binary.match(s, ["\"", "\\"]) do
      :nomatch ->
        {IO.iodata_to_binary(Enum.reverse([s | acc])), ""}

      {p, 1} ->
        before = binary_part(s, 0, p)

        case binary_part(s, p, byte_size(s) - p) do
          <<?\\, c, rest::binary>> -> quoted(rest, [<<c>>, before | acc])
          <<?", rest::binary>> -> {IO.iodata_to_binary(Enum.reverse([before | acc])), rest}
          _ -> {IO.iodata_to_binary(Enum.reverse([before | acc])), ""}
        end
    end
  end

  defp comment(s, depth, acc) do
    case :binary.match(s, ["(", ")", "\\"]) do
      :nomatch ->
        {IO.iodata_to_binary(Enum.reverse([s | acc])), ""}

      {p, 1} ->
        before = binary_part(s, 0, p)

        case binary_part(s, p, byte_size(s) - p) do
          <<?\\, c, rest::binary>> ->
            comment(rest, depth, [<<c>>, before | acc])

          <<?(, rest::binary>> ->
            comment(rest, depth + 1, ["(", before | acc])

          <<?), rest::binary>> when depth == 1 ->
            {IO.iodata_to_binary(Enum.reverse([before | acc])), rest}

          <<?), rest::binary>> ->
            comment(rest, depth - 1, [")", before | acc])

          _ ->
            {IO.iodata_to_binary(Enum.reverse([before | acc])), ""}
        end
    end
  end

  # Entries split at commas and semicolons; a colon outside an angle-addr
  # opens a group, whose display name is dropped.
  defp entries([], cur, _angle, acc), do: Enum.reverse([Enum.reverse(cur) | acc])

  defp entries([t | rest], cur, _angle, acc) when t in [:comma, :semi],
    do: entries(rest, [], false, [Enum.reverse(cur) | acc])

  defp entries([:colon | rest], cur, true, acc), do: entries(rest, cur, true, acc)
  defp entries([:colon | rest], _cur, false, acc), do: entries(rest, [], false, acc)
  defp entries([{:a, _} = t | rest], cur, _angle, acc), do: entries(rest, [t | cur], true, acc)
  defp entries([t | rest], cur, angle, acc), do: entries(rest, [t | cur], angle, acc)

  defp mailbox(tokens) do
    case Enum.split_while(tokens, &(not match?({:a, _}, &1))) do
      {phrase, [{:a, inner} | _]} ->
        phrase =
          Enum.map_join(phrase, fn
            {:w, w} -> w
            {:q, q} -> q
            _ -> " "
          end)

        named(name(phrase) || name(first_comment(tokens)), route(inner))

      {_, []} ->
        bare(tokens)
    end
  end

  # An addr-spec without angle brackets: the first run of words holding an
  # "@", glued across obsolete spaces around "." and "@"; a comment or the
  # words before it name it.
  defp bare(tokens) do
    chunks =
      tokens
      |> Enum.chunk_by(&(&1 == :sp or match?({:c, _}, &1)))
      |> Enum.reject(fn [t | _] -> t == :sp or match?({:c, _}, t) end)
      |> Enum.map(fn chunk ->
        Enum.map_join(chunk, fn
          {:w, w} -> w
          {:q, q} -> "\"" <> q <> "\""
          _ -> ""
        end)
      end)
      |> glue()

    case Enum.split_while(chunks, &(not String.contains?(&1, "@"))) do
      {before, [addr | _]} ->
        named(name(first_comment(tokens)) || name(Enum.join(before, " ")), addr)

      {_, []} ->
        []
    end
  end

  defp glue([a, b | rest]) do
    if String.ends_with?(a, ["@", "."]) or String.starts_with?(b, ["@", "."]),
      do: glue([a <> b | rest]),
      else: [a | glue([b | rest])]
  end

  defp glue(chunks), do: chunks

  defp first_comment(tokens) do
    Enum.find_value(tokens, "", fn
      {:c, c} -> c
      _ -> nil
    end)
  end

  defp route(inner) do
    inner = strip_wsp(inner)

    case String.starts_with?(inner, "@") and :binary.matches(inner, ":") do
      [_ | _] = colons ->
        {p, _} = List.last(colons)
        binary_part(inner, p + 1, byte_size(inner) - p - 1)

      _ ->
        inner
    end
  end

  defp named(name, addr) do
    addr = addr |> strip_wsp() |> String.downcase()

    case :binary.matches(addr, "@") do
      [] ->
        []

      at ->
        {p, _} = List.last(at)
        if p > 0 and p < byte_size(addr) - 1, do: [%{name: name, addr: addr}], else: []
    end
  end

  defp name(text) do
    case text |> words() |> line() |> String.split() do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end

  defp strip_wsp(s), do: for(<<c <- s>>, c not in @wsp, into: "", do: <<c>>)

  ## Dates (RFC 5322 and its obsolete forms)

  defp date(""), do: nil

  defp date(v) do
    d =
      v
      |> uncomment()
      |> ascii_downcase()
      |> String.split([" ", "\t", "\r", "\n", ","], trim: true)
      |> Enum.reduce(%{nums: [], month: nil, time: nil, zone: nil}, &date_part/2)

    with {:ok, year, day} <- year_day(Enum.reverse(d.nums)),
         month when month != nil <- d.month,
         {h, mi, s} <- d.time,
         true <- :calendar.valid_date(year, month, day) do
      days = :calendar.date_to_gregorian_days(year, month, day) - @epoch_days
      days * 86_400 + h * 3600 + mi * 60 + s - (d.zone || 0) * 60
    else
      _ -> nil
    end
  end

  defp date_part(tok, d) do
    month = Map.get(@months, binary_part(tok, 0, min(3, byte_size(tok))))

    cond do
      d.month == nil and month != nil and letters?(String.trim_trailing(tok, ".")) ->
        %{d | month: month}

      d.zone == nil and zone(tok) != nil ->
        %{d | zone: zone(tok)}

      d.time == nil and String.contains?(tok, ":") ->
        %{d | time: time(tok)}

      digits?(tok, 4) ->
        %{d | nums: [tok | d.nums]}

      true ->
        d
    end
  end

  defp year_day(nums) do
    case Enum.split_with(nums, &(byte_size(&1) >= 3)) do
      {[y | _], [d | _]} -> {:ok, year(y), String.to_integer(d)}
      {[], [d, y | _]} -> {:ok, year(y), String.to_integer(d)}
      _ -> :error
    end
  end

  # Two-digit years below 50 are 20xx, others 19xx, as are three-digit ones
  # (RFC 5322 obs-year).
  defp year(y) do
    n = String.to_integer(y)

    case byte_size(y) do
      4 -> n
      3 -> n + 1900
      _ when n < 50 -> n + 2000
      _ -> n + 1900
    end
  end

  defp time(tok) do
    with [_, _ | _] = parts when length(parts) <= 3 <- String.split(tok, ":"),
         true <- Enum.all?(parts, &digits?(&1, 2)),
         [h, mi, s] <-
           Enum.map(parts, &String.to_integer/1) ++ List.duplicate(0, 3 - length(parts)),
         true <- h <= 23 and mi <= 59 and s <= 60 do
      {h, mi, s}
    else
      _ -> nil
    end
  end

  defp zone(<<sign, rest::binary>>) when sign in [?+, ?-] do
    with <<h::binary-size(2), m::binary-size(2)>> <- String.replace(rest, ":", ""),
         true <- digits?(h, 2) and digits?(m, 2),
         minutes when minutes < 60 <- String.to_integer(m) do
      if(sign == ?-, do: -1, else: 1) * (String.to_integer(h) * 60 + minutes)
    else
      _ -> nil
    end
  end

  # Military zones read as -0000, as RFC 5322 says: RFC 822 gave their signs
  # backwards. An unknown alphabetic zone also reads as no offset.
  defp zone(<<c>>) when c in ?a..?z and c != ?j, do: 0
  defp zone(tok), do: Map.get(@zones, tok)

  defp letters?(<<c, rest::binary>>) when c in ?a..?z, do: letters?(rest)
  defp letters?(rest), do: rest == ""

  defp digits?(s, max), do: s != "" and byte_size(s) <= max and digits?(s)
  defp digits?(<<c, rest::binary>>) when c in ?0..?9, do: digits?(rest)
  defp digits?(rest), do: rest == ""

  ## RFC 2047 encoded words

  # `s` with its encoded words decoded: whitespace between two of them is
  # dropped, adjacent ones in one charset decode as one (a character split
  # across two survives), and a malformed one stays as it is.
  defp words(s) do
    case :binary.match(s, "=?") do
      :nomatch -> s
      _ -> s |> ew(0, 0, []) |> merge() |> Enum.map_join(&render/1)
    end
  end

  defp ew(s, lit, from, acc) do
    size = byte_size(s)

    case :binary.match(s, "=?", scope: {from, size - from}) do
      :nomatch ->
        Enum.reverse([{:lit, binary_part(s, lit, size - lit)} | acc])

      {p, 2} ->
        case encoded(s, p + 2) do
          {:ok, cs, e, text, next} ->
            word = {:word, charset(cs), unword(e, text)}
            ew(s, next, next, [word, {:lit, binary_part(s, lit, p - lit)} | acc])

          :error ->
            ew(s, lit, p + 1, acc)
        end
    end
  end

  # The parts of an encoded word whose "=?" ends at `at`. Each scan stops at
  # the next "?", so a run of failed candidates stays linear.
  defp encoded(s, at) do
    size = byte_size(s)

    with {q, 1} <- :binary.match(s, "?", scope: {at, size - at}),
         cs = binary_part(s, at, q - at),
         true <- cs != "" and byte_size(cs) <= 64 and token?(cs),
         <<e, ??, _::binary>> when e in ~c"BbQq" <- binary_part(s, q + 1, size - q - 1),
         {t, 1} <- :binary.match(s, "?", scope: {q + 3, size - q - 3}),
         <<"?=", _::binary>> <- binary_part(s, t, size - t),
         text = binary_part(s, q + 3, t - q - 3),
         :nomatch <- :binary.match(text, [" ", "\t", "\r", "\n"]) do
      {:ok, cs, e, text, t + 2}
    else
      _ -> :error
    end
  end

  defp token?(<<c, rest::binary>>) when c in 0x21..0x7E and c not in ~c"()<>,;\"=",
    do: token?(rest)

  defp token?(rest), do: rest == ""

  defp unword(e, text) when e in ~c"Bb", do: b64(text)
  defp unword(_, text), do: text |> :binary.replace("_", " ", [:global]) |> qp(<<>>)

  defp merge([{:word, cs, a}, {:lit, l}, {:word, cs2, b} | rest]) do
    if blank?(l),
      do: merge([{:word, cs, a}, {:word, cs2, b} | rest]),
      else: [{:word, cs, a}, {:lit, l} | merge([{:word, cs2, b} | rest])]
  end

  defp merge([{:word, cs, a}, {:word, cs, b} | rest]), do: merge([{:word, cs, a <> b} | rest])
  defp merge([t | rest]), do: [t | merge(rest)]
  defp merge([]), do: []

  defp render({:lit, l}), do: l
  defp render({:word, cs, bytes}), do: decode(bytes, cs)

  defp blank?(<<c, rest::binary>>) when c in @wsp, do: blank?(rest)
  defp blank?(rest), do: rest == ""

  ## Parameters (RFC 2045, with RFC 2231 sections)

  # {main value lowercased, [{name, section | nil, extended?, value}]}
  defp params(nil), do: {"", [], false}

  defp params(v) do
    {[main | rest], cut} = cuts(v, ?;, @params + 1)
    main = main |> uncomment() |> String.split() |> List.first("") |> ascii_downcase()
    {main, Enum.flat_map(rest, &param/1), cut}
  end

  defp param(segment) do
    with [name, value] <- :binary.split(segment, "="),
         name when name != "" <- name |> String.trim() |> ascii_downcase() do
      [section(name, unquote_value(value))]
    else
      _ -> []
    end
  end

  defp unquote_value(v) do
    case String.trim_leading(v) do
      <<?", rest::binary>> -> rest |> quoted([]) |> elem(0)
      v -> v |> uncomment() |> String.trim()
    end
  end

  defp section(name, value) do
    {name, ext} =
      if String.ends_with?(name, "*"),
        do: {binary_part(name, 0, byte_size(name) - 1), true},
        else: {name, false}

    case :binary.split(name, "*") do
      [base, i] ->
        if digits?(i, 3),
          do: {base, String.to_integer(i), ext, value},
          else: {name, nil, ext, value}

      [base] ->
        {base, nil, ext, value}
    end
  end

  # A parameter's value: {:plain, as written} or {:ext, its RFC 2231
  # sections joined and decoded}; nil when absent.
  defp get(params, name) do
    case for({^name, i, e, v} <- params, i != nil or e, do: {i, e, v}) do
      [] ->
        case for({^name, nil, false, v} <- params, do: v) do
          [v | _] -> {:plain, v}
          [] -> nil
        end

      sections ->
        {:ext, rfc2231(sections)}
    end
  end

  defp param_value(params, name) do
    case get(params, name) do
      {_, v} -> v
      nil -> nil
    end
  end

  # A name as shown: plain values often carry encoded words, against RFC 2047.
  defp display(params, name) do
    case get(params, name) do
      {:plain, v} -> words(v)
      {:ext, v} -> v
      nil -> nil
    end
  end

  defp rfc2231(sections) do
    {cs, bytes} =
      sections
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.sort_by(&(elem(&1, 0) || 0))
      |> Enum.reduce({nil, []}, fn
        {i, true, v}, {nil, []} when i in [nil, 0] ->
          case :binary.split(v, "'", [:global]) do
            [cs, _lang | rest] -> {charset(cs), [pct(Enum.join(rest, "'"))]}
            _ -> {nil, [pct(v)]}
          end

        {_, true, v}, {cs, acc} ->
          {cs, [pct(v) | acc]}

        {_, false, v}, {cs, acc} ->
          {cs, [v | acc]}
      end)

    bytes |> Enum.reverse() |> IO.iodata_to_binary() |> decode(cs || :ascii)
  end

  defp pct(v) do
    [first | rest] = :binary.split(v, "%", [:global])
    IO.iodata_to_binary([first | Enum.map(rest, &pct_piece/1)])
  end

  defp pct_piece(<<a, b, rest::binary>>) when hex?(a) and hex?(b),
    do: [<<hex(a) * 16 + hex(b)>>, rest]

  defp pct_piece(piece), do: ["%", piece]

  defp hex(c) when c in ?0..?9, do: c - ?0
  defp hex(c) when c in ?A..?F, do: c - ?A + 10
  defp hex(c), do: c - ?a + 10

  # `s` split on `sep` outside quoted strings and comments, into at most
  # `max` pieces: {pieces, cut}.
  defp cuts(s, sep, max), do: cuts(s, sep, {0, 0, 0}, [], max - 1)

  defp cuts(s, _sep, {i, from, _depth}, acc, _left) when i >= byte_size(s),
    do: {Enum.reverse([binary_part(s, from, byte_size(s) - from) | acc]), false}

  # depth: 0 outside, -1 in a quoted string, n > 0 in n nested comments.
  defp cuts(s, sep, {i, from, depth}, acc, left) do
    case :binary.at(s, i) do
      ?\\ when depth != 0 ->
        cuts(s, sep, {i + 2, from, depth}, acc, left)

      ?" when depth == 0 ->
        cuts(s, sep, {i + 1, from, -1}, acc, left)

      ?" when depth == -1 ->
        cuts(s, sep, {i + 1, from, 0}, acc, left)

      ?( when depth >= 0 ->
        cuts(s, sep, {i + 1, from, depth + 1}, acc, left)

      ?) when depth > 0 ->
        cuts(s, sep, {i + 1, from, depth - 1}, acc, left)

      ^sep when depth == 0 and left == 0 ->
        {Enum.reverse([binary_part(s, from, i - from) | acc]), true}

      ^sep when depth == 0 ->
        cuts(s, sep, {i + 1, i + 1, 0}, [binary_part(s, from, i - from) | acc], left - 1)

      _ ->
        cuts(s, sep, {i + 1, from, depth}, acc, left)
    end
  end

  # `s` without its comments; quoted strings are kept as written.
  defp uncomment(s) do
    if :binary.match(s, "(") == :nomatch, do: s, else: uncomment(s, [])
  end

  defp uncomment(s, acc) do
    case :binary.match(s, ["(", "\""]) do
      :nomatch ->
        IO.iodata_to_binary(Enum.reverse([s | acc]))

      {p, 1} ->
        before = binary_part(s, 0, p)
        rest = binary_part(s, p + 1, byte_size(s) - p - 1)

        if :binary.at(s, p) == ?( do
          {_, rest} = comment(rest, 1, [])
          uncomment(rest, [" ", before | acc])
        else
          n = quoted_len(rest, 0)

          uncomment(binary_part(rest, n, byte_size(rest) - n), [
            binary_part(rest, 0, n),
            "\"",
            before | acc
          ])
        end
    end
  end

  defp quoted_len(s, from) do
    case :binary.match(s, ["\"", "\\"], scope: {from, byte_size(s) - from}) do
      :nomatch ->
        byte_size(s)

      {p, 1} ->
        if :binary.at(s, p) == ?\\, do: quoted_len(s, min(p + 2, byte_size(s))), else: p + 1
    end
  end

  defp token(nil), do: nil

  defp token(v) do
    case v |> uncomment() |> String.split() do
      [t | _] -> ascii_downcase(t)
      [] -> nil
    end
  end

  ## The body

  defp body(fields, body) do
    st = %{parts: 0, cut: false, files: [], report: nil, budget: @text_in, size: 0}
    {texts, st} = walk(fields, body, 0, "text/plain", st)
    {text, cut} = texts |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n") |> bounded(@text)
    {{text, Enum.reverse(st.files), st.report}, st.cut or cut}
  end

  # One entity: its texts in order; its attachments and report go to `st`.
  defp walk(fields, body, depth, default, st) do
    c = content(fields, default)
    st = %{st | cut: st.cut or c.cut}

    cond do
      not String.starts_with?(c.type, "multipart/") ->
        if attachment?(c), do: {[], file(c, body, st)}, else: text(c, body, st)

      depth >= @depth ->
        {[], %{st | cut: true}}

      true ->
        multipart(c, body, depth, st)
    end
  end

  defp content(fields, default) do
    {type, c1} = value(fields, "content-type", @field)
    {disposition, c2} = value(fields, "content-disposition", @field)
    {cte, c3} = value(fields, "content-transfer-encoding", @field)
    {type, params, c4} = params(type)
    {disposition, dparams, c5} = params(disposition)

    %{
      type: if(type?(type), do: type, else: default),
      params: params,
      disposition: disposition,
      dparams: dparams,
      cte: token(cte),
      cut: c1 or c2 or c3 or c4 or c5
    }
  end

  defp type?(type) do
    case :binary.split(type, "/", [:global]) do
      [a, b] -> a != "" and b != ""
      _ -> false
    end
  end

  defp attachment?(c) do
    c.disposition == "attachment" or c.type not in ["text/plain", "text/html"] or
      List.keymember?(c.dparams, "filename", 0) or List.keymember?(c.params, "name", 0)
  end

  defp file(c, body, st) do
    name =
      case display(c.dparams, "filename") || display(c.params, "name") do
        nil -> nil
        v -> v |> line() |> String.trim() |> clip(@field)
      end

    size = if c.cte == "base64", do: b64_size(body), else: byte_size(body)
    %{st | files: [%{name: if(name != "", do: name), type: c.type, size: size} | st.files]}
  end

  # Past the text kept, a text part is not read.
  defp text(_c, body, %{size: size} = st) when size > @text,
    do: {[], %{st | cut: st.cut or body != ""}}

  defp text(c, body, st) do
    raw = binary_part(body, 0, min(byte_size(body), st.budget))
    text = raw |> transfer(c.cte) |> decode(charset(param_value(c.params, "charset")))
    text = if c.type == "text/html", do: html(text), else: plain(text)
    cut = st.cut or byte_size(raw) < byte_size(body)

    {[text],
     %{st | budget: st.budget - byte_size(raw), cut: cut, size: st.size + byte_size(text) + 2}}
  end

  defp multipart(c, body, depth, st) do
    case boundary(c.params) do
      nil ->
        text(%{c | type: "text/plain"}, body, st)

      b ->
        {raw, cut} = parts(body, b, @parts - st.parts)

        {children, cuts} =
          raw
          |> Enum.map(fn part ->
            {head, body} = split(part)
            {fields, cut} = fields(head)
            {{fields, body}, cut}
          end)
          |> Enum.unzip()

        st = %{st | parts: st.parts + length(children), cut: st.cut or cut or Enum.any?(cuts)}
        default = if c.type == "multipart/digest", do: "message/rfc822", else: "text/plain"

        case c.type do
          "multipart/alternative" -> alternative(children, depth + 1, default, st)
          "multipart/report" -> report(children, depth + 1, default, st)
          _ -> mixed(children, depth + 1, default, st)
        end
    end
  end

  defp boundary(params) do
    case param_value(params, "boundary") do
      b when is_binary(b) and b != "" and byte_size(b) <= 200 ->
        if :binary.match(b, ["\r", "\n"]) == :nomatch, do: b

      _ ->
        nil
    end
  end

  defp mixed(children, depth, default, st) do
    {texts, st} =
      Enum.map_reduce(children, st, fn {f, b}, st -> walk(f, b, depth, default, st) end)

    {Enum.concat(texts), st}
  end

  # The first non-empty plain text, else the first alternative with any.
  # Each alternative is read as if it stood alone.
  defp alternative(children, depth, default, st) do
    size = st.size

    {walked, st} =
      Enum.map_reduce(children, st, fn {f, b}, st ->
        c = content(f, default)
        {texts, st} = walk(f, b, depth, default, %{st | size: size})
        {{c.type == "text/plain" and not attachment?(c), Enum.reject(texts, &(&1 == ""))}, st}
      end)

    chosen =
      Enum.find_value(walked, fn {plain, texts} -> plain and texts != [] and texts end) ||
        Enum.find_value(walked, [], fn {_, texts} -> texts != [] and texts end)

    {chosen, %{st | size: size + Enum.sum_by(chosen, &(byte_size(&1) + 2))}}
  end

  defp report(children, depth, default, st) do
    typed = for {f, b} <- children, do: {content(f, default), f, b}

    if st.report == nil and Enum.any?(typed, fn {c, _, _} -> c.type in @status end) do
      {texts, {st, status, original}} =
        Enum.map_reduce(typed, {st, nil, nil}, fn
          {%{type: t} = c, _, b}, {st, nil, o} when t in @status ->
            {[], {st, dsn(c, b), o}}

          {%{type: t} = c, _, b}, {st, s, nil} when t in @original ->
            {[], {st, s, original(c, b)}}

          {_, f, b}, {st, s, o} ->
            {texts, st} = walk(f, b, depth, default, st)
            {texts, {st, s, o}}
        end)

      report = Map.merge(status, %{kind: kind(status.action), original_message_id: original})
      {Enum.concat(texts), %{st | report: report}}
    else
      mixed(children, depth, default, st)
    end
  end

  # The fields of the first per-recipient block of a delivery status.
  defp dsn(c, body) do
    text =
      body
      |> binary_part(0, min(byte_size(body), @raw))
      |> transfer(c.cte)
      |> utf8()
      |> :binary.replace("\r\n", "\n", [:global])

    blocks = for block <- :binary.split(text, "\n\n", [:global]), do: elem(fields(block), 0)

    block =
      Enum.find(blocks, &List.keymember?(&1, "action", 0)) ||
        Enum.find(blocks, [], fn b ->
          List.keymember?(b, "final-recipient", 0) or List.keymember?(b, "status", 0)
        end)

    read = fn name -> block |> value(name, @field) |> elem(0) end

    %{
      action: token(read.("action")),
      status: status(read.("status")),
      diagnostic: name(typed_value(read.("diagnostic-code"))),
      recipient: recipient(read.("final-recipient") || read.("original-recipient"))
    }
  end

  defp original(c, body) do
    {head, _} = body |> binary_part(0, min(byte_size(body), @raw)) |> transfer(c.cte) |> split()
    {fields, _} = fields(head)
    {id, _} = value(fields, "message-id", @field)
    msg_id(id)
  end

  defp kind("failed"), do: :bounce
  defp kind("delayed"), do: :delay
  defp kind(action) when action in ["delivered", "relayed", "expanded"], do: :delivered
  defp kind(_), do: :other

  defp status(nil), do: nil

  defp status(v) do
    v
    |> String.split([" ", "\t", "(", ")", ";", ","], trim: true)
    |> Enum.find(fn t ->
      case :binary.split(t, ".", [:global]) do
        [class, a, b] -> class in ["2", "4", "5"] and digits?(a, 3) and digits?(b, 3)
        _ -> false
      end
    end)
  end

  # "rfc822; user@example.com" without its type.
  defp typed_value(nil), do: ""

  defp typed_value(v) do
    case :binary.split(v, ";") do
      [_, rest] -> rest
      [v] -> v
    end
  end

  defp recipient(v) do
    case v
         |> typed_value()
         |> strip_wsp()
         |> String.trim_leading("<")
         |> String.trim_trailing(">") do
      "" -> nil
      r -> String.downcase(r)
    end
  end

  # The parts of a multipart, between "--boundary" lines: at most `limit`,
  # {parts, cut}. The preamble and epilogue are dropped; a missing close
  # delimiter ends the last part at the end of the body. Only a delimiter
  # followed by "--", padding or a line end is searched for, so lines that
  # merely start with the boundary cost nothing.
  defp parts(body, boundary, limit) do
    dash = "--" <> boundary
    nl = "\n" <> dash

    find =
      {:binary.compile_pattern(for end_ <- ["--", " ", "\t", "\r", "\n"], do: nl <> end_),
       byte_size(nl)}

    start =
      with true <- String.starts_with?(body, dash),
           {:open, content} <- delimiter(body, byte_size(dash)) do
        {:open, 0, content}
      else
        _ -> next_delimiter(body, find, 0)
      end

    case start do
      {:open, _, content} -> collect(body, find, content, limit, [])
      _ -> {[], false}
    end
  end

  defp collect(_body, _find, _content, 0, acc), do: {Enum.reverse(acc), true}

  defp collect(body, find, content, left, acc) do
    case next_delimiter(body, find, max(content - 1, 0)) do
      nil ->
        {Enum.reverse([slice(body, content, byte_size(body)) | acc]), false}

      {kind, p, next} ->
        stop = if p > content and :binary.at(body, p - 1) == ?\r, do: p - 1, else: p
        acc = [slice(body, content, stop) | acc]

        if kind == :close,
          do: {Enum.reverse(acc), false},
          else: collect(body, find, next, left - 1, acc)
    end
  end

  # The next delimiter line at or after `from`: {:open | :close, its newline,
  # where the next part starts}.
  defp next_delimiter(body, {pattern, n} = find, from) do
    size = byte_size(body)

    case :binary.match(body, pattern, scope: {from, size - from}) do
      {p, _} ->
        case delimiter(body, p + n) do
          :close -> {:close, p, size}
          {:open, content} -> {:open, p, content}
          :none -> next_delimiter(body, find, p + 1)
        end

      :nomatch ->
        nil
    end
  end

  # What follows "--boundary": "--" closes; transport padding (up to 256
  # blanks) then a line end, or the body's end, opens a part; anything else
  # means the line was no delimiter.
  defp delimiter(body, at) do
    case binary_part(body, at, min(258, byte_size(body) - at)) do
      <<"--", _::binary>> -> :close
      window -> padded(window, at, at + byte_size(window) == byte_size(body))
    end
  end

  defp padded(<<c, rest::binary>>, at, ends) when c in [?\s, ?\t], do: padded(rest, at + 1, ends)
  defp padded(<<"\r\n", _::binary>>, at, _ends), do: {:open, at + 2}
  defp padded(<<"\n", _::binary>>, at, _ends), do: {:open, at + 1}
  defp padded("\r", at, true), do: {:open, at + 1}
  defp padded("", at, true), do: {:open, at}
  defp padded(_window, _at, _ends), do: :none

  defp slice(body, from, to), do: binary_part(body, from, max(to - from, 0))

  ## Transfer encodings

  defp transfer(data, "base64"), do: b64(data)
  defp transfer(data, "quoted-printable"), do: qp(data, <<>>)
  defp transfer(data, _), do: data

  # Lenient: whitespace and stray characters skipped, padding optional, and
  # padded chunks that were concatenated decoded one by one.
  defp b64(data) do
    stripped = :binary.replace(data, [" ", "\t", "\r", "\n"], "", [:global])

    case Base.decode64(stripped, padding: false) do
      {:ok, bin} -> bin
      :error -> sextets(stripped, 0, 0, <<>>)
    end
  end

  # Six bits a character into whole bytes; "=" ends a quantum.
  defp sextets(<<c, rest::binary>>, acc, bits, out) do
    case elem(@b64, c) do
      nil ->
        sextets(rest, acc, bits, out)

      :pad ->
        sextets(rest, 0, 0, out)

      v when bits >= 2 ->
        acc = acc <<< 6 ||| v
        left = bits - 2
        byte = acc >>> left
        sextets(rest, acc &&& (1 <<< left) - 1, left, <<out::binary, byte>>)

      v ->
        sextets(rest, acc <<< 6 ||| v, bits + 6, out)
    end
  end

  defp sextets(<<>>, _acc, _bits, out), do: out

  # A base64 attachment's decoded size, from its encoded length alone.
  defp b64_size(body) do
    size = byte_size(body)
    n = size - whitespace(body, 0, 0)
    max(div(n * 3, 4) - padding(body, size - 1, max(size - 4096, 0), 0), 0)
  end

  defp whitespace(body, at, count) when at >= byte_size(body), do: count

  defp whitespace(body, at, count) do
    len = min(1024 * 1024, byte_size(body) - at)
    found = length(:binary.matches(body, [" ", "\t", "\r", "\n"], scope: {at, len}))
    whitespace(body, at + len, count + found)
  end

  defp padding(_body, i, floor, pad) when i < floor or pad == 2, do: pad

  defp padding(body, i, floor, pad) do
    case :binary.at(body, i) do
      c when c in @wsp -> padding(body, i - 1, floor, pad)
      ?= -> padding(body, i - 1, floor, pad + 1)
      _ -> pad
    end
  end

  # Soft line breaks (trailing blanks tolerated) and =XX; a bad sequence
  # stays as it is.
  defp qp(<<?=, a, b, rest::binary>>, acc) when hex?(a) and hex?(b),
    do: qp(rest, <<acc::binary, hex(a) * 16 + hex(b)>>)

  defp qp(<<?=, rest::binary>>, acc) do
    case trim_blanks(rest) do
      <<"\r\n", rest::binary>> -> qp(rest, acc)
      <<"\n", rest::binary>> -> qp(rest, acc)
      _ -> qp(rest, <<acc::binary, ?=>>)
    end
  end

  defp qp(<<c, rest::binary>>, acc), do: qp(rest, <<acc::binary, c>>)
  defp qp(<<>>, acc), do: acc

  defp trim_blanks(<<c, rest::binary>>) when c in [?\s, ?\t], do: trim_blanks(rest)
  defp trim_blanks(rest), do: rest

  ## Charsets

  defp charset(nil), do: :ascii

  defp charset(name) do
    key = name |> :binary.split("*") |> hd() |> String.trim() |> ascii_downcase()
    Map.get(@charsets, key, :unknown)
  end

  # Bytes in a charset as valid UTF-8.
  defp decode(b, :utf8), do: String.replace_invalid(b, @bad)
  defp decode(b, :ascii), do: utf8(b)
  defp decode(b, :cp1252), do: for(<<c <- b>>, into: "", do: elem(@cp1252_bytes, c))
  defp decode(b, :latin9), do: for(<<c <- b>>, into: "", do: elem(@latin9_bytes, c))
  defp decode(b, :utf16), do: utf16(b, nil)
  defp decode(b, :utf16le), do: utf16(b, :little)
  defp decode(b, :utf16be), do: utf16(b, :big)

  defp decode(b, :unknown) do
    if String.valid?(b),
      do: b,
      else: for(<<c <- b>>, into: "", do: if(c < 0x80, do: <<c>>, else: @bad))
  end

  # Header text as RFC 6532 has it: UTF-8 when it is, else windows-1252.
  defp utf8(b), do: if(String.valid?(b), do: b, else: decode(b, :cp1252))

  # UTF-16 without a byte order mark is big-endian (RFC 2781); an unpaired
  # surrogate or an odd last byte becomes U+FFFD.
  defp utf16(<<0xFE, 0xFF, rest::binary>>, e) when e in [nil, :big], do: utf16(rest, :big, [])

  defp utf16(<<0xFF, 0xFE, rest::binary>>, e) when e in [nil, :little],
    do: utf16(rest, :little, [])

  defp utf16(b, e), do: utf16(b, e || :big, [])

  defp utf16(b, e, acc) do
    case :unicode.characters_to_binary(b, {:utf16, e}) do
      s when is_binary(s) -> IO.iodata_to_binary([acc, s])
      {:error, s, <<_, _, rest::binary>>} -> utf16(rest, e, [acc, s, @bad])
      {_, s, _} -> IO.iodata_to_binary([acc, s, @bad])
    end
  end

  ## HTML to text: one forward scan, jumping between "<" and "&"

  defp html(s) do
    # The patterns ride apart from the state, which is copied on each change.
    pat = %{
      find: :binary.compile_pattern(["<", "&"]),
      quote: :binary.compile_pattern([">", "\"", "'"]),
      gt: :binary.compile_pattern(">"),
      close: :binary.compile_pattern("</"),
      lines: :binary.compile_pattern(["\r\n", "\r", "\n"]),
      blank: :binary.compile_pattern(Enum.uniq([" ", "\t", "\r", "\n", "\f", @nbsp | @controls]))
    }

    st = html(s, 0, 0, %{out: "", gap: 0, a: nil, drop: nil, pre: 0, pat: pat})
    close_a(st).out
  end

  # Text pending from `run`: a "<" or "&" that opens nothing stays in it.
  # Past the text kept, the rest is not read.
  defp html(_s, _run, _from, %{out: out} = st) when byte_size(out) > @text, do: st

  defp html(s, run, from, st) do
    size = byte_size(s)

    case :binary.match(s, st.pat.find, scope: {from, size - from}) do
      :nomatch ->
        flush(st, s, run, size)

      {p, 1} ->
        case binary_part(s, p, min(2, size - p)) do
          <<?&, c>> when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?# ->
            case entity(s, p + 1) do
              {text, next} -> html(s, next, next, put(flush(st, s, run, p), text))
              nil -> html(s, run, p + 1, st)
            end

          <<?<, c>> when c in ?a..?z or c in ?A..?Z or c in ~c"/!?" ->
            {next, st} = tag(s, p + 1, flush(st, s, run, p))
            html(s, next, next, st)

          _ ->
            html(s, run, p + 1, st)
        end
    end
  end

  defp flush(st, s, run, p) when p > run, do: put(st, binary_part(s, run, p - run))
  defp flush(st, _s, _run, _p), do: st

  # Text into the output as it reads: blanks (control characters too) as one
  # space, markup breaks as at most one empty line, nothing leading or
  # trailing. Source line breaks count only inside <pre>.
  defp put(%{drop: nil, pre: 0} = st, text), do: put_words(st, text)

  defp put(%{drop: nil} = st, text) do
    [first | rest] = :binary.split(text, st.pat.lines, [:global])
    Enum.reduce(rest, put_words(st, first), fn line, st -> st |> gap(:br) |> put_words(line) end)
  end

  defp put(st, _text), do: st

  defp put_words(st, text) do
    case :binary.split(text, st.pat.blank, [:global, :trim_all]) do
      [] ->
        if text == "", do: st, else: space(st)

      words ->
        st = if lead_blank?(text), do: space(st), else: st
        st = append(st, Enum.join(words, " "))
        if trail_blank?(text), do: space(st), else: st
    end
  end

  defp lead_blank?(<<c, _::binary>>) when c <= 0x20 or c == 0x7F, do: true
  defp lead_blank?(<<0xC2, c, _::binary>>) when c in 0x80..0xA0, do: true
  defp lead_blank?(_text), do: false

  defp trail_blank?(text) do
    case binary_part(text, max(byte_size(text) - 2, 0), min(2, byte_size(text))) do
      <<0xC2, c>> when c in 0x80..0xA0 -> true
      <<_, c>> when c <= 0x20 or c == 0x7F -> true
      <<c>> when c <= 0x20 or c == 0x7F -> true
      _ -> false
    end
  end

  defp space(st), do: %{st | gap: max(st.gap, 1)}

  # gap: 0 none, 1 a space, 2 a line break, 3 an empty line.
  defp gap(%{drop: nil, gap: gap} = st, kind) do
    case kind do
      :br -> %{st | gap: if(gap < 2, do: 2, else: 3)}
      :line -> %{st | gap: max(gap, 2)}
      :para -> %{st | gap: 3}
    end
  end

  defp gap(st, _kind), do: st

  defp append(%{out: ""} = st, text), do: %{st | out: text, gap: 0}

  defp append(st, text) do
    gap = elem({"", " ", "\n", "\n\n"}, st.gap)
    %{st | out: <<st.out::binary, gap::binary, text::binary>>, gap: 0}
  end

  # A character reference's text and where it ends, or nil.
  defp entity(s, at) do
    window = binary_part(s, at, min(33, byte_size(s) - at))
    n = ref_chars(window, 0)

    with <<name::binary-size(^n), ?;, _::binary>> when n > 0 <- window,
         text when is_binary(text) <- reference(name) do
      {text, at + n + 1}
    else
      _ -> nil
    end
  end

  defp ref_chars(<<c, rest::binary>>, n)
       when n < 32 and (c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?#),
       do: ref_chars(rest, n + 1)

  defp ref_chars(_window, n), do: n

  defp reference(<<?#, x, digits::binary>>) when x in [?x, ?X], do: numeric(digits, 16)
  defp reference(<<?#, digits::binary>>), do: numeric(digits, 10)
  defp reference(name), do: Map.get(@entities, name)

  defp numeric(digits, base) when byte_size(digits) in 1..8 do
    if radix?(digits, base), do: codepoint(:erlang.binary_to_integer(digits, base))
  end

  defp numeric(_digits, _base), do: nil

  defp radix?(<<c, rest::binary>>, 10) when c in ?0..?9, do: radix?(rest, 10)
  defp radix?(<<c, rest::binary>>, 16) when hex?(c), do: radix?(rest, 16)
  defp radix?(rest, _base), do: rest == ""

  # HTML reads references to 0x80-0x9F as windows-1252.
  defp codepoint(n) when n in 0x80..0x9F, do: elem(@cp1252_bytes, n)
  defp codepoint(n) when n == 0 or n in 0xD800..0xDFFF or n > 0x10FFFF, do: @bad
  defp codepoint(n), do: <<n::utf8>>

  defp tag(s, at, st) do
    case binary_part(s, at, min(8, byte_size(s) - at)) do
      <<"!--", _::binary>> -> {skip(s, at + 1, "-->"), st}
      "![CDATA[" -> {skip(s, at + 8, "]]>"), st}
      <<c, _::binary>> when c in [?!, ??] -> {skip(s, at + 1, st.pat.gt), st}
      <<?/, _::binary>> -> close_tag(s, at + 1, st)
      _ -> open_tag(s, at, st)
    end
  end

  defp open_tag(s, at, st) do
    {name, after_name} = tag_name(s, at)
    stop = tag_end(s, after_name, after_name, st.pat.quote)
    next = min(stop + 1, byte_size(s))
    void = stop < byte_size(s) and stop > after_name and :binary.at(s, stop - 1) == ?/

    case Map.get(@tags, name) do
      :raw when not void -> {raw_end(s, next, name, st), st}
      :head when st.drop == nil and not void -> {next, %{st | drop: :head}}
      :template when st.drop == nil and not void -> {next, %{st | drop: :template}}
      :body when st.drop == :head -> {next, %{st | drop: nil}}
      :a -> {next, open_a(st, href(binary_part(s, after_name, stop - after_name)))}
      :li -> {next, item(st)}
      :cell -> {next, space(st)}
      :pre -> {next, gap(%{st | pre: st.pre + 1}, :para)}
      kind when kind in [:br, :line, :para] -> {next, gap(st, kind)}
      _ -> {next, st}
    end
  end

  defp close_tag(s, at, st) do
    {name, after_name} = tag_name(s, at)
    next = skip(s, after_name, st.pat.gt)

    st =
      case Map.get(@tags, name) do
        :head when st.drop == :head -> %{st | drop: nil}
        :template when st.drop == :template -> %{st | drop: nil}
        :a -> close_a(st)
        :pre -> gap(%{st | pre: max(st.pre - 1, 0)}, :para)
        kind when kind in [:br, :line, :para] -> gap(st, kind)
        _ -> st
      end

    {next, st}
  end

  defp tag_name(s, at) do
    n = s |> binary_part(at, min(32, byte_size(s) - at)) |> name_chars(0)
    {ascii_downcase(binary_part(s, at, n)), at + n}
  end

  defp name_chars(<<c, rest::binary>>, n)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?-, ?:],
       do: name_chars(rest, n + 1)

  defp name_chars(_window, n), do: n

  # The ">" closing a start tag; a quote opens a value only right after "=".
  defp tag_end(s, at, floor, quote) do
    size = byte_size(s)

    case :binary.match(s, quote, scope: {at, size - at}) do
      :nomatch ->
        size

      {p, 1} ->
        q = :binary.at(s, p)

        cond do
          q == ?> ->
            p

          after_equals?(s, p - 1, floor) ->
            case :binary.match(s, <<q>>, scope: {p + 1, size - p - 1}) do
              {e, 1} -> tag_end(s, e + 1, floor, quote)
              :nomatch -> size
            end

          true ->
            tag_end(s, p + 1, floor, quote)
        end
    end
  end

  defp after_equals?(s, i, floor) when i >= floor do
    case :binary.at(s, i) do
      c when c in @wsp -> after_equals?(s, i - 1, floor)
      c -> c == ?=
    end
  end

  defp after_equals?(_s, _i, _floor), do: false

  # Script and style hold no markup: they end at their own end tag.
  defp raw_end(s, at, name, st) do
    size = byte_size(s)

    case :binary.match(s, st.pat.close, scope: {at, size - at}) do
      :nomatch ->
        size

      {p, 2} ->
        case tag_name(s, p + 2) do
          {^name, after_name} -> skip(s, after_name, st.pat.gt)
          _ -> raw_end(s, p + 2, name, st)
        end
    end
  end

  defp skip(s, from, pattern) do
    size = byte_size(s)
    from = min(from, size)

    case :binary.match(s, pattern, scope: {from, size - from}) do
      {p, n} -> p + n
      :nomatch -> size
    end
  end

  defp item(%{drop: nil} = st), do: st |> gap(:line) |> append("-") |> space()
  defp item(st), do: st

  defp open_a(%{drop: nil} = st, href) do
    st = close_a(st)
    %{st | a: {href, byte_size(st.out)}}
  end

  defp open_a(st, _href), do: st

  defp close_a(%{a: nil} = st), do: st

  defp close_a(%{a: {href, start}, out: out} = st) do
    st = %{st | a: nil}
    text = binary_part(out, start, byte_size(out) - start)
    if link?(href, text), do: st |> space() |> append("(" <> href <> ")"), else: st
  end

  # Whether a link's target is a web or mail address its text does not show.
  defp link?(nil, _text), do: false

  defp link?(href, text) do
    shown = text |> String.trim() |> ascii_downcase() |> String.trim_trailing("/")
    target = href |> ascii_downcase() |> String.trim_trailing("/")

    String.starts_with?(target, ["http://", "https://", "mailto:"]) and
      shown not in [target, String.replace_prefix(target, "mailto:", "")]
  end

  defp href(attrs) do
    case attr(attrs, "href") do
      nil ->
        nil

      v ->
        url =
          v |> unescape([]) |> :binary.replace(["\r", "\n", "\t"], "", [:global]) |> String.trim()

        if url != "" and byte_size(url) <= @href, do: url
    end
  end

  defp attr(<<c, rest::binary>>, want) when c in [?\s, ?\t, ?\r, ?\n, ?\f, ?/],
    do: attr(rest, want)

  defp attr(<<>>, _want), do: nil

  defp attr(<<c, rest::binary>>, want) do
    n = attr_name_len(rest, 0)
    name = <<c>> <> binary_part(rest, 0, n)
    {value, rest} = attr_value(trim_leading_wsp(binary_part(rest, n, byte_size(rest) - n)))
    if value != nil and ascii_downcase(name) == want, do: value, else: attr(rest, want)
  end

  defp attr_name_len(s, n) when n < byte_size(s) do
    if :binary.at(s, n) in [?\s, ?\t, ?\r, ?\n, ?\f, ?/, ?>, ?=],
      do: n,
      else: attr_name_len(s, n + 1)
  end

  defp attr_name_len(_s, n), do: n

  defp attr_value(<<?=, rest::binary>>) do
    case trim_leading_wsp(rest) do
      <<q, more::binary>> when q in [?", ?'] ->
        case :binary.split(more, <<q>>) do
          [v, rest] -> {v, rest}
          [v] -> {v, ""}
        end

      rest ->
        case :binary.match(rest, [" ", "\t", "\r", "\n", "\f", ">"]) do
          {p, 1} -> {binary_part(rest, 0, p), binary_part(rest, p, byte_size(rest) - p)}
          :nomatch -> {rest, ""}
        end
    end
  end

  defp attr_value(rest), do: {nil, rest}

  defp trim_leading_wsp(<<c, rest::binary>>) when c in [?\s, ?\t, ?\r, ?\n, ?\f],
    do: trim_leading_wsp(rest)

  defp trim_leading_wsp(rest), do: rest

  defp unescape(v, acc) do
    case :binary.split(v, "&") do
      [last] ->
        IO.iodata_to_binary(Enum.reverse([last | acc]))

      [before, rest] ->
        case entity(rest, 0) do
          {text, n} -> unescape(binary_part(rest, n, byte_size(rest) - n), [text, before | acc])
          nil -> unescape(rest, ["&", before | acc])
        end
    end
  end

  ## Text

  defp plain(s),
    do: s |> :binary.replace(["\r\n", "\r"], "\n", [:global]) |> clean() |> String.trim()

  # One line: line breaks and tabs as spaces, other controls gone.
  defp line(s), do: s |> :binary.replace(["\r\n", "\r", "\n", "\t"], " ", [:global]) |> clean()

  defp clean(s), do: if(controls?(s), do: :binary.replace(s, @controls, "", [:global]), else: s)

  defp controls?(<<c, _::binary>>) when c < 0x20 and c not in [?\t, ?\n], do: true
  defp controls?(<<0x7F, _::binary>>), do: true
  defp controls?(<<0xC2, c, _::binary>>) when c in 0x80..0x9F, do: true
  defp controls?(<<_, rest::binary>>), do: controls?(rest)
  defp controls?(<<>>), do: false

  defp bounded(s, max), do: {clip(s, max), byte_size(s) > max}

  # `s` cut to at most `n` bytes, backed off to a character boundary.
  defp clip(s, n) when byte_size(s) <= n, do: s
  defp clip(s, n), do: binary_part(s, 0, boundary(s, n, 3))

  defp boundary(s, n, tries) when n > 0 and tries > 0 do
    if (:binary.at(s, n) &&& 0xC0) == 0x80, do: boundary(s, n - 1, tries - 1), else: n
  end

  defp boundary(_s, n, _tries), do: n

  defp ascii_downcase(s) do
    if lower?(s),
      do: s,
      else: for(<<c <- s>>, into: "", do: <<if(c in ?A..?Z, do: c + 32, else: c)>>)
  end

  defp lower?(<<c, _::binary>>) when c in ?A..?Z, do: false
  defp lower?(<<_, rest::binary>>), do: lower?(rest)
  defp lower?(<<>>), do: true
end
