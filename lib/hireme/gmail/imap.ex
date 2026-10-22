defmodule Hireme.Gmail.Imap do
  @moduledoc """
  One IMAP connection to Gmail: the few commands the link needs (RFC 3501
  with Gmail's X-GM-EXT-1). Log in, find All Mail by its SPECIAL-USE flag
  (its name is localized), select it, search and fetch by UID, add a label,
  and IDLE.

  Every fetch is `BODY.PEEK`, so nothing hireme reads is marked seen.
  Nothing is ever moved, flagged or deleted.

  The connection is passive (each call sends a command and reads its
  answer), except while idling. `idle/1` gives the socket to the calling
  process in active-once mode, so Gmail's pushes arrive as messages. The
  owner hands them to `idle_data/2` until `done/1` ends the idle.

  Errors never carry a credential. Gmail never echoes one, and a refused
  login answers an atom, not Gmail's text.
  """

  defstruct [:socket, :idle, tag: 0, buf: "", scanned: 0, timeout: 30_000]

  @type t :: %__MODULE__{}
  @type error ::
          :auth
          | :imap_disabled
          | :no_all_mail
          | :not_gmail
          | {:no | :bad | :bye, String.t()}
          | {:network, term}

  # Gmail's own limit is 35 MB per message; the link reads none over 25 MiB.
  @max_literal 26 * 1024 * 1024
  # A SEARCH over months of mail answers a long line of UIDs.
  @max_line 16 * 1024 * 1024

  # What the envelope pass reads: enough for the filer to tell a candidate
  # from everything else without reading a body.
  @envelope ~w(FROM TO CC REPLY-TO SENDER SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES
               LIST-ID LIST-UNSUBSCRIBE AUTO-SUBMITTED PRECEDENCE RETURN-PATH X-AUTOREPLY
               X-AUTO-RESPONSE-SUPPRESS X-FAILED-RECIPIENTS CONTENT-TYPE AUTHENTICATION-RESULTS)

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc """
  The TLS options for a Gmail host: the peer verified against `cacerts`
  (`:system` is the OS store), its name checked as HTTPS checks it, SNI,
  and TLS 1.2 or 1.3 only.
  """
  @spec tls(String.t(), [binary] | :system) :: list
  def tls(host, cacerts) do
    [
      :binary,
      active: false,
      verify: :verify_peer,
      cacerts: if(cacerts == :system, do: :public_key.cacerts_get(), else: cacerts),
      depth: 99,
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      versions: [:"tlsv1.3", :"tlsv1.2"]
    ]
  end

  @doc "Opens the connection and reads Gmail's greeting."
  @spec connect(String.t(), :inet.port_number(), [binary] | :system, timeout) ::
          {:ok, t} | {:error, error}
  def connect(host, port, cacerts, timeout \\ 30_000) do
    case :ssl.connect(String.to_charlist(host), port, tls(host, cacerts), timeout) do
      {:ok, socket} ->
        conn = %__MODULE__{socket: socket, timeout: timeout}

        case response(conn, timeout) do
          {:ok, {:untagged, {:status, :ok, _, _}}, conn} -> {:ok, conn}
          {:ok, {:untagged, {:bye, text}}, conn} -> fail(conn, {:bye, text})
          {:ok, _, conn} -> fail(conn, {:bad, "greeting"})
          {:error, reason} -> fail(conn, {:network, reason})
        end

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  @doc """
  Logs in, then checks the server is Gmail (X-GM-EXT-1). A refused login
  closes the connection and answers `:auth` (wrong or revoked app password,
  or an account that wants a browser sign-in) or `:imap_disabled`.
  """
  @spec login(t, String.t(), String.t()) :: {:ok, t} | {:error, error}
  def login(conn, user, password) do
    with {:ok, user} <- quoted(user),
         {:ok, password} <- quoted(password) do
      case command(conn, ["LOGIN ", user, " ", password]) do
        {:ok, {:ok, _, _}, conn} -> gmail?(conn)
        {:ok, {:no, text, _}, conn} -> fail(conn, refused(text))
        {:ok, {:bad, text, _}, conn} -> fail(conn, {:bad, text})
        {:error, _} = e -> e
      end
    else
      :error -> fail(conn, :auth)
    end
  end

  defp gmail?(conn) do
    case command(conn, "CAPABILITY") do
      {:ok, {:ok, _, untagged}, conn} ->
        caps = for {:capability, caps} <- untagged, cap <- caps, do: String.upcase(cap)
        if "X-GM-EXT-1" in caps, do: {:ok, conn}, else: fail(conn, :not_gmail)

      other ->
        answer(other)
    end
  end

  # Gmail's words for a password it will not take: wrong or revoked, a
  # plain account password where an app password is needed, or an account
  # that wants a browser sign-in first.
  defp refused(text) do
    cond do
      text =~ "AUTHENTICATIONFAILED" -> :auth
      text =~ ~r/not enabled for IMAP/i -> :imap_disabled
      text =~ ~r/application-specific password|web ?browser|WEBALERT/i -> :auth
      true -> {:no, text}
    end
  end

  @doc """
  The folders the link reads, found by their SPECIAL-USE flags (the names
  are localized): All Mail (`\\All`) and Spam (`\\Junk`, nil when Gmail
  shows none). `:no_all_mail` means the operator hid All Mail from IMAP in
  Gmail's label settings.
  """
  @spec folders(t) :: {:ok, %{all: String.t(), junk: String.t() | nil}, t} | {:error, error}
  def folders(conn) do
    case command(conn, ~s(LIST "" "*")) do
      {:ok, {:ok, _, untagged}, conn} ->
        flagged = fn flag ->
          Enum.find_value(untagged, fn
            {:list, flags, name} -> flag in flags and name
            _ -> nil
          end)
        end

        case flagged.("\\all") do
          nil -> fail(conn, :no_all_mail)
          all -> {:ok, %{all: all, junk: flagged.("\\junk")}, conn}
        end

      other ->
        answer(other)
    end
  end

  @doc "Selects a folder: its UIDVALIDITY, UIDNEXT and message count."
  @spec select(t, String.t()) ::
          {:ok, %{uidvalidity: integer | nil, uidnext: integer | nil, exists: integer}, t}
          | {:error, error}
  def select(conn, name) do
    with {:ok, name} <- quoted(name) |> or_bad(conn, "folder") do
      case command(conn, ["SELECT ", name]) do
        {:ok, {:ok, _, untagged}, conn} ->
          {:ok, Enum.reduce(untagged, %{uidvalidity: nil, uidnext: nil, exists: 0}, &selected/2),
           conn}

        other ->
          answer(other)
      end
    end
  end

  defp selected({:status, :ok, {"UIDVALIDITY", v}, _}, acc), do: %{acc | uidvalidity: int(v)}
  defp selected({:status, :ok, {"UIDNEXT", v}, _}, acc), do: %{acc | uidnext: int(v)}
  defp selected({:exists, n}, acc), do: %{acc | exists: n}
  defp selected(_, acc), do: acc

  @doc "UIDs from `first` on (`UID first:*`, without the RFC's highest-UID quirk)."
  @spec since_uid(t, pos_integer) :: {:ok, [pos_integer], t} | {:error, error}
  def since_uid(conn, first) do
    with {:ok, uids, conn} <- search(conn, "UID #{first}:*"),
         do: {:ok, Enum.filter(uids, &(&1 >= first)), conn}
  end

  @doc "UIDs of mail whose internal date is on or after `date`."
  @spec since_date(t, Date.t()) :: {:ok, [pos_integer], t} | {:error, error}
  def since_date(conn, %Date{} = d),
    do: search(conn, "SINCE #{d.day}-#{Enum.at(@months, d.month - 1)}-#{d.year}")

  @doc """
  UIDs of the mail whose Message-ID is `id` (brackets or not). Gmail's
  search reads its index, which may lag a mail it has just taken, so the
  headers of the UIDs after `after_uid` are read too: a mail newer than
  that is found the moment it is in All Mail. An id Gmail's search syntax
  cannot carry answers `:unsearchable`, never "none".
  """
  @spec message_id(t, String.t(), non_neg_integer) ::
          {:ok, [pos_integer] | :unsearchable, t} | {:error, error}
  def message_id(conn, id, after_uid \\ 0) do
    id = id |> String.trim() |> String.trim("<") |> String.trim(">")

    if id =~ ~r/\A[[:graph:]]+@[[:graph:]]+\z/ and
         not String.contains?(id, ["\"", "\\", "(", ")"]) do
      with {:ok, indexed, conn} <- search(conn, ~s(X-GM-RAW "rfc822msgid:#{id}")),
           {:ok, recent, conn} <- recent_ids(conn, after_uid) do
        fresh = for {uid, mid} <- recent, String.downcase(mid) == String.downcase(id), do: uid
        {:ok, Enum.sort(Enum.uniq(indexed ++ fresh)), conn}
      end
    else
      {:ok, :unsearchable, conn}
    end
  end

  # The Message-IDs of the mail after `after_uid`, read off its headers.
  defp recent_ids(conn, after_uid) do
    with {:ok, uids, conn} <- since_uid(conn, after_uid + 1),
         {:ok, found, conn} <-
           fetch(
             conn,
             Enum.take(uids, -200),
             "(UID BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])",
             conn.timeout
           ) do
      {:ok,
       for(
         %{uid: uid, header: h} <- found,
         [_, mid] <- [Regex.run(~r/<([^<>\s]+)>/, h)],
         do: {uid, mid}
       ), conn}
    end
  end

  defp search(conn, criteria) do
    case command(conn, ["UID SEARCH ", criteria]) do
      {:ok, {:ok, _, untagged}, conn} ->
        {:ok, Enum.sort(for({:search, uids} <- untagged, uid <- uids, do: uid)), conn}

      other ->
        answer(other)
    end
  end

  @doc """
  The envelopes of `uids`: per message its `uid`, `msgid`, `thrid`, `labels`,
  `internaldate` (unix seconds), `size` and `header` (the header lines the
  filer reads, as raw bytes).
  """
  @spec envelopes(t, [pos_integer]) :: {:ok, [map], t} | {:error, error}
  def envelopes(conn, uids) do
    fetch(
      conn,
      uids,
      "(UID X-GM-MSGID X-GM-THRID X-GM-LABELS INTERNALDATE RFC822.SIZE " <>
        "BODY.PEEK[HEADER.FIELDS (#{Enum.join(@envelope, " ")})])",
      conn.timeout
    )
  end

  @doc "One message whole, as `raw` (with `uid` and its Gmail ids)."
  @spec message(t, pos_integer) :: {:ok, map | nil, t} | {:error, error}
  def message(conn, uid) do
    with {:ok, found, conn} <-
           fetch(conn, [uid], "(UID X-GM-MSGID X-GM-THRID X-GM-LABELS BODY.PEEK[])", 120_000),
         do: {:ok, List.first(found), conn}
  end

  defp fetch(conn, [], _items, _timeout), do: {:ok, [], conn}

  defp fetch(conn, uids, items, timeout) do
    case command(conn, ["UID FETCH ", set(uids), " ", items], timeout) do
      {:ok, {:ok, _, untagged}, conn} ->
        wanted = MapSet.new(uids)
        {:ok, for({:fetch, _, %{uid: uid} = m} <- untagged, uid in wanted, do: m), conn}

      other ->
        answer(other)
    end
  end

  @doc "Adds the Gmail label `label` to `uids` (Gmail creates a new one)."
  @spec label(t, [pos_integer], String.t()) :: {:ok, t} | {:error, error}
  def label(conn, [], _label), do: {:ok, conn}

  def label(conn, uids, label) do
    with {:ok, label} <- quoted(label) |> or_bad(conn, "label") do
      case command(conn, ["UID STORE ", set(uids), " +X-GM-LABELS (", label, ")"]) do
        {:ok, {:ok, _, _}, conn} -> {:ok, conn}
        other -> answer(other)
      end
    end
  end

  @doc """
  Starts an IDLE. The socket is the caller's in active-once mode until
  `done/1`; its data goes to `idle_data/2`. Answers any pushes that came
  before Gmail's go-ahead.
  """
  @spec idle(t) :: {:ok, [term], t} | {:error, error}
  def idle(conn) do
    tag = "h#{conn.tag + 1}"
    conn = %{conn | tag: conn.tag + 1}

    with :ok <- put(conn, [tag, " IDLE"]),
         {:ok, pushed, conn} <- until_continue(conn, []),
         :ok <- :ssl.setopts(conn.socket, active: :once) |> net(),
         {:ok, more, conn} <- complete(%{conn | idle: tag}, []) do
      {:ok, pushed ++ more, conn}
    end
  end

  defp until_continue(conn, acc) do
    case response(conn, conn.timeout) do
      {:ok, {:continue, _}, conn} -> {:ok, Enum.reverse(acc), conn}
      {:ok, {:untagged, {:bye, text}}, conn} -> fail(conn, {:bye, text})
      {:ok, {:untagged, u}, conn} -> until_continue(conn, [u | acc])
      {:ok, {:tagged, _, status, text}, conn} -> fail(conn, {status, text})
      {:error, reason} -> fail(conn, {:network, reason})
    end
  end

  @doc """
  Reads what an idle connection pushed (`{:ssl, socket, data}`): the
  complete responses so far, as `{:exists, n}`, `{:expunge, n}`,
  `{:bye, text}` and the like. Re-arms active-once.
  """
  @spec idle_data(t, binary) :: {:ok, [term], t} | {:error, error}
  def idle_data(%{idle: tag} = conn, data) when tag != nil do
    with {:ok, pushed, conn} <- complete(%{conn | buf: conn.buf <> data}, []),
         :ok <- :ssl.setopts(conn.socket, active: :once) |> net(),
         do: {:ok, pushed, conn}
  end

  # The responses whole in the buffer; a partial one waits for more data.
  defp complete(conn, acc) do
    if String.contains?(conn.buf, "\r\n") do
      case response(conn, 0) do
        {:ok, {:untagged, u}, conn} -> complete(conn, [u | acc])
        {:ok, _other, conn} -> complete(conn, acc)
        {:error, :timeout} -> {:ok, Enum.reverse(acc), conn}
        {:error, reason} -> {:error, {:network, reason}}
      end
    else
      {:ok, Enum.reverse(acc), conn}
    end
  end

  @doc "Ends an IDLE: the connection is passive again. Answers the pushes read meanwhile."
  @spec done(t) :: {:ok, [term], t} | {:error, error}
  def done(%{idle: tag, socket: socket} = conn) when tag != nil do
    with :ok <- :ssl.setopts(socket, active: false) |> net() do
      conn = drain(conn)

      with :ok <- put(conn, "DONE") do
        case collect(%{conn | idle: nil}, tag, [], conn.timeout) do
          {:ok, {:ok, _, pushed}, conn} -> {:ok, pushed, conn}
          other -> answer(other)
        end
      end
    end
  end

  # Data the socket delivered before it went passive comes first.
  defp drain(%{socket: socket} = conn) do
    receive do
      {:ssl, ^socket, data} -> drain(%{conn | buf: conn.buf <> data})
    after
      0 -> conn
    end
  end

  @doc "Logs out and closes; never fails."
  @spec logout(t) :: :ok
  def logout(%{socket: nil}), do: :ok

  def logout(conn) do
    if conn.idle == nil, do: put(conn, "h#{conn.tag + 1} LOGOUT")
    close(conn)
  end

  @doc "Closes the socket."
  @spec close(t) :: :ok
  def close(%{socket: nil}), do: :ok

  def close(%{socket: socket}) do
    :ssl.close(socket)
    :ok
  end

  # ------------------------------------------------------------ commands

  defp command(conn, cmd, timeout \\ nil) do
    tag = "h#{conn.tag + 1}"
    conn = %{conn | tag: conn.tag + 1}

    with :ok <- put(conn, [tag, " ", cmd]),
         do: collect(conn, tag, [], timeout || conn.timeout)
  end

  # A BYE before the tagged answer ends the connection: Gmail closes it.
  defp collect(conn, tag, acc, timeout) do
    case response(conn, timeout) do
      {:ok, {:tagged, ^tag, status, text}, conn} -> {:ok, {status, text, Enum.reverse(acc)}, conn}
      {:ok, {:untagged, {:bye, text}}, conn} -> fail(conn, {:bye, text})
      {:ok, {:untagged, u}, conn} -> collect(conn, tag, [u | acc], timeout)
      {:ok, _, conn} -> collect(conn, tag, acc, timeout)
      {:error, reason} -> fail(conn, {:network, reason})
    end
  end

  defp answer({:ok, {status, text, _}, conn}), do: fail(conn, {status, text})
  defp answer({:error, _} = e), do: e

  defp fail(conn, reason) do
    close(conn)
    {:error, reason}
  end

  defp put(conn, iodata), do: :ssl.send(conn.socket, [iodata, "\r\n"]) |> net()

  defp net(:ok), do: :ok
  defp net({:error, reason}), do: {:error, {:network, reason}}

  defp or_bad({:ok, _} = ok, _conn, _what), do: ok
  defp or_bad(:error, conn, what), do: fail(conn, {:bad, what})

  # A quoted string: no CR, LF or NUL can be in one.
  defp quoted(s) when is_binary(s) do
    if String.contains?(s, ["\r", "\n", <<0>>]),
      do: :error,
      else: {:ok, [?", s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\""), ?"]}
  end

  # A UID set, runs collapsed: 1,4:9,12.
  defp set(uids) do
    uids
    |> Enum.sort()
    |> Enum.dedup()
    |> Enum.chunk_while(
      nil,
      fn
        u, nil -> {:cont, {u, u}}
        u, {a, b} when u == b + 1 -> {:cont, {a, u}}
        u, run -> {:cont, run, {u, u}}
      end,
      fn run -> {:cont, run, nil} end
    )
    |> Enum.map_join(",", fn
      {a, a} -> Integer.to_string(a)
      {a, b} -> "#{a}:#{b}"
    end)
  end

  # ----------------------------------------------------------- responses

  # One response, with any literals it announces read in place. In the
  # line's text a literal stands as NUL, its index, NUL (IMAP text never
  # holds a NUL), and its bytes wait in a tuple until the parse takes them.
  defp response(conn, timeout) do
    with {:ok, text, lits, conn} <- logical(conn, [], [], timeout),
         do: {:ok, classify(text, List.to_tuple(Enum.reverse(lits))), conn}
  end

  defp logical(conn, parts, lits, timeout) do
    with {:ok, line, conn} <- line(conn, timeout) do
      found = if parts == [] and status_line?(line), do: nil, else: literal(line)

      case found do
        nil ->
          {:ok, IO.iodata_to_binary(Enum.reverse([line | parts])), lits, conn}

        {n, _} when n > @max_literal ->
          {:error, :too_large}

        {n, prefix} ->
          with {:ok, bytes, conn} <- take(conn, n, timeout),
               do:
                 logical(
                   conn,
                   [<<0, "#{length(lits)}", 0>>, prefix | parts],
                   [bytes | lits],
                   timeout
                 )
      end
    end
  end

  # A status response's text is free text: a `{n}` at its end is no literal.
  defp status_line?(line),
    do: line =~ ~r/\A(\*|[A-Za-z0-9.]+) (OK|NO|BAD|BYE|PREAUTH)( |\z)/i

  defp literal(line) do
    case Regex.run(~r/\{(\d{1,10})\+?\}\z/, line, return: :index) do
      [{at, _}, {d, len}] ->
        {String.to_integer(binary_part(line, d, len)), binary_part(line, 0, at)}

      nil ->
        nil
    end
  end

  defp line(conn, timeout) do
    case :binary.match(conn.buf, "\r\n",
           scope: {conn.scanned, byte_size(conn.buf) - conn.scanned}
         ) do
      {i, 2} ->
        <<line::binary-size(^i), "\r\n", rest::binary>> = conn.buf
        {:ok, line, %{conn | buf: rest, scanned: 0}}

      :nomatch when byte_size(conn.buf) > @max_line ->
        {:error, :too_large}

      :nomatch ->
        conn = %{conn | scanned: max(byte_size(conn.buf) - 1, 0)}

        case recv(conn, timeout) do
          {:ok, data} -> line(%{conn | buf: conn.buf <> data}, timeout)
          error -> error
        end
    end
  end

  defp take(conn, n, _timeout) when byte_size(conn.buf) >= n do
    <<bytes::binary-size(^n), rest::binary>> = conn.buf
    {:ok, bytes, %{conn | buf: rest, scanned: 0}}
  end

  defp take(conn, n, timeout) do
    case recv(conn, timeout) do
      {:ok, data} -> take(%{conn | buf: conn.buf <> data}, n, timeout)
      error -> error
    end
  end

  # An idle connection is the owner's to read; the buffer alone is parsed.
  defp recv(%{idle: tag}, _timeout) when tag != nil, do: {:error, :timeout}
  defp recv(conn, timeout), do: :ssl.recv(conn.socket, 0, timeout)

  defp classify("+" <> text, _lits), do: {:continue, String.trim(text)}

  defp classify("* " <> text, lits), do: {:untagged, untagged(text, lits)}

  defp classify(text, _lits) do
    case String.split(text, " ", parts: 3) do
      [tag, status, rest] -> {:tagged, tag, status(status), rest}
      [tag, status] -> {:tagged, tag, status(status), ""}
      _ -> {:untagged, {:other, text}}
    end
  end

  defp status(s) do
    case String.upcase(s) do
      "OK" -> :ok
      "NO" -> :no
      _ -> :bad
    end
  end

  defp untagged(text, lits) do
    case String.split(text, " ", parts: 2) do
      [word, rest] -> untagged(String.upcase(word), rest, lits)
      [word] -> untagged(String.upcase(word), "", lits)
    end
  end

  defp untagged("BYE", rest, _), do: {:bye, String.trim(rest)}

  defp untagged(s, rest, _) when s in ["OK", "NO", "BAD"],
    do: {:status, status(s), code(rest), rest}

  defp untagged("CAPABILITY", rest, _), do: {:capability, String.split(rest)}

  defp untagged("SEARCH", rest, _),
    do: {:search, rest |> String.split() |> Enum.flat_map(&uint/1)}

  defp untagged("LIST", rest, lits) do
    case parse(rest, lits) do
      [flags, _delim, name | _] when is_list(flags) and is_binary(name) ->
        {:list, for(f <- flags, is_binary(f), do: String.downcase(f)), name}

      _ ->
        {:other, rest}
    end
  end

  defp untagged(word, rest, lits) do
    with [n] <- uint(word),
         [what | data] <- String.split(rest, " ", parts: 2) do
      numbered(n, String.upcase(what), data, lits)
    else
      _ -> {:other, word <> " " <> rest}
    end
  end

  defp numbered(n, "EXISTS", _, _), do: {:exists, n}
  defp numbered(n, "EXPUNGE", _, _), do: {:expunge, n}
  defp numbered(n, "RECENT", _, _), do: {:recent, n}

  defp numbered(n, "FETCH", [data], lits) do
    case parse(data, lits) do
      [items | _] when is_list(items) -> {:fetch, n, fetched(items, %{})}
      _ -> {:other, data}
    end
  end

  defp numbered(n, what, _, _), do: {:other, "#{n} #{what}"}

  # A response code: [UIDVALIDITY 1] -> {"UIDVALIDITY", "1"}.
  defp code("[" <> rest) do
    case :binary.split(rest, "]") do
      [inner, _] ->
        case String.split(inner, " ", parts: 2) do
          [name, value] -> {String.upcase(name), value}
          [name] -> {String.upcase(name), nil}
        end

      _ ->
        nil
    end
  end

  defp code(_), do: nil

  defp fetched([k, v | rest], acc) when is_binary(k),
    do: fetched(rest, item(String.upcase(k), v, acc))

  defp fetched(_, acc), do: acc

  defp item("UID", v, acc), do: put_int(acc, :uid, v)
  defp item("X-GM-MSGID", v, acc), do: put_int(acc, :msgid, v)
  defp item("X-GM-THRID", v, acc), do: put_int(acc, :thrid, v)
  defp item("RFC822.SIZE", v, acc), do: put_int(acc, :size, v)

  defp item("X-GM-LABELS", v, acc) when is_list(v),
    do: Map.put(acc, :labels, Enum.filter(v, &is_binary/1))

  defp item("INTERNALDATE", v, acc) when is_binary(v), do: Map.put(acc, :internaldate, date(v))
  defp item("BODY[]", v, acc), do: Map.put(acc, :raw, v || "")
  defp item("BODY[HEADER" <> _, v, acc), do: Map.put(acc, :header, v || "")
  defp item(_, _, acc), do: acc

  defp put_int(acc, key, v) do
    case int(v) do
      nil -> acc
      n -> Map.put(acc, key, n)
    end
  end

  defp int(v) when is_binary(v) do
    case uint(v) do
      [n] -> n
      [] -> nil
    end
  end

  defp int(_), do: nil

  defp uint(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> [n]
      _ -> []
    end
  end

  # INTERNALDATE: "22-Oct-2026 08:12:01 +0000" -> unix seconds.
  defp date(s) do
    with [_, d, mon, y, h, mi, sec, sign, zh, zm] <-
           Regex.run(
             ~r/\A\s?(\d{1,2})-(\w{3})-(\d{4}) (\d\d):(\d\d):(\d\d) ([+-])(\d\d)(\d\d)\z/,
             s
           ),
         m when m != nil <- Enum.find_index(@months, &(&1 == mon)),
         {:ok, naive} <-
           NaiveDateTime.new(
             String.to_integer(y),
             m + 1,
             String.to_integer(d),
             String.to_integer(h),
             String.to_integer(mi),
             String.to_integer(sec)
           ) do
      offset = (String.to_integer(zh) * 60 + String.to_integer(zm)) * 60
      utc = naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
      if sign == "+", do: utc - offset, else: utc + offset
    else
      _ -> nil
    end
  end

  # IMAP data as terms: lists, binaries (atoms, quoted strings and literals
  # alike) and nil for NIL. A `[...]` inside an atom belongs to it, spaces
  # and parentheses included: BODY[HEADER.FIELDS (FROM TO)].
  defp parse(text, lits) do
    {terms, _rest} = items(text, lits, [])
    terms
  end

  defp items(<<>>, _lits, acc), do: {Enum.reverse(acc), <<>>}
  defp items(<<?\s, rest::binary>>, lits, acc), do: items(rest, lits, acc)
  defp items(<<?), rest::binary>>, _lits, acc), do: {Enum.reverse(acc), rest}

  defp items(<<?(, rest::binary>>, lits, acc) do
    {list, rest} = items(rest, lits, [])
    items(rest, lits, [list | acc])
  end

  defp items(<<?", rest::binary>>, lits, acc) do
    {s, rest} = string(rest, [])
    items(rest, lits, [s | acc])
  end

  defp items(<<0, rest::binary>>, lits, acc) do
    case :binary.split(rest, <<0>>) do
      [i, rest] -> items(rest, lits, [lit(lits, i) | acc])
      [_] -> {Enum.reverse(acc), <<>>}
    end
  end

  defp items(text, lits, acc) do
    case atom(text, 0, 0) do
      {"", <<_, rest::binary>>} ->
        items(rest, lits, acc)

      {atom, rest} ->
        items(rest, lits, [if(String.upcase(atom) == "NIL", do: nil, else: atom) | acc])
    end
  end

  defp lit(lits, i) do
    case Integer.parse(i) do
      {n, ""} when n < tuple_size(lits) -> elem(lits, n)
      _ -> nil
    end
  end

  defp string(<<?\\, c, rest::binary>>, acc), do: string(rest, [c | acc])

  defp string(<<?", rest::binary>>, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp string(<<c, rest::binary>>, acc), do: string(rest, [c | acc])
  defp string(<<>>, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), <<>>}

  defp atom(text, i, depth) when i < byte_size(text) do
    case :binary.at(text, i) do
      c when depth == 0 and c in [?\s, ?(, ?), 0] -> split_at(text, i)
      ?[ when depth > 0 -> atom(text, i + 1, depth + 1)
      ?[ -> atom(text, i + 1, if(section?(binary_part(text, 0, i)), do: 1, else: 0))
      ?] when depth > 0 -> atom(text, i + 1, depth - 1)
      _ -> atom(text, i + 1, depth)
    end
  end

  defp atom(text, i, _depth), do: split_at(text, i)

  # Only a fetch item's section (BODY[...]) holds spaces and parentheses
  # inside brackets; a label like [Archive is a plain atom.
  defp section?(prefix),
    do: String.upcase(prefix) in ["BODY", "BODY.PEEK", "BINARY", "BINARY.PEEK", "BINARY.SIZE"]

  defp split_at(text, i), do: {binary_part(text, 0, i), binary_part(text, i, byte_size(text) - i)}
end
