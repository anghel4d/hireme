defmodule Hireme.Gmail.MimeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias Hireme.Gmail.Mime

  @bad <<0xFFFD::utf8>>
  @kept ~w(content-type list-id list-unsubscribe auto-submitted precedence return-path x-autoreply
           x-auto-response-suppress x-failed-recipients)

  defp parse!(raw) do
    assert {:ok, mail} = Mime.parse(raw)
    mail
  end

  defp text(head, body), do: parse!(head <> "\r\n\r\n" <> body).text

  test "generated mail reads back field for field: encoded subjects and names, address lists, dates, bodies in three charsets and four encodings, alternatives, attachments, the key" do
    for i <- 1..300 do
      seed = {i, 1, 2}
      :rand.seed(:exsss, seed)
      {raw, want} = mail()
      got = parse!(raw)

      for {field, value} <- want,
          do:
            assert(
              got[field] == value,
              "seed #{inspect(seed)}, #{field}:\n#{String.replace_invalid(raw)}"
            )
    end
  end

  test "any bytes read to a well-formed answer and nothing raises: random bytes, broken mail, absurd nesting, 10,000 parts; the header alone (as IMAP envelopes are fetched) or cut anywhere after reads its fields" do
    log =
      capture_log(fn ->
        for i <- 1..200 do
          seed = {i, 3, 4}
          :rand.seed(:exsss, seed)
          {raw, want} = mail()
          for input <- mutants(raw), do: well_formed!(input, seed)

          {at, n} = :binary.match(raw, ["\n\n", "\n\r\n"])
          head = parse!(binary_part(raw, 0, at + 1))
          assert {head.text, head.attachments, head.truncated} == {"", [], false}, inspect(seed)

          cut =
            parse!(binary_part(raw, 0, at + n + :rand.uniform(byte_size(raw) - at - n + 1) - 1))

          for field <- ~w(message_id in_reply_to refs from to cc reply_to subject date headers)a,
              m <- [head, cut],
              do: assert(m[field] == want[field], "seed #{inspect(seed)}, #{field}")
        end

        well_formed!(nested(60), :nested)
        well_formed!(many(10_000), :many)
      end)

    refute log =~ "opaque"
  end

  test "address lists past what the builder writes: comments, a mailbox after a group, routes, an encoded comma, obsolete spacing; junk dropped, repeats once, the first of two senders" do
    for {value, want} <- [
          {"carl@example.net (Carl Example), Dana Example <dana@example.net> (Recruiting)",
           [{"Carl Example", "carl@example.net"}, {"Dana Example", "dana@example.net"}]},
          {"Hiring Team: a@example.com, B@example.org;, c@example.net",
           [{nil, "a@example.com"}, {nil, "b@example.org"}, {nil, "c@example.net"}]},
          {"<@relay.example.net,@hop.example.org:route@example.com>",
           [{nil, "route@example.com"}]},
          {"=?utf-8?Q?Doe,_Jane?= <jane@example.com>", [{"Doe, Jane", "jane@example.com"}]},
          {"john . doe @ example . com", [{nil, "john.doe@example.com"}]},
          {"no address, @example.com, user@, <>, ;", []},
          {"a@example.com, A@EXAMPLE.COM", [{nil, "a@example.com"}]}
        ] do
      assert Enum.map(parse!("To: #{value}\r\n\r\n").to, &{&1.name, &1.addr}) == want, value
    end

    m =
      parse!(
        "From: a@example.com, b@example.org\r\nTo: x@example.com\r\nTo: y@example.org\r\n\r\n"
      )

    assert m.from == %{name: nil, addr: "a@example.com"}
    assert Enum.map(m.to, & &1.addr) == ["x@example.com", "y@example.org"]
  end

  test "dates in the obsolete forms the builder does not write read as unix seconds, and none outside 1970..2200" do
    for {value, want} <- [
          {"Wed,21 Oct 2026 10:00:00 +0530", ~U[2026-10-21 04:30:00Z]},
          {"Wed, 21 Oct 2026 10:00:00 Q", ~U[2026-10-21 10:00:00Z]},
          {"(sent) Mon, 21 Oct 085 10:00:00 +0000", ~U[1985-10-21 10:00:00Z]},
          {"31 Feb 2026 10:00:00 +0000", nil},
          # Outside 1970..2200 is no date: DateTime.from_unix! would raise on 9999 (hopper's review, M2).
          {"Fri, 31 Dec 9999 23:59:59 -0100", nil},
          {"Wed, 31 Dec 1969 23:59:59 +0000", nil},
          {"Mon, 31 Dec 2200 23:59:59 +0000", ~U[2200-12-31 23:59:59Z]},
          {"Thu, 01 Jan 1970 00:30:00 +0100", nil},
          {"21 Oct 2026", nil},
          {"yesterday", nil}
        ] do
      assert parse!("Date: #{value}\r\n\r\n").date == (want && DateTime.to_unix(want)), value
    end
  end

  test "ids are canonical, References keep their first and newest within 8 KiB, encoded words decode, and the kept headers come back" do
    head = fn lines -> parse!(Enum.join(lines, "\r\n") <> "\r\n\r\n") end

    m =
      head.([
        "Message-ID:  <Abc.123@\r\n Mail.Example.COM> (ours)",
        "In-Reply-To: Your message of Wed <First@example.org> <second@example.org>",
        "References: <a@example.org>\r\n <b@example.org> <a@example.org> <c@example.org>"
      ])

    assert {m.message_id, m.key, m.in_reply_to, m.refs, m.truncated} ==
             {"Abc.123@Mail.Example.COM", "Abc.123@Mail.Example.COM", "First@example.org",
              ["a@example.org", "b@example.org", "c@example.org"], false}

    assert head.(["Message-ID: bare.id@example.com"]).message_id == "bare.id@example.com"
    assert head.(["Message-ID: <>"]).message_id == nil

    ids = for i <- 1..300, do: "ref#{i}.0123456789abcdef@mail.example.com"
    m = head.(["References: " <> Enum.map_join(ids, "\r\n ", &"<#{&1}>")])
    [first | newest] = m.refs
    size = Enum.sum_by(m.refs, &byte_size/1)
    assert first == hd(ids) and newest == Enum.take(ids, -length(newest)) and m.truncated
    assert size <= 8192 and size + byte_size(Enum.at(ids, -length(newest) - 1)) > 8192

    for {raw, want} <- [
          {"=?utf-8?Q?a?= x =?utf-8?Q?b?=", "a x b"},
          {"=?utf-8*en?Q?hello_world?=", "hello world"},
          {"=?ISO-8859-1?Q?caf=E9?= =?windows-1252?Q?=93ok=94?=", "café“ok”"},
          {"Re: =?utf-8?Q?broken", "Re: =?utf-8?Q?broken"},
          {"=?utf-8?X?abc?= =??Q?x?=", "=?utf-8?X?abc?= =??Q?x?="},
          {"Grüße", "Grüße"},
          {<<"Gr", 0xFC, 0xDF, "e">>, "Grüße"},
          {"tab\there\x01 and\x7F bell", "tab here and bell"}
        ] do
      assert head.(["Subject: " <> raw]).subject == want, inspect(raw)
    end

    assert head.([
             "List-Id: =?utf-8?Q?Careers_=C3=A9quipe?= <careers.example.com>",
             "List-Unsubscribe: <mailto:leave@example.com>,\r\n <https://example.com/leave>",
             "Return-Path: <bounce@example.org>",
             "X-Auto-Response-Suppress: All",
             "X-Failed-Recipients: nobody@example.org",
             ~s(Content-Type: multipart/mixed;\r\n\tboundary="=?utf-8?Q?raw?="),
             "X-Mailer: not kept"
           ]).headers == %{
             "list-id" => "Careers équipe <careers.example.com>",
             "list-unsubscribe" => "<mailto:leave@example.com>, <https://example.com/leave>",
             "return-path" => "<bounce@example.org>",
             "x-auto-response-suppress" => "All",
             "x-failed-recipients" => "nobody@example.org",
             "content-type" => ~s(multipart/mixed; boundary="=?utf-8?Q?raw?=")
           }
  end

  test "transfer encodings and charsets decode to UTF-8" do
    qp = "Content-Transfer-Encoding: quoted-printable"
    b64 = "Content-Transfer-Encoding: base64"
    type = &"Content-Type: text/plain; charset=#{&1}"

    for {head, body, want} <- [
          {qp, "caf=C3=A9 soft=\r\nbreak, blanks =  \r\nthen a soft break; =ZZ and =4 stay",
           "café softbreak, blanks then a soft break; =ZZ and =4 stay"},
          {b64, "SGVs bG8g!d29y\r\nbGQ", "Hello world"},
          {b64, "SGk=\r\nSGk=", "HiHi"},
          {type.("utf-16"), <<0xFF, 0xFE, "h", 0, "i", 0>>, "hi"},
          {type.("UTF-16BE"), <<0, "h", 0, "i">>, "hi"},
          {type.("utf-16"), <<0, "h", 0xD8, 0, 0, "i">>, "h#{@bad}i"},
          {type.("utf-8"), <<"a", 0xFF, "b">>, "a#{@bad}b"},
          {type.("ISO-8859-15"), <<0xA4, "5">>, "€5"},
          {type.("latin1"), <<"caf", 0xE9>>, "café"},
          {type.("iso-8859-1"), <<0x93, "q", 0x94>>, "“q”"},
          {type.("us-ascii"), <<"caf", 0xE9>>, "café"},
          {type.("us-ascii"), "café", "café"},
          {"Content-Type: text/plain", <<"caf", 0xE9>>, "café"},
          {type.("x-unknown"), "naïve", "naïve"},
          {type.("x-unknown"), <<"na", 0xEF, "ve">>, "na#{@bad}ve"},
          # Past Latin-1: Cyrillic, Central European, Greek, Turkish (iso-8859-9 as windows-1254).
          {type.("windows-1251"), <<0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2>>, "Привет"},
          {type.("koi8-r"), <<0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4>>, "Привет"},
          {type.("ISO-8859-2"), <<"Pozdrawiam, ", 0xA3, "ukasz">>, "Pozdrawiam, Łukasz"},
          {type.("windows-1250"), <<0x8A, "kola">>, "Škola"},
          {type.("iso-8859-7"), <<0xE3, 0xE5, 0xE9, 0xDC>>, "γειά"},
          {type.("iso-8859-9"), <<0xDE, "irket">>, "Şirket"},
          # Double-byte charsets without tables: the ASCII kept, one U+FFFD a character.
          {type.("shift_jis"), <<"Tokyo ", 0x93, 0x8C, 0x8B, 0x9E, " x@acme.example">>,
           "Tokyo #{@bad}#{@bad} x@acme.example"},
          {type.("euc-kr"), <<0xC7, 0xD1, "a">>, "#{@bad}a"},
          {type.("gb18030"), <<0x81, 0x30, 0x81, 0x30, "b">>, "#{@bad}b"},
          {type.("iso-2022-jp"),
           <<"See ", 0x1B, "$B", 0x46, 0x7C, 0x4B, 0x5C, 0x1B, "(B",
             " https://acme.example/jobs">>, "See #{@bad}#{@bad} https://acme.example/jobs"},
          {type.("utf-8"), "a\r\nb\rc\x00d", "a\nb\ncd"}
        ] do
      assert text(head, body) == want, inspect({head, body})
    end
  end

  test "inline plain and HTML parts become the text in order; every other part is an attachment, listed by name, type and size and never decoded" do
    forwarded = "From: a@example.com\r\nSubject: inner\r\n\r\nforwarded body"

    parts = [
      {"Content-Type: text/plain; charset=utf-8", "First."},
      {~s(Content-Type: text/plain\r\nContent-Disposition: attachment; filename="notes.txt"),
       "not text"},
      {"Content-Type: text/html", "<p>Second.</p>"},
      {"Content-Type: message/rfc822", forwarded},
      {~s(Content-Type: text/plain; name="log.txt"), "also not text"},
      {"Content-Type: text/plain", "Third."}
    ]

    body = Enum.map_join(parts, fn {head, body} -> "--b\r\n#{head}\r\n\r\n#{body}\r\n" end)

    m =
      parse!(
        ~s(Content-Type: multipart/mixed; boundary="b"\r\n\r\npreamble\r\n#{body}--b--\r\nepilogue)
      )

    assert m.text == "First.\n\nSecond.\n\nThird."
    refute m.truncated

    alternative =
      "--a\r\nContent-Type: text/plain\r\n\r\n \r\n--a\r\nContent-Type: text/html\r\n\r\n<p>From HTML.</p>\r\n--a--"

    assert text(~s(Content-Type: multipart/alternative; boundary="a"), alternative) ==
             "From HTML."

    assert m.attachments == [
             %{name: "notes.txt", type: "text/plain", size: 8},
             %{name: nil, type: "message/rfc822", size: byte_size(forwarded)},
             %{name: "log.txt", type: "text/plain", size: 13}
           ]
  end

  test "HTML reads as its visible text: block tags break lines, li items, cells, references, hidden elements dropped, links shown" do
    for {html, want} <- [
          {"a<br>b<br/><br>c", "a\nb\n\nc"},
          {"<ul><li>x</li><li>y</li></ul>after", "- x\n- y\n\nafter"},
          {"<table><tr><td>Role</td><td>Engineer</td></tr><tr><td>Place</td><td>Remote</td></tr></table>",
           "Role Engineer\nPlace Remote"},
          {"<div>line one</div><div>line two</div><div><br></div><div>after a gap</div>",
           "line one\nline two\n\nafter a gap"},
          {"<pre>a\n  b\n\n\n\nc</pre>", "a\nb\n\nc"},
          {"<head><title>t</title></head><body>x<script>if (a < b) {}</script><style>p{}</style>y</body>",
           "xy"},
          {"<!DOCTYPE html><!-- c --><![CDATA[x]]><template><p>hidden</p></template>z", "z"},
          {"&amp; &lt; &gt; &quot; &apos; &copy; &#233; &#xE9; &#150; &bogus; &amp",
           ~s(& < > " ' © é é – &bogus; &amp)},
          {~s|<a href="https://example.com/a">Apply</a> <a href="mailto:jobs@example.com">jobs@example.com</a> <a href="/relative">rel</a> <a href="javascript:void(0)">js</a> <a href="https://example.com/">https://example.com</a>|,
           "Apply (https://example.com/a) jobs@example.com rel js https://example.com"},
          {~s(<img src="https://track.example.com/p.gif" alt="logo">text), "text"},
          {"unclosed <b>bold <i>and <a href='https://example.com/x'>link",
           "unclosed bold and link (https://example.com/x)"},
          {"a < b && c > d", "a < b && c > d"},
          {"Sen<b>ior</b> &nbsp; Engineer", "Senior Engineer"},
          {~s(<a href="https://example.com/j?id=4&amp;utm=email" style="color:#1a73e8">Job</a> &middot; x),
           "Job (https://example.com/j?id=4&utm=email) · x"}
        ] do
      assert text("Content-Type: text/html", html) == want, html
    end
  end

  test "a Gmail-style bounce reads as a report: failed, 5.1.1, the original Message-ID and the recipient" do
    png =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    raw =
      String.replace(
        """
        Delivered-To: ada@example.com
        Return-Path: <>
        From: Mail Delivery Subsystem <mailer-daemon@googlemail.example.com>
        To: ada@example.com
        Auto-Submitted: auto-replied
        Subject: Delivery Status Notification (Failure)
        References: <CAOrig123@mail.gmail.example.com>
        In-Reply-To: <CAOrig123@mail.gmail.example.com>
        X-Failed-Recipients: nobody@example.org
        Message-ID: <6123.bounce@mx.google.example.com>
        Date: Wed, 21 Oct 2026 09:00:01 -0700 (PDT)
        Content-Type: multipart/report; boundary="000000000000a1b2c3"; report-type=delivery-status

        --000000000000a1b2c3
        Content-Type: multipart/related; boundary="000000000000d4e5f6"

        --000000000000d4e5f6
        Content-Type: multipart/alternative; boundary="000000000000g7h8i9"

        --000000000000g7h8i9
        Content-Type: text/plain; charset="UTF-8"


        ** Address not found **

        Your message wasn't delivered to nobody@example.org because the address couldn't be found, or is unable to receive mail.

        The response from the remote server was:
        550 5.1.1 The email account that you tried to reach does not exist.

        --000000000000g7h8i9
        Content-Type: text/html; charset="UTF-8"

        <html><head><style>* { font-family: Roboto, sans-serif; }</style></head><body><h2>Address not found</h2><p>Your message wasn't delivered.</p></body></html>
        --000000000000g7h8i9--
        --000000000000d4e5f6
        Content-Type: image/png; name="icon.png"
        Content-Disposition: attachment; filename="icon.png"
        Content-Transfer-Encoding: base64

        #{png}
        --000000000000d4e5f6--
        --000000000000a1b2c3
        Content-Type: message/delivery-status

        Reporting-MTA: dns; googlemail.example.com

        Final-Recipient: rfc822; Nobody@Example.org
        Action: failed
        Status: 5.1.1
        Diagnostic-Code: smtp; 550-5.1.1 The email account that you tried to reach does not exist.
         Please try 550-5.1.1 double-checking the recipient's email address for typos.

        --000000000000a1b2c3
        Content-Type: message/rfc822

        From: Ada Example <ada@example.com>
        To: nobody@example.org
        Subject: Application: Senior Backend Engineer
        Message-ID: <CAOrig123@mail.gmail.example.com>
        Date: Wed, 21 Oct 2026 09:00:00 -0700

        Please find my application attached.
        --000000000000a1b2c3--
        """,
        "\n",
        "\r\n"
      )

    m = parse!(raw)

    assert %{
             kind: :bounce,
             action: "failed",
             status: "5.1.1",
             original_message_id: "CAOrig123@mail.gmail.example.com",
             recipient: "nobody@example.org",
             diagnostic: diagnostic
           } = m.report

    assert diagnostic =~ "550-5.1.1 The email account that you tried to reach does not exist."
    assert m.text =~ "Address not found" and m.text =~ "wasn't delivered to nobody@example.org"
    refute m.text =~ "Please find my application"

    assert m.attachments == [
             %{name: "icon.png", type: "image/png", size: byte_size(Base.decode64!(png))}
           ]

    assert {m.headers["x-failed-recipients"], m.headers["auto-submitted"]} ==
             {"nobody@example.org", "auto-replied"}

    assert m.in_reply_to == "CAOrig123@mail.gmail.example.com"
  end

  test "bounds: 25 MiB; a 20 MiB attachment in well under a second; the text, a header and the header lines cut; nesting past 10 opaque; at most 200 parts" do
    max = 25 * 1024 * 1024
    assert {:error, :too_large} = Mime.parse(:binary.copy("a", max + 1))
    assert {:ok, _} = Mime.parse(:binary.copy("a", max))

    pdf = :binary.copy(<<1, 2, 3>>, 5 * 1024 * 1024)

    raw =
      "Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\nContent-Type: text/plain\r\n\r\nSee attached.\r\n--b\r\nContent-Type: application/pdf; name=big.pdf\r\nContent-Transfer-Encoding: base64\r\n\r\n" <>
        wrap(Base.encode64(pdf), "\r\n") <> "\r\n--b--\r\n"

    {us, m} = :timer.tc(fn -> parse!(raw) end)
    assert us < 1_000_000, "#{div(us, 1000)} ms"

    assert {m.text, m.attachments, m.truncated} ==
             {"See attached.",
              [%{name: "big.pdf", type: "application/pdf", size: byte_size(pdf)}], false}

    long = parse!("Content-Type: text/plain; charset=utf-8\r\n\r\n" <> :binary.copy("€", 100_000))
    assert byte_size(long.text) in (256 * 1024 - 2)..(256 * 1024) and String.valid?(long.text)
    assert long.truncated

    subject = parse!("Subject: " <> :binary.copy("word ", 4000) <> "\r\n\r\n")
    assert byte_size(subject.subject) in 8000..8192 and subject.truncated

    lines = parse!(:binary.copy("X-Filler: x\r\n", 1000) <> "Subject: late\r\n\r\nbody")
    assert lines.subject == "" and lines.truncated

    assert %{text: "deep", truncated: false} = parse!(nested(10))
    assert %{text: "", truncated: true} = parse!(nested(11))

    many = parse!(many(10_000))
    assert length(many.attachments) in 100..200 and many.truncated
  end

  ## Inputs

  defp nested(depth) do
    Enum.reduce(depth..1//-1, "Content-Type: text/plain\r\n\r\ndeep", fn d, inner ->
      "Content-Type: multipart/mixed; boundary=b#{d}\r\n\r\n--b#{d}\r\n#{inner}\r\n--b#{d}--\r\n"
    end)
  end

  defp many(n) do
    "Content-Type: multipart/mixed; boundary=p\r\n\r\n" <>
      :binary.copy("--p\r\nContent-Type: image/png\r\n\r\nx\r\n", n) <> "--p--\r\n"
  end

  @fragments [
    "--",
    "\r\n--",
    "\r\n\r\n",
    "=?utf-8?B?",
    "=?",
    "?=",
    "<!--",
    ~s(<a href="),
    "&#x",
    ~s("),
    "(",
    "<",
    ";",
    ":",
    "Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\n",
    "Content-Transfer-Encoding: base64\r\n",
    "Content-Type: message/delivery-status\r\n\r\nAction: failed\r\n",
    <<0xFF, 0xFE>>,
    <<0xC3>>,
    <<0>>
  ]

  # Random bytes, and the mail truncated, with bytes flipped, its boundary
  # lines deleted, and fragments of MIME spliced in.
  defp mutants(raw) do
    [
      :rand.bytes(:rand.uniform(2048)),
      binary_part(raw, 0, :rand.uniform(byte_size(raw) + 1) - 1),
      Enum.reduce(1..:rand.uniform(16), raw, fn _, r ->
        splice(r, <<:rand.uniform(256) - 1>>, 1)
      end),
      raw
      |> :binary.split("\n", [:global])
      |> Enum.reject(&String.starts_with?(&1, "--"))
      |> Enum.join("\n"),
      Enum.reduce(1..:rand.uniform(8), raw, fn _, r -> splice(r, pick(@fragments), 0) end)
    ]
  end

  # `r` with `cut` bytes at a random place replaced by `s`.
  defp splice(r, s, cut) do
    at = :rand.uniform(byte_size(r) + 1) - 1
    cut = min(cut, byte_size(r) - at)
    binary_part(r, 0, at) <> s <> binary_part(r, at + cut, byte_size(r) - at - cut)
  end

  defp well_formed!(raw, seed) do
    m = parse!(raw)
    at = "seed #{inspect(seed)}: #{inspect(raw, limit: 64, printable_limit: 512)}"
    ids = Enum.reject([m.message_id, m.in_reply_to | m.refs], &is_nil/1)
    strings = [m.key, m.subject, m.text | Map.values(m.headers)] ++ ids
    assert Enum.all?(strings, &(is_binary(&1) and String.valid?(&1))), at
    assert m.key != "" and is_boolean(m.truncated) and (m.date == nil or is_integer(m.date)), at
    assert Enum.all?(ids, &(&1 != "" and not (&1 =~ ~r/[\s<>]/))), at
    assert Enum.sum_by(m.refs, &byte_size/1) <= 8192, at

    for list <- [List.wrap(m.from), List.wrap(m.sender), m.reply_to, m.to, m.cc] do
      assert Enum.all?(list, fn %{name: name, addr: addr} ->
               String.valid?(addr) and addr =~ "@" and addr == String.downcase(addr) and
                 (name == nil or String.valid?(name))
             end),
             at

      assert Enum.sum_by(list, &(byte_size(&1.addr) + byte_size(&1.name || ""))) <= 8192, at
    end

    assert byte_size(m.subject) <= 8192 and not (m.subject =~ ~r/[\x00-\x1f\x7f]|\xc2[\x80-\x9f]/),
           at

    assert Enum.all?(m.headers, fn {k, v} -> k in @kept and byte_size(v) <= 8192 end), at
    assert byte_size(m.text) <= 256 * 1024 and length(m.attachments) <= 200, at

    assert Enum.all?(m.attachments, fn %{name: name, type: type, size: size} ->
             (name == nil or String.valid?(name)) and type =~ "/" and is_integer(size) and
               size >= 0
           end),
           at

    assert m.report == nil or
             (m.report.kind in [:bounce, :delay, :delivered, :other] and
                Enum.all?(Map.delete(m.report, :kind), fn {_, v} ->
                  v == nil or String.valid?(v)
                end)),
           at
  end

  ## A mail builder: random mail with known fields

  @ascii ~w(offer interview role engineer onsite thanks R&D schedule panel next steps)
  @latin ~w(café résumé naïve Zürich São mañana façade Ærø)
  @cp1252 ~w(€100 “quoted” it’s 2026–2027 wait… Œuvre)
  @wide ~w(日本 Привет Ελλάδα 🎉)
  @names [
    "Ada Quill",
    "Grace Fenwick",
    "Doe, Jane",
    ~s(Jane "JD" Doe),
    "Recruiting (Example)",
    "José Pérez",
    "Zoë O’Brien",
    "李雷"
  ]
  @files ["résumé.pdf", "Cover Letter.docx", "日程 2026.ics", "plain.pdf", "a;b.pdf"]
  @to_cp1252 %{
    0x20AC => 0x80,
    0x2026 => 0x85,
    0x2019 => 0x92,
    0x201C => 0x93,
    0x201D => 0x94,
    0x2013 => 0x96,
    0x152 => 0x8C
  }
  @zones [
    {"+0000", 0},
    {"-0700", -420},
    {"+0530", 330},
    {"+1400", 840},
    {"-1200", -720},
    {"GMT", 0},
    {"UT", 0},
    {"Z", 0},
    {"EST", -300},
    {"PDT", -420}
  ]
  @wdays ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp pick(list), do: Enum.random(list)
  defp chance(p), do: :rand.uniform() < p

  # {raw, the fields it must read back as}
  defp mail do
    nl = pick(["\r\n", "\n"])
    {from_lines, from} = if chance(0.9), do: one("From", 0), else: {[], nil}
    {to_lines, to} = list("To", 1, nl)
    {cc_lines, cc} = if chance(0.5), do: list("Cc", 20, nl), else: {[], []}
    {reply_lines, reply_to} = if chance(0.3), do: one("Reply-To", 40), else: {[], nil}
    {subject_lines, subject} = subject(nl)
    {date_lines, date_value, date} = date()
    {id_lines, id} = message_id(nl)
    {thread_lines, in_reply_to, refs} = thread(nl)
    {kept_lines, kept} = kept()
    {body_lines, body, text, attachments} = body(nl)

    transport =
      if chance(0.5),
        do: [
          "Received: from mx.example.net by mx.example.org; Wed, 21 Oct 2026 10:00:00 +0000",
          "Delivered-To: ada@example.com",
          "X-Gm-Message-State: AOJu0Yx",
          "ARC-Seal: i=1; a=rsa-sha256; t=1792598402; cv=none"
        ],
        else: []

    heads = [transport, from_lines, to_lines, cc_lines, reply_lines, subject_lines, date_lines]

    lines =
      Enum.concat(
        heads ++ [id_lines, thread_lines, kept_lines, ["MIME-Version: 1.0" | body_lines]]
      )

    "Content-Type: " <> type = Enum.find(body_lines, &String.starts_with?(&1, "Content-Type: "))

    want = %{
      message_id: id,
      in_reply_to: in_reply_to,
      refs: refs,
      from: from,
      sender: nil,
      reply_to: List.wrap(reply_to),
      to: to,
      cc: cc,
      subject: subject,
      date: date,
      headers: Map.put(kept, "content-type", String.replace(type, nl, "")),
      text: text,
      attachments: attachments,
      report: nil,
      truncated: false,
      key: id || key(if(from, do: from.addr, else: ""), date_value, subject, text)
    }

    {Enum.join(lines, nl) <> nl <> nl <> body, want}
  end

  defp key(from, date, subject, text) do
    head = binary_part(text, 0, min(byte_size(text), 4096))
    hash = :crypto.hash(:sha256, Enum.join([from, date, subject, head], "\n"))
    "sha256-" <> Base.encode16(hash, case: :lower) <> "@hireme.invalid"
  end

  defp one(header, n) do
    {written, box} = mailbox(n)
    {["#{header}: #{written}"], box}
  end

  # Mailboxes, perhaps in a group, with an empty group, folded, or over two
  # headers.
  defp list(header, n, nl) do
    boxes = for i <- 0..(:rand.uniform(3) - 1), do: mailbox(n + i)
    written = Enum.map(boxes, &elem(&1, 0))

    written =
      if chance(0.3), do: ["Hiring Team: " <> Enum.join(written, ", ") <> ";"], else: written

    written = if chance(0.2), do: written ++ ["undisclosed-recipients:;"], else: written
    sep = pick([", ", "," <> nl <> " "])

    lines =
      if length(written) > 1 and chance(0.3) do
        {first, rest} = Enum.split(written, 1)
        ["#{header}: #{Enum.join(first, sep)}", "#{header}: #{Enum.join(rest, sep)}"]
      else
        ["#{header}: #{Enum.join(written, sep)}"]
      end

    {lines, Enum.map(boxes, &elem(&1, 1))}
  end

  defp mailbox(n) do
    addr =
      pick(~w(jane.doe Recruiting+ref no-reply A.Quill hr)) <>
        "#{n}@" <> pick(~w(example.com Example.ORG mail.example.net))

    box = %{name: nil, addr: String.downcase(addr)}

    if chance(0.25) do
      {pick([addr, "<#{addr}>"]), box}
    else
      name = pick(@names)
      {phrase(name) <> " <#{addr}>", %{box | name: name}}
    end
  end

  # A display name as atoms, a quoted string with escapes (raw UTF-8 too, as
  # RFC 6532 allows), or encoded words.
  defp phrase(name) do
    cond do
      name =~ ~r/^[A-Za-z ]+$/ and chance(0.5) ->
        name

      ascii?(name) or chance(0.3) ->
        ~s(") <> String.replace(name, ["\\", ~s(")], &("\\" <> &1)) <> ~s(")

      true ->
        encoded(name, "utf-8", " ")
    end
  end

  defp subject(nl) do
    if chance(0.1) do
      {[], ""}
    else
      words = for _ <- 1..:rand.uniform(6), do: pick(@ascii ++ @latin ++ @cp1252 ++ @wide)
      subject = Enum.join(words, " ")
      prefix = pick(["", "Re: ", "Fwd: "])
      fold = pick([" ", nl <> " ", nl <> "\t"])

      written =
        if ascii?(subject),
          do: Enum.join(words, fold),
          else: encoded(subject, charset(subject), fold)

      {["Subject: " <> prefix <> written], prefix <> subject}
    end
  end

  defp charset(text) do
    cps = String.to_charlist(text)

    cond do
      Enum.all?(cps, &(&1 < 256)) -> pick(["utf-8", "iso-8859-1", "windows-1252"])
      Enum.all?(cps, &(&1 < 256 or is_map_key(@to_cp1252, &1))) -> pick(["utf-8", "windows-1252"])
      true -> "utf-8"
    end
  end

  # Encoded words over `text` in `charset`, cut at any byte, through a
  # multibyte character as well.
  defp encoded(text, charset, sep) do
    text
    |> encode(charset)
    |> chunks([])
    |> Enum.map_join(sep, fn chunk ->
      label = pick([charset, String.upcase(charset)])

      if chance(0.5),
        do: "=?#{label}?B?#{Base.encode64(chunk)}?=",
        else: "=?#{label}?#{pick(["Q", "q"])}?#{q(chunk)}?="
    end)
  end

  defp chunks("", acc), do: Enum.reverse(acc)

  defp chunks(bytes, acc) do
    n = min(:rand.uniform(16), byte_size(bytes))
    chunks(binary_part(bytes, n, byte_size(bytes) - n), [binary_part(bytes, 0, n) | acc])
  end

  defp q(bytes) do
    for <<c <- bytes>>, into: "" do
      cond do
        c in ?a..?z or c in ?A..?Z or c in ?0..?9 -> <<c>>
        c == ?\s -> "_"
        true -> "=" <> Base.encode16(<<c>>)
      end
    end
  end

  defp encode(text, "utf-8"), do: text

  defp encode(text, _single),
    do: for(<<cp::utf8 <- text>>, into: "", do: <<Map.get(@to_cp1252, cp, cp)>>)

  defp ascii?(s), do: for(<<c <- s>>, c > 127, do: c) == []

  defp date do
    if chance(0.1) do
      {[], "", nil}
    else
      seconds = chance(0.8)
      t = :rand.uniform(2_400_000_000) - 1
      t = if seconds, do: t, else: t - rem(t, 60)
      {zone, offset} = pick(@zones)

      {{y, mo, d}, {h, mi, s}} =
        :calendar.gregorian_seconds_to_datetime(t + offset * 60 + 62_167_219_200)

      wday = Enum.at(@wdays, :calendar.day_of_the_week(y, mo, d) - 1)
      year = if y in 1950..2049 and chance(0.2), do: pad(rem(y, 100)), else: "#{y}"
      time = Enum.map_join(if(seconds, do: [h, mi, s], else: [h, mi]), ":", &pad/1)

      value =
        "#{if chance(0.8), do: wday <> ", "}#{pick([d, pad(d)])} #{Enum.at(@months, mo - 1)} #{year} #{time} #{zone}#{if chance(0.3), do: " (local)"}"

      {["Date: " <> value], value, t}
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp message_id(nl) do
    if chance(0.2) do
      {[], nil}
    else
      left = "CA+" <> Base.url_encode64(:rand.bytes(9), padding: false)
      id = left <> "@Mail.Example.COM"
      {["Message-ID: " <> pick(["<#{id}>", "<#{left}@#{nl} Mail.Example.COM>"])], id}
    end
  end

  # In-Reply-To the newest, References with a repeat of the first.
  defp thread(nl) do
    if chance(0.5) do
      {[], nil, []}
    else
      ids = for i <- 1..:rand.uniform(4), do: "thread#{i}.#{:rand.uniform(9999)}@example.org"
      written = Enum.map_join(ids ++ [hd(ids)], pick([" ", nl <> " "]), &"<#{&1}>")
      {["In-Reply-To: <#{List.last(ids)}>", "References: " <> written], List.last(ids), ids}
    end
  end

  defp kept do
    pairs =
      Enum.filter(
        [
          {"List-Id", "Careers <careers.example.com>"},
          {"Auto-Submitted", "auto-generated"},
          {"Precedence", "bulk"},
          {"X-Autoreply", "yes"}
        ],
        fn _ -> chance(0.3) end
      )

    {Enum.map(pairs, fn {k, v} -> "#{k}: #{v}" end),
     Map.new(pairs, fn {k, v} -> {String.downcase(k), v} end)}
  end

  # {header lines, body, its text, its attachments}
  defp body(nl) do
    case pick([:plain, :html, :alternative, :mixed, :texts]) do
      :mixed ->
        {lines, body, text} = pick([&plain/1, &alternative/1]).(nl)
        files = for _ <- 1..:rand.uniform(2), do: attachment(nl)
        files = if chance(0.3), do: [calendar(nl) | files], else: files
        parts = Enum.shuffle([{lines, body, nil} | files])
        {lines, body} = multipart("mixed", Enum.map(parts, fn {l, b, _} -> {l, b} end), nl)
        {lines, body, text, for({_, _, file} <- parts, file, do: file)}

      :texts ->
        {l1, b1, t1} = plain(nl)
        {l2, b2, t2} = plain(nl)
        {lines, body} = multipart("mixed", [{l1, b1}, {l2, b2}], nl)
        {lines, body, t1 <> "\n\n" <> t2, []}

      kind ->
        {lines, body, text} =
          %{plain: &plain/1, html: &html/1, alternative: &alternative/1}[kind].(nl)

        {lines, body, text, []}
    end
  end

  defp plain(nl) do
    charset = pick(["utf-8", "iso-8859-1", "windows-1252"])
    text = charset |> paragraphs() |> Enum.join("\n\n")
    {cte, body} = transfer(encode(text, charset), nl)

    {[
       "Content-Type: text/plain; charset=" <> label(charset),
       "Content-Transfer-Encoding: " <> cte
     ], body, text}
  end

  defp html(nl) do
    charset = pick(["utf-8", "windows-1252"])
    paragraphs = paragraphs(charset)

    source =
      "<!DOCTYPE html><html><head><title>Not text</title><style>p { margin: 0 }</style></head><body><div>" <>
        Enum.map_join(paragraphs, "\n", &"<p>#{markup(&1)}</p>") <> "</div></body></html>"

    {cte, body} = transfer(encode(source, charset), nl)

    {[
       "Content-Type: text/html; charset=" <> label(charset),
       "Content-Transfer-Encoding: " <> cte
     ], body, Enum.join(paragraphs, "\n\n")}
  end

  # The plain part's text is the one read, wherever it stands; the HTML says
  # something else.
  defp alternative(nl) do
    {plain_lines, plain_body, text} = plain(nl)
    {html_lines, html_body, _other} = html(nl)
    parts = Enum.shuffle([{plain_lines, plain_body}, {html_lines, html_body}])
    {lines, body} = multipart("alternative", parts, nl)
    {lines, body, text}
  end

  defp multipart(subtype, parts, nl) do
    b = "=_" <> Base.url_encode64(:rand.bytes(6), padding: false)

    body =
      "This is a multi-part message in MIME format." <>
        nl <>
        Enum.map_join(parts, fn {lines, body} ->
          "--#{b}#{nl}#{Enum.join(lines, nl)}#{nl}#{nl}#{body}#{nl}"
        end) <>
        "--#{b}--#{nl}"

    {["Content-Type: multipart/#{subtype};" <> pick([" ", nl <> " "]) <> ~s(boundary="#{b}")],
     body}
  end

  # A file named in RFC 2231 (whole or in sections), quoted, or as an encoded
  # word in Content-Type's name.
  defp attachment(nl) do
    bytes = :rand.bytes(:rand.uniform(3000) - 1)
    name = pick(@files)
    type = pick(~w(application/pdf image/png application/octet-stream))

    pct =
      for <<c <- name>>,
        do:
          if(c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in ~c".-_",
            do: <<c>>,
            else: "%" <> Base.encode16(<<c>>)
          )

    lines =
      case pick([:whole, :sections, :quoted, :encoded]) do
        :whole ->
          ["Content-Type: " <> type, "Content-Disposition: attachment; filename*=utf-8''#{pct}"]

        :sections ->
          {a, b} = Enum.split(pct, :rand.uniform(length(pct) - 1))

          [
            "Content-Type: " <> type,
            "Content-Disposition: attachment;#{nl} filename*0*=UTF-8''#{a};#{nl} filename*1*=#{b}"
          ]

        :quoted when name in ["plain.pdf", "a;b.pdf"] ->
          [~s(Content-Type: #{type}; name="#{name}"), "Content-Disposition: attachment"]

        _ ->
          [~s(Content-Type: #{type};#{nl} name="=?utf-8?B?#{Base.encode64(name)}?=")]
      end

    {lines ++ ["Content-Transfer-Encoding: base64"], wrap(Base.encode64(bytes), nl),
     %{name: name, type: type, size: byte_size(bytes)}}
  end

  defp calendar(nl) do
    body = Enum.join(["BEGIN:VCALENDAR", "METHOD:REQUEST", "END:VCALENDAR"], nl)

    {["Content-Type: text/calendar; method=REQUEST; charset=utf-8"], body,
     %{name: nil, type: "text/calendar", size: byte_size(body)}}
  end

  defp label(charset), do: pick([charset, String.upcase(charset), ~s("#{charset}")])

  defp paragraphs(charset) do
    pool =
      %{
        "utf-8" => @ascii ++ @latin ++ @cp1252 ++ @wide,
        "windows-1252" => @ascii ++ @latin ++ @cp1252,
        "iso-8859-1" => @ascii ++ @latin
      }[charset]

    for _ <- 1..:rand.uniform(3),
        do: Enum.map_join(1..(2 + :rand.uniform(8)), " ", fn _ -> pick(pool) end)
  end

  # A paragraph as HTML: "&" and "<" escaped, words apart by any run of
  # blanks, some characters as numeric references.
  defp markup(paragraph) do
    paragraph
    |> String.split(" ")
    |> Enum.map(fn word -> for <<cp::utf8 <- word>>, into: "", do: html_char(cp) end)
    |> Enum.reduce(fn word, acc -> acc <> pick([" ", "&nbsp;", "\n", " \t "]) <> word end)
  end

  defp html_char(?&), do: "&amp;"
  defp html_char(?<), do: "&lt;"

  defp html_char(cp) when cp > 127 do
    if chance(0.3), do: pick(["&##{cp};", "&#x#{Integer.to_string(cp, 16)};"]), else: <<cp::utf8>>
  end

  defp html_char(cp), do: <<cp::utf8>>

  defp transfer(bytes, nl) do
    case pick(
           if ascii?(bytes),
             do: ~w(7bit 8bit quoted-printable base64),
             else: ~w(8bit quoted-printable base64)
         ) do
      "base64" ->
        {"base64",
         bytes |> :binary.replace("\n", "\r\n", [:global]) |> Base.encode64() |> wrap(nl)}

      "quoted-printable" ->
        {"quoted-printable", qp(bytes, nl)}

      plain ->
        {plain, :binary.replace(bytes, "\n", nl, [:global])}
    end
  end

  defp wrap(s, nl), do: Regex.scan(~r/.{1,76}/s, s) |> Enum.map_join(nl, &hd/1)

  # Quoted-printable, soft-broken under 76 characters: a token is at most
  # three bytes, so 24 to a line.
  defp qp(bytes, nl) do
    bytes
    |> :binary.split("\n", [:global])
    |> Enum.map_join(nl, fn line ->
      tokens =
        for <<c <- line>> do
          cond do
            c in 33..126 and c != ?= -> <<c>>
            c == ?\s -> " "
            true -> "=" <> Base.encode16(<<c>>)
          end
        end

      tokens = if List.last(tokens) == " ", do: List.replace_at(tokens, -1, "=20"), else: tokens
      tokens |> Enum.chunk_every(24) |> Enum.map_join("=" <> nl, &Enum.join/1)
    end)
  end
end
