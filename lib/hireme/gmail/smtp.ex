defmodule Hireme.Gmail.Smtp do
  @moduledoc """
  One message through Gmail's SMTP submission, and its composition.

  Delivery: TLS up to the endpoint's `:tls` — implicit on 465, or a plain
  connection upgraded with STARTTLS everywhere else (587, the default, because
  fsn1-2 has no route to 465: `docs/mail/deliverability.md`) — verified as
  `Hireme.Gmail.Imap.tls/2` verifies it, then EHLO, AUTH PLAIN with the app
  password, one envelope, DATA, QUIT. Gmail files what it accepts in the
  account's Sent, so the thread lives in the operator's own mailbox as if sent
  from Gmail itself.

  Composition: RFC 5322 with MIME. The body is UTF-8 quoted-printable, any
  non-ASCII header text RFC 2047 encoded words, an attachment a base64
  part. The Message-ID is the caller's (the node mints it before it sends,
  so a retry after a crash sends the same one). Header values are cleared
  of line breaks, so no text the mail carries can add a header.
  """

  alias Hireme.Gmail.Imap

  @type error ::
          :auth
          | {:temporary, String.t()}
          | {:permanent, String.t()}
          | {:network, term}
          | {:unknown, term}

  # Gmail's own cap on one submission's recipients is far higher; the link's is 10.
  @max_rcpts 10

  @doc """
  Sends `data` (a composed message) from `from` to `rcpts`, logging in as
  `user`. Answers Gmail's acceptance line, or why it was not accepted:
  `:auth` (the app password was refused), `{:temporary, reply}` (4xx: try
  again later), `{:permanent, reply}` (5xx), `{:network, reason}` (before
  the message was complete, so Gmail cannot have taken it). Only
  `{:unknown, reason}` (the connection lost once the message's final dot
  was written, before Gmail's answer) leaves it open whether Gmail took
  it; the caller looks in Sent before it sends again.
  """
  @spec deliver(map, String.t(), String.t(), String.t(), [String.t()], iodata) ::
          {:ok, String.t()} | {:error, error}
  def deliver(%{host: host, port: port, cacerts: cacerts} = at, user, password, from, rcpts, data)
      when length(rcpts) in 1..@max_rcpts do
    s = %{
      socket: nil,
      kind: nil,
      tls: Map.get(at, :tls) || tls(port),
      host: host,
      port: port,
      cacerts: cacerts,
      buf: "",
      timeout: Map.get(at, :timeout, 60_000)
    }

    case open(s) do
      {:ok, s} ->
        try do
          session(s, user, password, from, rcpts, data)
        after
          close(s)
        end

      error ->
        error
    end
  end

  def deliver(_at, _user, _password, _from, rcpts, _data),
    do: {:error, {:permanent, "#{length(rcpts)} recipients: 1 to #{@max_rcpts}"}}

  # 465 opens on TLS; 587 opens in the clear and is upgraded with STARTTLS,
  # which is the only one of the two this host can reach.
  defp tls(465), do: :implicit
  defp tls(_port), do: :starttls

  # The greeting read and EHLO answered, the socket TLS where the endpoint is.
  defp open(%{tls: :implicit, host: host, port: port, cacerts: cacerts, timeout: timeout} = s) do
    case :ssl.connect(String.to_charlist(host), port, Imap.tls(host, cacerts), timeout) do
      {:ok, socket} -> hello(%{s | socket: socket, kind: :ssl})
      {:error, reason} -> {:error, {:network, reason}}
    end
  end

  defp open(%{tls: :starttls, host: host, port: port, timeout: timeout} = s) do
    case :gen_tcp.connect(
           String.to_charlist(host),
           port,
           [:binary, active: false, packet: :raw],
           timeout
         ) do
      {:ok, socket} ->
        s = %{s | socket: socket, kind: :tcp}

        with {:ok, _, s} <- expect(s, nil, 220),
             {:ok, _, s} <- expect(s, "EHLO hireme", 250),
             {:ok, _, s} <- expect(s, "STARTTLS", 220),
             :ok <- empty(s),
             {:ok, socket} <- upgrade(s, timeout) do
          # RFC 3207: what EHLO said before the handshake is forgotten.
          hello(%{s | socket: socket, kind: :ssl, buf: ""})
        end

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  defp hello(s) do
    case expect(s, "EHLO hireme", 250) do
      {:ok, _, s} -> {:ok, s}
      error -> error
    end
  end

  # STARTTLS: the plain socket becomes TLS, verified as Imap.tls/2 says.
  defp upgrade(%{socket: socket, host: host, cacerts: cacerts}, timeout) do
    case :ssl.connect(socket, Imap.tls(host, cacerts), timeout) do
      {:ok, ssl} -> {:ok, ssl}
      {:error, reason} -> {:error, {:network, reason}}
    end
  end

  # Nothing may follow STARTTLS's 220: the next bytes are the handshake.
  defp empty(%{buf: ""}), do: :ok
  defp empty(_s), do: {:error, {:network, :starttls}}

  defp session(s, user, password, from, rcpts, data) do
    plain = Base.encode64(<<0, user::binary, 0, password::binary>>)

    with {:ok, _, s} <- expect(s, ["AUTH PLAIN ", plain], 235, :auth),
         {:ok, _, s} <- expect(s, ["MAIL FROM:<", from, ">"], 250),
         {:ok, s} <- recipients(s, rcpts),
         {:ok, _, s} <- expect(s, "DATA", 354),
         :ok <- put(s, [stuffed(data), "\r\n."]),
         {:ok, accepted, s} <- answer(s) do
      expect(s, "QUIT", 221)
      {:ok, accepted}
    end
  end

  # Gmail's answer to a complete message: a lost connection now may have
  # come after Gmail took it.
  defp answer(s) do
    case expect(s, nil, 250) do
      {:error, {:network, why}} -> {:error, {:unknown, why}}
      other -> other
    end
  end

  defp recipients(s, []), do: {:ok, s}

  defp recipients(s, [rcpt | rest]) do
    case expect(s, ["RCPT TO:<", rcpt, ">"], 250) do
      {:ok, _, s} -> recipients(s, rest)
      {:error, {:permanent, "251" <> _}} -> recipients(s, rest)
      error -> error
    end
  end

  # Sends a line (none for the greeting) and reads the reply: `want`, or
  # the error its code says. 535 and 534 are Gmail refusing the login.
  defp expect(s, line, want, on_auth \\ nil) do
    with :ok <- put(s, line),
         {:ok, code, text, s} <- reply(s, []) do
      cond do
        code == want -> {:ok, text, s}
        on_auth == :auth and code in [534, 535] -> {:error, :auth}
        code in 400..499 -> {:error, {:temporary, "#{code} #{text}"}}
        true -> {:error, {:permanent, "#{code} #{text}"}}
      end
    end
  end

  defp put(_s, nil), do: :ok

  defp put(s, line) do
    case transmit(s, [line, "\r\n"]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:network, reason}}
    end
  end

  defp transmit(%{kind: :ssl, socket: socket}, data), do: :ssl.send(socket, data)
  defp transmit(%{kind: :tcp, socket: socket}, data), do: :gen_tcp.send(socket, data)

  defp recv(%{kind: :ssl, socket: socket}, timeout), do: :ssl.recv(socket, 0, timeout)
  defp recv(%{kind: :tcp, socket: socket}, timeout), do: :gen_tcp.recv(socket, 0, timeout)

  defp close(%{kind: :ssl, socket: socket}) when socket != nil, do: :ssl.close(socket)
  defp close(%{kind: :tcp, socket: socket}) when socket != nil, do: :gen_tcp.close(socket)
  defp close(_s), do: :ok

  # A reply, its continuation lines (250-...) joined.
  defp reply(s, acc) do
    case line(s) do
      {:ok, <<code::binary-3, sep, text::binary>>, s} when sep in [?\s, ?-] ->
        acc = [text | acc]

        case {Integer.parse(code), sep} do
          {{n, ""}, ?\s} -> {:ok, n, acc |> Enum.reverse() |> Enum.join(" "), s}
          {{_, ""}, ?-} -> reply(s, acc)
          _ -> {:error, {:network, :reply}}
        end

      {:ok, <<code::binary-3>>, s} ->
        case Integer.parse(code) do
          {n, ""} -> {:ok, n, acc |> Enum.reverse() |> Enum.join(" "), s}
          _ -> {:error, {:network, :reply}}
        end

      {:ok, _, _} ->
        {:error, {:network, :reply}}

      error ->
        error
    end
  end

  defp line(s) do
    case :binary.split(s.buf, "\r\n") do
      [line, rest] ->
        {:ok, line, %{s | buf: rest}}

      [_] when byte_size(s.buf) > 65_536 ->
        {:error, {:network, :reply}}

      [_] ->
        case recv(s, s.timeout) do
          {:ok, data} -> line(%{s | buf: s.buf <> data})
          {:error, reason} -> {:error, {:network, reason}}
        end
    end
  end

  # RFC 5321 4.5.2: a line starting with a dot gets another.
  defp stuffed(data) do
    data = IO.iodata_to_binary(data)
    data = if String.starts_with?(data, "."), do: "." <> data, else: data
    String.replace(data, "\r\n.", "\r\n..")
  end

  # ---------------------------------------------------------- composition

  @doc """
  The message as sent. `mail` holds `from` (an address) and optionally
  `from_name`, `to` and `cc` (address lists), `subject`, `body` (text),
  `message_id`, `in_reply_to` and `refs` (ids without brackets), `date`
  (unix seconds) and `attachments` (`%{name, type, data}`). Lines end in
  CRLF.
  """
  @spec compose(map) :: binary
  def compose(mail) do
    boundary = "hm-" <> Base.encode32(:crypto.strong_rand_bytes(15), case: :lower, padding: false)
    attachments = Map.get(mail, :attachments, [])

    headers =
      [
        {"From", mailbox(Map.get(mail, :from_name), mail.from)},
        {"To", Enum.join(mail.to, ",\r\n ")},
        {"Cc", Enum.join(Map.get(mail, :cc, []), ",\r\n ")},
        {"Subject", encoded(Map.get(mail, :subject, ""))},
        {"Date", date(mail.date)},
        {"Message-ID", ids([mail.message_id])},
        {"In-Reply-To", ids([Map.get(mail, :in_reply_to)])},
        {"References", ids(Map.get(mail, :refs, []))},
        {"MIME-Version", "1.0"}
      ]
      |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
      |> Enum.map(fn {k, v} -> [k, ": ", v, "\r\n"] end)

    body = text_part(Map.get(mail, :body) || "")

    IO.iodata_to_binary(
      if attachments == [] do
        [headers, body]
      else
        [
          headers,
          ~s(Content-Type: multipart/mixed; boundary="#{boundary}"\r\n\r\n),
          ["--", boundary, "\r\n", body, "\r\n"],
          Enum.map(attachments, &["--", boundary, "\r\n", attachment(&1), "\r\n"]),
          ["--", boundary, "--\r\n"]
        ]
      end
    )
  end

  defp text_part(text) do
    [
      "Content-Type: text/plain; charset=utf-8\r\n",
      "Content-Transfer-Encoding: quoted-printable\r\n\r\n",
      qp(text)
    ]
  end

  defp attachment(%{name: name, type: type, data: data}) do
    [
      "Content-Type: ",
      if(type =~ ~r/\A[a-z0-9.+-]+\/[a-z0-9.+-]+\z/i, do: type, else: "application/octet-stream"),
      ";\r\n ",
      param("name", name),
      "\r\nContent-Disposition: attachment;\r\n ",
      param("filename", name),
      "\r\nContent-Transfer-Encoding: base64\r\n\r\n",
      data |> Base.encode64() |> lines(76)
    ]
  end

  # A short plain ASCII name quoted; any other as RFC 2231 says, cut in
  # continuations of at most 60 encoded bytes so no line runs long.
  defp param(key, name) do
    name = clean(name)

    if plain?(name) and byte_size(name) <= 60 do
      [key, ~s(="), String.replace(name, ~r/["\\]/, "\\\\\\0"), ?"]
    else
      name
      |> chunks(20, [], [])
      |> Enum.with_index()
      |> Enum.map_join(";\r\n ", fn {part, i} ->
        lead = if i == 0, do: "utf-8''", else: ""
        "#{key}*#{i}*=#{lead}#{URI.encode(part, &URI.char_unreserved?/1)}"
      end)
    end
  end

  defp lines(b64, n) when byte_size(b64) <= n, do: [b64, "\r\n"]

  defp lines(b64, n) do
    <<chunk::binary-size(^n), rest::binary>> = b64
    [chunk, "\r\n" | lines(rest, n)]
  end

  defp mailbox(nil, addr), do: addr
  defp mailbox("", addr), do: addr

  defp mailbox(name, addr) do
    name = clean(name)

    cond do
      not plain?(name) -> "#{encoded(name)} <#{addr}>"
      name =~ ~r/\A[A-Za-z0-9!#$%&'*+\-\/=?^_`{|}~ ]+\z/ -> "#{encoded(name)} <#{addr}>"
      # A long name that needs quoting goes as encoded words, which fold.
      byte_size(name) > 70 -> "#{words(name)} <#{addr}>"
      true -> ~s("#{String.replace(name, ~r/["\\]/, "\\\\\\0")}" <#{addr}>)
    end
  end

  # Ids as the thread holds them, bracketed once whether or not they came so.
  defp ids(ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> clean() |> String.trim() |> String.trim("<") |> String.trim(">")))
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      ids -> Enum.map_join(ids, "\r\n ", &"<#{&1}>")
    end
  end

  # Header text: plain ASCII folded at spaces; anything else (other
  # characters, a word too long to fold under 998, text a reader would take
  # for an encoded word) as encoded words of at most 45 bytes each (75
  # characters encoded), split between characters.
  defp encoded(text) do
    text = clean(text)

    if plain?(text), do: fold(String.split(text, " "), [], 0), else: words(text)
  end

  defp words(text),
    do: text |> chunks(45, [], []) |> Enum.map_join("\r\n ", &"=?UTF-8?B?#{Base.encode64(&1)}?=")

  defp plain?(text),
    do:
      ascii?(text) and not String.contains?(text, "=?") and
        Enum.all?(String.split(text, " "), &(byte_size(&1) <= 70))

  defp fold([], acc, _), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp fold([w | rest], [], _), do: fold(rest, [w], byte_size(w))

  defp fold([w | rest], acc, n) when n + 1 + byte_size(w) > 70,
    do: fold(rest, [w, "\r\n " | acc], byte_size(w))

  defp fold([w | rest], acc, n), do: fold(rest, [w, " " | acc], n + 1 + byte_size(w))

  defp chunks("", _max, [], acc), do: Enum.reverse(acc)

  defp chunks("", _max, cur, acc),
    do: Enum.reverse([IO.iodata_to_binary(Enum.reverse(cur)) | acc])

  defp chunks(text, max, cur, acc) do
    {c, rest} = String.next_codepoint(text)

    if IO.iodata_length(cur) + byte_size(c) > max,
      do: chunks(rest, max, [c], [IO.iodata_to_binary(Enum.reverse(cur)) | acc]),
      else: chunks(rest, max, [c | cur], acc)
  end

  defp clean(text), do: String.replace(to_string(text), ~r/[\r\n\0]+/, " ")

  defp ascii?(text), do: text =~ ~r/\A[\x20-\x7e]*\z/

  defp date(unix) do
    unix |> DateTime.from_unix!() |> Calendar.strftime("%a, %d %b %Y %H:%M:%S +0000")
  end

  # Quoted-printable (RFC 2045 6.7): lines of at most 76 characters, soft
  # breaks where a line runs longer, trailing spaces encoded.
  defp qp(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.map_join("\r\n", &qp_line/1)
  end

  defp qp_line(line) do
    last = byte_size(line) - 1

    {lines, cur, _} =
      line
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.reduce({[], [], 0}, fn {b, i}, {lines, cur, n} ->
        enc = qp_byte(b, i == last)

        if n + byte_size(enc) > 75,
          do: {[Enum.reverse(cur) | lines], [enc], byte_size(enc)},
          else: {lines, [enc | cur], n + byte_size(enc)}
      end)

    [Enum.reverse(cur) | lines]
    |> Enum.reverse()
    |> Enum.intersperse("=\r\n")
    |> IO.iodata_to_binary()
  end

  defp qp_byte(b, last?) when b in [?\s, ?\t] and last?, do: hex(b)
  defp qp_byte(b, _) when b in 33..126 and b != ?=, do: <<b>>
  defp qp_byte(b, _) when b in [?\s, ?\t], do: <<b>>
  defp qp_byte(b, _), do: hex(b)

  defp hex(b), do: "=" <> Base.encode16(<<b>>)
end
