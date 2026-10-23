defmodule Hireme.FakeGmail do
  @moduledoc ~S"""
  A local fake Gmail for the Gmail connector's tests: the IMAP and SMTP
  subset the connector speaks, over implicit TLS as imap.gmail.com:993 and
  smtp.gmail.com:465 serve it, with Gmail's X-GM-EXT-1 items and Gmail's
  wording. One account and one mailbox: All Mail holds every message, and
  INBOX, the other system folders and each user label are views of it that
  share its UIDs (real Gmail numbers each folder apart; the connector reads
  All Mail only). It uses nothing beyond Elixir and OTP, so it also runs
  standalone.

      {:ok, fake} = Hireme.FakeGmail.start()
      uid = Hireme.FakeGmail.deliver(fake, raw)

  ## Options of `start/1`

    * `:imap_port`, `:smtp_port`: 0 (the default) takes a free port.
    * `:user` (`"someone@gmail.com"`, matched without case) and `:password`
      (`"abcdefghijklmnop"`; spaces are ignored, as Gmail ignores them in an
      app password).
    * `:tls`: `:test_ca` (the default) makes a CA and a certificate for
      localhost (DNS:localhost, IP:127.0.0.1) and answers the CA in
      `cacerts`; `[certfile: path, keyfile: path]` serves those PEM files
      (and `cacerts` is empty).
    * `:all_mail`: All Mail's name (`"[Gmail]/All Mail"`). Gmail localizes
      it, so a client finds it by `\All`; the other system folders take its
      prefix.
    * `:uidvalidity` (1), `:ip` (127.0.0.1).
    * `:spool`: a directory that drives the fake (see Standalone).

  The fake stops when the process that started it exits.

  ## Failures

  `fail/2` turns a mode on until `heal/1`; modes add up.

    * `:imap_disabled`: a right LOGIN answers that IMAP is off for the account.
    * `{:smtp_reply, reply}`: the end of DATA is answered with `reply` and
      nothing is stored; a 421 also closes the connection.
    * `:smtp_drop_after_data`: the message is accepted (in `sent/1`, and in
      All Mail with `\Sent`), then the connection closes with no reply: the
      window a sender must survive without sending twice.

  A wrong password is always refused. `down/1` closes both listeners and
  every connection; `up/1` listens again on the same ports.

  ## What it serves

  IMAP: LOGIN, CAPABILITY, LOGOUT, LIST, SELECT, IDLE, and the UID forms of
  SEARCH (UID, SINCE, `X-GM-RAW "rfc822msgid:<id>"`), FETCH (UID,
  X-GM-MSGID, X-GM-THRID, X-GM-LABELS, INTERNALDATE, RFC822.SIZE, BODY[] and
  BODY[HEADER.FIELDS (...)], each also as BODY.PEEK; BODY without PEEK marks
  the message `\Seen`) and STORE +X-GM-LABELS. Anything else is `BAD`.
  Before login, CAPABILITY lists what Gmail lists then (none of UIDPLUS,
  MOVE, CONDSTORE or LITERAL-); a login answers the full list untagged, as
  Gmail does. SMTP: EHLO, AUTH PLAIN with its initial response, MAIL, RCPT,
  DATA, QUIT, each refused out of order in Gmail's words.

  ## Standalone

      elixir -r test/support/fake_gmail.ex -e 'Hireme.FakeGmail.main(System.argv())' -- \
        --imap-port 993 --smtp-port 465 --cert cert.pem --key key.pem \
        --user someone@gmail.com --password abcdefghijklmnop --spool /tmp/spool \
        [--all-mail NAME] [--ip ADDRESS]

  It listens on every address (or `--ip`), prints one line once listening,
  and blocks. Without `--cert` and `--key` it makes a localhost CA and writes
  it to `<spool>/ca.pem`. The spool directory is the only control channel:

    * `inbox/`: each new regular file, a raw message, is delivered once with
      `\Inbox` and moved to `inbox/done/`. The directory is polled every
      200 ms and a file is taken once its size and mtime held over two polls;
      names starting with a dot are skipped, so write `.name` and rename it.
    * `sent/`: each message SMTP accepted, as `<n>.eml` and `<n>.json`
      (`{"from", "rcpts", "at"}`), n counting from 1.
    * `state.json`: All Mail as `[{"uid", "msgid", "thrid", "labels",
      "message_id"}]`, rewritten on every change.

  Every spool file is written under a dot name and renamed into place.
  """

  use GenServer

  @caps_before "IMAP4rev1 UNSELECT IDLE NAMESPACE QUOTA ID XLIST CHILDREN X-GM-EXT-1 XYZZY SASL-IR AUTH=XOAUTH2 AUTH=PLAIN AUTH=PLAIN-CLIENTTOKEN AUTH=OAUTHBEARER AUTH=XOAUTH"
  @caps "IMAP4rev1 UNSELECT IDLE NAMESPACE QUOTA ID XLIST CHILDREN X-GM-EXT-1 UIDPLUS COMPRESS=DEFLATE ENABLE MOVE CONDSTORE ESEARCH UTF8=ACCEPT LIST-EXTENDED LIST-STATUS LITERAL- SPECIAL-USE APPENDLIMIT=35651584"
  @flags ~S"\Answered \Flagged \Draft \Deleted \Seen $NotPhishing $Phishing"
  @auth_failed "[AUTHENTICATIONFAILED] Invalid credentials (Failure)"
  @imap_disabled "[ALERT] Your account is not enabled for IMAP use. Please visit your Gmail settings page and enable your account for IMAP access. (Failure)"
  @bad_credentials "535-5.7.8 Username and Password not accepted. For more information, go to\r\n535 5.7.8  https://support.google.com/mail/?p=BadCredentials x - gsmtp"
  @auth_required "530-5.7.0 Authentication Required. For more information, go to\r\n530 5.7.0  https://support.google.com/mail/?p=WantAuthError x - gsmtp"
  @modes [:imap_disabled, :smtp_drop_after_data]
  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)
  # Gmail does not answer FETCH items in the order asked, nor with UID first.
  @fetch_order [:thrid, :msgid, :labels, :uid, :flags, :internaldate, :size]

  ## API

  @doc """
  Starts a fake owned by the caller (options in the moduledoc):
  `{:ok, %{pid: pid, imap_port: port, smtp_port: port, cacerts: [der]}}`.
  """
  def start(opts \\ []) do
    with {:ok, pid} <- GenServer.start(__MODULE__, {opts, self()}),
         do: {:ok, GenServer.call(pid, :info)}
  end

  @doc """
  An inbound mail arriving: appended to All Mail with `labels` (new user
  labels are made on the fly), the next UID, a fresh X-GM-MSGID, and the
  X-GM-THRID of the message its In-Reply-To or References names (else its
  own X-GM-MSGID). IDLE-ing clients hear `* n EXISTS` at once. `opts`:
  `:date` (a DateTime, the INTERNALDATE; now by default) and `:flags` ([]).
  Answers the UID.
  """
  def deliver(fake, raw, labels \\ ["\\Inbox"], opts \\ []),
    do: call(fake, {:deliver, IO.iodata_to_binary(raw), labels, opts})

  @doc """
  Every message in UID order: `[%{uid, msgid, thrid, labels, flags,
  internaldate, raw, message_id}]`; `message_id` has no brackets.
  """
  def messages(fake), do: call(fake, :messages)

  @doc "Every message SMTP accepted, oldest first: `[%{from, rcpts, raw, at}]`."
  def sent(fake), do: call(fake, :sent)

  @doc "Every login attempt, oldest first: `[%{proto: :imap | :smtp, user, ok, at}]`."
  def logins(fake), do: call(fake, :logins)

  @doc "Turns a failure mode on (the modes are in the moduledoc)."
  def fail(fake, {:smtp_reply, reply}) when is_binary(reply),
    do: call(fake, {:fail, :smtp_reply, String.trim_trailing(reply, "\r\n")})

  def fail(fake, mode) when mode in @modes, do: call(fake, {:fail, mode, true})

  @doc "Turns every failure mode off."
  def heal(fake), do: call(fake, :heal)

  @doc "Closes both listeners and every open connection: connecting is refused until `up/1`."
  def down(fake), do: call(fake, :down)

  @doc "Listens again on the same ports: `:ok` or `{:error, reason}`."
  def up(fake), do: call(fake, :up)

  @doc "Stops the fake, closing everything; a fake already gone is fine."
  def stop(fake) do
    GenServer.stop(pid(fake))
  catch
    :exit, _ -> :ok
  end

  @doc "Standalone mode: parses the flags in the moduledoc, starts a fake and blocks."
  def main(argv) do
    strings = for f <- ~w(cert key user password spool all_mail ip)a, do: {f, :string}
    strict = [imap_port: :integer, smtp_port: :integer] ++ strings
    {opts, rest, invalid} = OptionParser.parse(argv, strict: strict)
    ip = :inet.parse_address(to_charlist(opts[:ip] || "0.0.0.0"))

    if rest != [] or invalid != [] or opts[:spool] == nil or match?({:error, _}, ip) or
         is_nil(opts[:cert]) != is_nil(opts[:key]) do
      IO.puts(:stderr, "usage: the Standalone section of Hireme.FakeGmail's moduledoc")
      System.halt(2)
    end

    tls = if opts[:cert], do: [certfile: opts[:cert], keyfile: opts[:key]], else: :test_ca
    ports = [imap_port: opts[:imap_port] || 993, smtp_port: opts[:smtp_port] || 465]
    keep = Keyword.take(opts, [:user, :password, :all_mail, :spool])

    case start(ports ++ [tls: tls, ip: elem(ip, 1)] ++ keep) do
      {:ok, fake} ->
        pem =
          :public_key.pem_encode(for der <- fake.cacerts, do: {:Certificate, der, :not_encrypted})

        if tls == :test_ca, do: File.write!(Path.join(opts[:spool], "ca.pem"), pem)

        IO.puts(
          "fake gmail: imap #{fake.imap_port}, smtp #{fake.smtp_port}, spool #{opts[:spool]}"
        )

        Process.sleep(:infinity)

      {:error, reason} ->
        IO.puts(:stderr, "fake gmail: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp pid(%{pid: pid}), do: pid
  defp pid(pid) when is_pid(pid), do: pid

  defp call(fake, msg), do: GenServer.call(pid(fake), msg)

  ## The mailbox

  @impl true
  def init({opts, owner}) do
    {:ok, _} = Application.ensure_all_started(:ssl)
    Process.monitor(owner)
    {tls, cacerts} = tls(Keyword.get(opts, :tls, :test_ca))
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})

    s = %{
      owner: owner,
      user: Keyword.get(opts, :user, "someone@gmail.com"),
      password: Keyword.get(opts, :password, "abcdefghijklmnop"),
      all_mail: Keyword.get(opts, :all_mail, "[Gmail]/All Mail"),
      uidvalidity: Keyword.get(opts, :uidvalidity, 1),
      imap_port: Keyword.get(opts, :imap_port, 0),
      smtp_port: Keyword.get(opts, :smtp_port, 0),
      ssl: [:binary, active: false, reuseaddr: true, ip: ip, versions: [:"tlsv1.3", :"tlsv1.2"]],
      cacerts: cacerts,
      spool: opts[:spool],
      listeners: [],
      conns: %{},
      msgs: [],
      uidnext: 1,
      modseq: 1,
      last_msgid: 0,
      user_labels: MapSet.new(),
      sent: [],
      logins: [],
      fails: %{},
      inbox_sizes: %{}
    }

    case listen(%{s | ssl: s.ssl ++ tls}) do
      {:ok, s} -> {:ok, spool_open(s)}
      {:error, reason} -> {:stop, reason}
    end
  end

  # The certificate must be signed with SHA-256: OTP's test default is SHA-1,
  # which TLS 1.3 (and OTP's TLS 1.2 defaults) refuse.
  defp tls(:test_ca) do
    san = {:Extension, {2, 5, 29, 17}, false, dNSName: ~c"localhost", iPAddress: <<127, 0, 0, 1>>}
    key = [key: {:namedCurve, :secp256r1}, digest: :sha256]

    conf =
      :public_key.pkix_test_data(%{
        root: key,
        intermediates: [],
        peer: [{:extensions, [san]} | key]
      })

    {[cert: conf[:cert], key: conf[:key]], Enum.uniq(conf[:cacerts])}
  end

  defp tls(files),
    do: {[certfile: to_charlist(files[:certfile]), keyfile: to_charlist(files[:keyfile])], []}

  defp listen(s) do
    with {:ok, imap} <- :ssl.listen(s.imap_port, s.ssl) do
      case :ssl.listen(s.smtp_port, s.ssl) do
        {:ok, smtp} ->
          me = self()
          listeners = [imap: imap, smtp: smtp]
          for {proto, l} <- listeners, do: spawn(fn -> accept(me, l, proto) end)

          [imap_port, smtp_port] =
            for {_, l} <- listeners, {:ok, {_, port}} <- [:ssl.sockname(l)], do: port

          {:ok, %{s | imap_port: imap_port, smtp_port: smtp_port, listeners: [imap, smtp]}}

        error ->
          :ssl.close(imap)
          error
      end
    end
  end

  # A closed listener ends its acceptor; so does any other error, rather
  # than spinning on it.
  defp accept(server, listener, proto) do
    with {:ok, socket} <- :ssl.transport_accept(listener) do
      pid = spawn(fn -> connection(server, proto) end)
      _ = :ssl.controlling_process(socket, pid)
      send(pid, {:socket, socket})
      accept(server, listener, proto)
    end
  end

  defp close_all(s) do
    Enum.each(s.listeners, &:ssl.close/1)
    Enum.each(Map.keys(s.conns), &Process.exit(&1, :kill))
    %{s | listeners: [], conns: %{}}
  end

  @impl true
  def handle_call(:info, _from, s),
    do:
      {:reply, %{pid: self(), imap_port: s.imap_port, smtp_port: s.smtp_port, cacerts: s.cacerts},
       s}

  def handle_call({:join, _proto}, _from, %{listeners: []} = s), do: {:reply, :down, s}

  def handle_call({:join, proto}, {pid, _}, s) do
    Process.monitor(pid)
    {:reply, :ok, %{s | conns: Map.put(s.conns, pid, proto)}}
  end

  def handle_call({:deliver, raw, labels, opts}, _from, s) do
    date = DateTime.from_unix!(DateTime.to_unix(opts[:date] || DateTime.utc_now()))
    {uid, s} = append(s, raw, labels, date, Keyword.get(opts, :flags, []))
    {:reply, uid, s}
  end

  def handle_call(:messages, _from, s), do: {:reply, s.msgs, s}
  def handle_call(:sent, _from, s), do: {:reply, Enum.reverse(s.sent), s}
  def handle_call(:logins, _from, s), do: {:reply, Enum.reverse(s.logins), s}

  def handle_call({:fail, mode, v}, _from, s),
    do: {:reply, :ok, %{s | fails: Map.put(s.fails, mode, v)}}

  def handle_call(:heal, _from, s), do: {:reply, :ok, %{s | fails: %{}}}
  def handle_call(:down, _from, s), do: {:reply, :ok, close_all(s)}

  def handle_call(:up, _from, %{listeners: []} = s) do
    case listen(s) do
      {:ok, s} -> {:reply, :ok, s}
      error -> {:reply, error, s}
    end
  end

  def handle_call(:up, _from, s), do: {:reply, :ok, s}

  def handle_call({:login, proto, user, password}, _from, s) do
    right =
      String.downcase(user) == String.downcase(s.user) and
        String.replace(password, " ", "") == String.replace(s.password, " ", "")

    verdict =
      cond do
        not right -> {:no, if(proto == :smtp, do: @bad_credentials, else: @auth_failed)}
        proto == :imap and s.fails[:imap_disabled] -> {:no, @imap_disabled}
        true -> {:ok, s.user}
      end

    at = DateTime.utc_now(:second)
    entry = %{proto: proto, user: user, ok: match?({:ok, _}, verdict), at: at}
    {:reply, verdict, %{s | logins: [entry | s.logins]}}
  end

  def handle_call(:folders, _from, s), do: {:reply, folders(s), s}

  # A selectable folder by its name: its name as listed, its messages
  # numbered from 1, and what SELECT reports; nil for no such folder.
  def handle_call({:view, name}, _from, s) do
    reported = Map.take(s, [:uidvalidity, :uidnext, :modseq])

    reply =
      with {folder, filter} <- folder(s, name),
           do: Map.merge(reported, %{name: folder, msgs: view(s, filter)})

    {:reply, reply, s}
  end

  # Adds `values` to each message's labels or flags; answers the messages
  # changed, as the folder `name` numbers them.
  def handle_call({:store, name, uids, field, values}, _from, s) do
    add = fn m -> %{m | field => Enum.sort(Enum.uniq(Map.fetch!(m, field) ++ values))} end
    msgs = for m <- s.msgs, do: if(m.uid in uids, do: add.(m), else: m)
    labels = if field == :labels, do: add_user_labels(s.user_labels, values), else: s.user_labels
    s = spool_state(%{s | msgs: msgs, modseq: s.modseq + 1, user_labels: labels})
    {_, filter} = folder(s, name)
    {:reply, for(m <- view(s, filter), m.uid in uids, do: m), s}
  end

  def handle_call({:smtp_data, _, _, _}, _from, %{fails: %{smtp_reply: reply}} = s),
    do: {:reply, {:reply, reply}, s}

  def handle_call({:smtp_data, from, rcpts, raw}, _from, s) do
    at = DateTime.utc_now(:second)
    entry = %{from: from, rcpts: rcpts, raw: raw, at: at}
    s = %{s | sent: [entry | s.sent]}
    spool_sent(s.spool, length(s.sent), entry)
    # Gmail files what it sends in All Mail, as read and with a Message-ID
    # of its own when the sender gave none.
    {_uid, s} = append(s, with_message_id(raw), ["\\Sent"], at, ["\\Seen"])
    {:reply, if(s.fails[:smtp_drop_after_data], do: :drop, else: {:ok, DateTime.to_unix(at)}), s}
  end

  @impl true
  def handle_info({:DOWN, _, :process, pid, _}, %{owner: pid} = s), do: {:stop, :normal, s}

  def handle_info({:DOWN, _, :process, pid, _}, s),
    do: {:noreply, %{s | conns: Map.delete(s.conns, pid)}}

  def handle_info(:poll, s) do
    Process.send_after(self(), :poll, 200)
    {:noreply, spool_inbox(s)}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s), do: close_all(s)

  defp append(s, raw, labels, date, flags) do
    # Gmail's X-GM-MSGIDs grow with time: about 1.9e18 in 2026, inside an i64.
    msgid = max(s.last_msgid + 1, System.os_time(:millisecond) * 1_048_576)
    labels = labels |> Enum.uniq() |> Enum.sort()

    m = %{
      uid: s.uidnext,
      msgid: msgid,
      thrid: thread(s.msgs, raw) || msgid,
      labels: labels,
      flags: flags |> Enum.uniq() |> Enum.sort(),
      internaldate: date,
      raw: raw,
      message_id: message_id(raw)
    }

    s = %{
      s
      | msgs: s.msgs ++ [m],
        uidnext: s.uidnext + 1,
        last_msgid: msgid,
        modseq: s.modseq + 1,
        user_labels: add_user_labels(s.user_labels, labels)
    }

    for {pid, :imap} <- s.conns, do: send(pid, {__MODULE__, :changed})
    {m.uid, spool_state(s)}
  end

  # In-Reply-To first, then References from the nearest parent back.
  defp thread(msgs, raw) do
    fields = fields(raw)
    refs = ids(field(fields, "in-reply-to")) ++ Enum.reverse(ids(field(fields, "references")))

    Enum.find_value(refs, fn id ->
      id = String.downcase(id)
      Enum.find_value(msgs, &(&1.message_id && String.downcase(&1.message_id) == id && &1.thrid))
    end)
  end

  defp with_message_id(raw) do
    id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    if message_id(raw), do: raw, else: "Message-ID: <#{id}@mx.google.com>\r\n" <> raw
  end

  defp add_user_labels(set, labels),
    do: labels |> Enum.reject(&String.starts_with?(&1, "\\")) |> Enum.into(set)

  # Every folder as {name, LIST attributes, view}; INBOX first, the rest by name.
  defp folders(s) do
    prefix =
      case String.split(s.all_mail, "/", parts: 2) do
        [prefix, _] -> prefix
        [_] -> "[Gmail]"
      end

    system = [
      {prefix, ~W(\HasChildren \Noselect), :none},
      {s.all_mail, ~W(\All \HasNoChildren), :all},
      {prefix <> "/Drafts", ~W(\Drafts \HasNoChildren), {:has, "\\Draft"}},
      {prefix <> "/Important", ~W(\HasNoChildren \Important), {:has, "\\Important"}},
      {prefix <> "/Sent Mail", ~W(\HasNoChildren \Sent), {:has, "\\Sent"}},
      {prefix <> "/Spam", ~W(\HasNoChildren \Junk), {:has, "\\Spam"}},
      {prefix <> "/Starred", ~W(\Flagged \HasNoChildren), {:has, "\\Starred"}},
      {prefix <> "/Trash", ~W(\HasNoChildren \Trash), {:has, "\\Trash"}}
    ]

    user = for l <- s.user_labels, do: {l, ~W(\HasNoChildren), {:has, l}}
    [{"INBOX", ~W(\HasNoChildren), {:has, "\\Inbox"}} | Enum.sort(system ++ user)]
  end

  # A selectable folder by its name: {its name as listed, view}.
  defp folder(s, name) do
    Enum.find_value(folders(s), fn {folder, _, filter} ->
      if filter != :none and
           (folder == name or (folder == "INBOX" and String.upcase(name) == "INBOX")),
         do: {folder, filter}
    end)
  end

  # All Mail leaves out spam and trash, as Gmail's does.
  defp view(s, filter) do
    for {m, seq} <- Enum.with_index(Enum.filter(s.msgs, &visible?(&1, filter)), 1),
        do: Map.put(m, :seq, seq)
  end

  defp visible?(m, :all), do: "\\Spam" not in m.labels and "\\Trash" not in m.labels
  defp visible?(m, {:has, label}), do: label in m.labels

  ## Spool

  defp spool_open(%{spool: nil} = s), do: s

  defp spool_open(s) do
    File.mkdir_p!(Path.join([s.spool, "inbox", "done"]))
    File.mkdir_p!(Path.join(s.spool, "sent"))
    send(self(), :poll)
    spool_state(s)
  end

  defp spool_state(%{spool: nil} = s), do: s

  defp spool_state(s) do
    rows = for m <- s.msgs, do: Map.take(m, [:uid, :msgid, :thrid, :labels, :message_id])
    spool_write(Path.join(s.spool, "state.json"), JSON.encode!(rows))
    s
  end

  defp spool_sent(nil, _n, _entry), do: :ok

  defp spool_sent(dir, n, entry) do
    spool_write(Path.join([dir, "sent", "#{n}.eml"]), entry.raw)
    json = %{entry | at: DateTime.to_iso8601(entry.at)} |> Map.delete(:raw) |> JSON.encode!()
    spool_write(Path.join([dir, "sent", "#{n}.json"]), json)
  end

  defp spool_write(path, data) do
    tmp = Path.join(Path.dirname(path), "." <> Path.basename(path))
    File.write!(tmp, data)
    File.rename!(tmp, path)
  end

  # A file is taken once its size and mtime held over two polls, so one
  # still being written is not read half way.
  defp spool_inbox(s) do
    inbox = Path.join(s.spool, "inbox")
    {:ok, names} = with {:error, _} <- File.ls(inbox), do: {:ok, []}

    sizes =
      for name <- names,
          not String.starts_with?(name, "."),
          {:ok, %File.Stat{type: :regular} = stat} <- [File.stat(Path.join(inbox, name))],
          into: %{},
          do: {name, {stat.size, stat.mtime}}

    ready = for {name, size} <- sizes, s.inbox_sizes[name] == size, do: name
    s = Enum.reduce(Enum.sort(ready), s, &spool_deliver(&2, inbox, &1))
    %{s | inbox_sizes: Map.drop(sizes, ready)}
  end

  defp spool_deliver(s, inbox, name) do
    path = Path.join(inbox, name)

    case File.read(path) do
      {:ok, raw} ->
        {_uid, s} = append(s, raw, ["\\Inbox"], DateTime.utc_now(:second), [])
        File.mkdir_p!(Path.join(inbox, "done"))
        File.rename!(path, Path.join([inbox, "done", name]))
        s

      {:error, _} ->
        s
    end
  end

  ## Connections

  defp connection(server, proto) do
    receive do
      {:socket, socket} ->
        with :ok <- join(server, proto),
             {:ok, socket} <- :ssl.handshake(socket, 15_000) do
          c = %{sock: socket, server: server, peer: peer(socket), buf: ""}
          if proto == :imap, do: imap_session(c), else: smtp_session(c)
        else
          _ -> :ssl.close(socket)
        end
    after
      15_000 -> :ok
    end
  end

  defp join(server, proto) do
    GenServer.call(server, {:join, proto})
  catch
    :exit, _ -> :down
  end

  defp peer(socket) do
    case :ssl.peername(socket) do
      {:ok, {ip, _port}} -> to_string(:inet.ntoa(ip))
      _ -> "127.0.0.1"
    end
  end

  defp write(c, iodata), do: :ssl.send(c.sock, [iodata, "\r\n"])

  # A connection's loop: each CRLF-ended line goes to `line`, which answers
  # {:ok, c} or :stop; a change to the mailbox reaches an IDLE at once.
  defp loop(c, line) do
    with :ok <- :ssl.setopts(c.sock, active: :once) do
      receive do
        {:ssl, _, data} ->
          with {:ok, c} <- lines(%{c | buf: c.buf <> data}, line), do: loop(c, line)

        {__MODULE__, :changed} ->
          loop(if(c.idle, do: flush(c), else: c), line)

        {:ssl_closed, _} ->
          :ok

        {:ssl_error, _, _} ->
          :ok
      end
    end
  end

  defp lines(c, line) do
    case :binary.split(c.buf, "\r\n") do
      [_] -> {:ok, c}
      [text, rest] -> with {:ok, c} <- line.(text, %{c | buf: rest}), do: lines(c, line)
    end
  end

  ## IMAP

  defp imap_session(c) do
    c = Map.merge(c, %{authed: nil, sel: nil, reported: 0, idle: nil})
    write(c, "* OK Gimap ready for requests from #{c.peer}")
    loop(c, &imap_line/2)
  end

  # During IDLE the next line is bare; otherwise it is a command.
  defp imap_line(line, %{idle: tag} = c) when tag != nil do
    c = %{c | idle: nil}

    if String.upcase(String.trim(line)) == "DONE",
      do: reply(tag, {:ok, "IDLE terminated (Success)", c}),
      else: reply(tag, {:bad, "Could not parse command", c})
  end

  defp imap_line(line, c), do: command(lex(line, []), c)

  defp lex(<<>>, acc), do: Enum.reverse(acc)
  defp lex(<<?\s, rest::binary>>, acc), do: lex(rest, acc)
  defp lex(<<?(, rest::binary>>, acc), do: lex(rest, [:lp | acc])
  defp lex(<<?), rest::binary>>, acc), do: lex(rest, [:rp | acc])

  defp lex(<<?", rest::binary>>, acc) do
    case quoted(rest, <<>>) do
      {s, rest} -> lex(rest, [{:str, s} | acc])
      :error -> Enum.reverse([:error | acc])
    end
  end

  defp lex(bin, acc) do
    case word(bin, <<>>) do
      {w, rest} -> lex(rest, [{:atom, w} | acc])
      :error -> Enum.reverse([:error | acc])
    end
  end

  defp quoted(<<?\\, ch, rest::binary>>, acc), do: quoted(rest, <<acc::binary, ch>>)
  defp quoted(<<?", rest::binary>>, acc), do: {acc, rest}
  defp quoted(<<ch, rest::binary>>, acc), do: quoted(rest, <<acc::binary, ch>>)
  defp quoted(<<>>, _acc), do: :error

  # A [section] is read whole: BODY.PEEK[HEADER.FIELDS (FROM TO)] is one word.
  defp word(<<ch, _::binary>> = rest, acc) when ch in [?\s, ?(, ?)], do: {acc, rest}

  defp word(<<?[, rest::binary>>, acc) do
    case :binary.split(rest, "]") do
      [inside, rest] -> word(rest, <<acc::binary, ?[, inside::binary, ?]>>)
      [_] -> :error
    end
  end

  defp word(<<ch, rest::binary>>, acc), do: word(rest, <<acc::binary, ch>>)
  defp word(<<>>, acc), do: {acc, <<>>}

  defp command([], c), do: {:ok, c}

  defp command([{:atom, tag} | args], c) do
    {name, args} = command_name(args)

    reply(tag, run(name, tag, args, c))
  end

  defp command(_toks, c) do
    write(c, "* BAD Could not parse command")
    {:ok, c}
  end

  defp command_name([{:atom, name} | args]) do
    case {String.upcase(name), args} do
      {"UID", [{:atom, sub} | args]} -> {"UID " <> String.upcase(sub), args}
      {name, args} -> {name, args}
    end
  end

  defp command_name(args), do: {"", args}

  defp run(name, tag, args, c) do
    if name == "LOGIN" and c.authed, do: throw({:bad, "Already authenticated"})

    if name not in ~w(CAPABILITY LOGOUT LOGIN) and !c.authed,
      do: throw({:bad, "Not authenticated"})

    exec(name, tag, args, c)
  catch
    :parse -> {:bad, "Could not parse command", c}
    {:bad, text} -> {:bad, text, c}
  end

  # Pending EXISTS go out before every tagged reply.
  defp reply(_tag, {:wait, c}), do: {:ok, c}

  defp reply(tag, {status, text, c}), do: reply(tag, {status, text, flush(c), :open})

  defp reply(tag, {status, text, c, close}) do
    write(c, [tag, " ", String.upcase(Atom.to_string(status)), " ", text])
    if close == :close, do: :ssl.close(c.sock) && :stop, else: {:ok, c}
  end

  defp exec("CAPABILITY", _tag, [], c) do
    write(c, ["* CAPABILITY ", if(c.authed, do: @caps, else: @caps_before)])
    {:ok, "Thats all she wrote! (Success)", c}
  end

  defp exec("LOGOUT", _tag, [], c) do
    write(c, "* BYE LOGOUT Requested")
    {:ok, "73 good day (Success)", c, :close}
  end

  # Gmail sends its capabilities again, untagged, after a login.
  defp exec("LOGIN", _tag, [user, password], c) do
    case GenServer.call(c.server, {:login, :imap, string(user), string(password)}) do
      {:ok, account} ->
        write(c, "* CAPABILITY " <> @caps)
        {:ok, "#{account} authenticated (Success)", %{c | authed: account}}

      {:no, text} ->
        {:no, text, c}
    end
  end

  defp exec("LIST", _tag, [reference, pattern | _return], c) do
    glob = (string(reference) <> string(pattern)) |> Regex.escape() |> String.replace("\\*", ".*")
    match = Regex.compile!("^" <> String.replace(glob, "%", "[^/]*") <> "$", "s")

    for {name, attrs, _view} <- GenServer.call(c.server, :folders),
        Regex.match?(match, name),
        do: write(c, ["* LIST (", Enum.join(attrs, " "), ~S|) "/" |, quote_string(name)])

    {:ok, "Success", c}
  end

  defp exec("SELECT", _tag, [name | _params], c) do
    case GenServer.call(c.server, {:view, string(name)}) do
      %{} = v ->
        exists = length(v.msgs)
        write(c, ["* FLAGS (", @flags, ")"])
        write(c, ["* OK [PERMANENTFLAGS (", @flags, " \\*)] Flags permitted."])
        write(c, "* OK [UIDVALIDITY #{v.uidvalidity}] UIDs valid.")
        write(c, "* #{exists} EXISTS")
        write(c, "* 0 RECENT")
        write(c, "* OK [UIDNEXT #{v.uidnext}] Predicted next UID.")
        write(c, "* OK [HIGHESTMODSEQ #{v.modseq}]")
        {:ok, "[READ-WRITE] #{v.name} selected. (Success)", %{c | sel: v.name, reported: exists}}

      nil ->
        text =
          "[NONEXISTENT] Unknown Mailbox: #{string(name)} (now in authenticated state) (Failure)"

        {:no, text, %{c | sel: nil}}
    end
  end

  defp exec("IDLE", tag, [], c) do
    write(c, "+ idling")
    {:wait, flush(%{c | idle: tag})}
  end

  defp exec("UID SEARCH", _tag, args, c) do
    {msgs, c} = snapshot(c)
    if args == [], do: throw(:parse)
    tests = criteria(args, top(msgs), [])
    hits = for m <- msgs, Enum.all?(tests, &hit?(m, &1)), do: [" ", Integer.to_string(m.uid)]
    write(c, ["* SEARCH" | hits])
    {:ok, "SEARCH completed (Success)", c}
  end

  defp exec("UID FETCH", _tag, [{:atom, set} | items], c) do
    items = Enum.map(parens(items), &fetch_item/1)
    {msgs, c} = in_set(c, set)

    # A BODY without PEEK marks what it reads seen, and says so.
    {msgs, items} =
      if Enum.any?(items, &match?({:body, false, _}, &1)),
        do: {store(c, msgs, :flags, ["\\Seen"]), [:flags | items]},
        else: {msgs, items}

    for m <- msgs, do: write(c, fetch_response(m, items))
    {:ok, "Success", c}
  end

  defp exec("UID STORE", _tag, [{:atom, set}, {:atom, item} | values], c) do
    if String.upcase(item) != "+X-GM-LABELS", do: throw(:parse)
    values = for v <- parens(values), do: string(v)
    {msgs, c} = in_set(c, set)

    for m <- store(c, msgs, :labels, values),
        do: write(c, ["* #{m.seq} FETCH (", fetch_part(:labels, m), " UID #{m.uid})"])

    {:ok, "Success", c}
  end

  defp exec(_name, _tag, _args, _c), do: throw(:parse)

  defp store(c, msgs, field, values),
    do: GenServer.call(c.server, {:store, c.sel, Enum.map(msgs, & &1.uid), field, values})

  defp parens([:lp | rest]),
    do: if(List.last(rest) == :rp, do: Enum.drop(rest, -1), else: throw(:parse))

  defp parens([_] = one), do: one
  defp parens(_), do: throw(:parse)

  # The selected folder's messages whose UIDs are in `set`.
  defp in_set(c, set) do
    {msgs, c} = snapshot(c)
    ranges = set(set, top(msgs))
    {Enum.filter(msgs, &in_set?(&1.uid, ranges)), c}
  end

  defp snapshot(%{sel: nil}), do: throw({:bad, "No mailbox selected"})

  defp snapshot(c) do
    msgs = GenServer.call(c.server, {:view, c.sel}).msgs
    {msgs, sync(c, length(msgs))}
  end

  defp flush(%{sel: nil} = c), do: c
  defp flush(c), do: sync(c, length(GenServer.call(c.server, {:view, c.sel}).msgs))

  defp sync(c, count) do
    if count > c.reported, do: write(c, "* #{count} EXISTS")
    %{c | reported: count}
  end

  defp string({:atom, a}), do: a
  defp string({:str, s}), do: s
  defp string(_tok), do: throw(:parse)

  defp top(msgs), do: msgs |> Enum.map(& &1.uid) |> Enum.max(fn -> 0 end)

  # A sequence set, 1,5,9:12 or 457:* or *, as ranges. * is the highest
  # UID, so n:* holds it even when n is above it.
  defp set(text, top) do
    for part <- String.split(text, ",") do
      case Enum.map(String.split(part, ":"), &set_number(&1, top)) do
        [a] -> a..a
        [a, b] -> min(a, b)..max(a, b)
        _ -> throw(:parse)
      end
    end
  end

  defp set_number("*", top), do: top

  defp set_number(text, _top) do
    case Integer.parse(text) do
      {n, ""} when n > 0 -> n
      _ -> throw(:parse)
    end
  end

  defp in_set?(uid, ranges), do: Enum.any?(ranges, &(uid in &1))

  defp criteria([], _top, acc), do: acc

  defp criteria([{:atom, key} | rest], top, acc) do
    case {String.upcase(key), rest} do
      {"UID", [{:atom, set} | rest]} ->
        criteria(rest, top, [{:uid, set(set, top)} | acc])

      {"SINCE", [date | rest]} ->
        criteria(rest, top, [{:since, search_date(string(date))} | acc])

      {"X-GM-RAW", [query | rest]} ->
        criteria(rest, top, [{:id, raw_search(string(query))} | acc])

      _ ->
        throw(:parse)
    end
  end

  defp criteria(_args, _top, _acc), do: throw(:parse)

  defp hit?(m, {:uid, ranges}), do: in_set?(m.uid, ranges)
  defp hit?(m, {:since, date}), do: not Date.before?(DateTime.to_date(m.internaldate), date)
  defp hit?(m, {:id, id}), do: m.message_id != nil and String.downcase(m.message_id) == id

  defp search_date(text) do
    with [d, mon, y] <- String.split(text, "-"),
         {day, ""} <- Integer.parse(d),
         month when is_integer(month) <- Enum.find_index(@months, &(&1 == String.downcase(mon))),
         {year, ""} <- Integer.parse(y),
         {:ok, date} <- Date.new(year, month + 1, day) do
      date
    else
      _ -> throw(:parse)
    end
  end

  # Only the rfc822msgid: operator of Gmail's search syntax, matched whole.
  defp raw_search(query) do
    case Regex.run(~r/^rfc822msgid:\s*<?([^<>\s]+)>?$/i, String.trim(query)) do
      [_, id] -> String.downcase(id)
      nil -> throw({:bad, "Could not parse command"})
    end
  end

  defp fetch_item(tok) do
    case String.upcase(string(tok)) do
      "UID" -> :uid
      "X-GM-MSGID" -> :msgid
      "X-GM-THRID" -> :thrid
      "X-GM-LABELS" -> :labels
      "INTERNALDATE" -> :internaldate
      "RFC822.SIZE" -> :size
      item -> body_item(item)
    end
  end

  defp body_item(item) do
    case Regex.run(~r/^BODY(\.PEEK)?\[(|HEADER\.FIELDS \((.*)\))\]$/, item) do
      [_, peek, ""] ->
        {:body, peek != "", :all}

      [_, peek, _, names] ->
        {:body, peek != "", {:fields, names |> String.replace("\"", "") |> String.split()}}

      nil ->
        throw(:parse)
    end
  end

  defp fetch_response(m, items) do
    simple = for item <- @fetch_order, item == :uid or item in items, do: fetch_part(item, m)
    bodies = for {:body, _peek, section} <- Enum.uniq(items), do: body_part(section, m.raw)
    ["* ", Integer.to_string(m.seq), " FETCH (", Enum.intersperse(simple ++ bodies, " "), ")"]
  end

  defp fetch_part(:thrid, m), do: ["X-GM-THRID ", Integer.to_string(m.thrid)]
  defp fetch_part(:msgid, m), do: ["X-GM-MSGID ", Integer.to_string(m.msgid)]
  defp fetch_part(:uid, m), do: ["UID ", Integer.to_string(m.uid)]
  defp fetch_part(:flags, m), do: ["FLAGS (", Enum.join(m.flags, " "), ")"]
  defp fetch_part(:size, m), do: ["RFC822.SIZE ", Integer.to_string(byte_size(m.raw))]

  defp fetch_part(:internaldate, m),
    do: ["INTERNALDATE \"", Calendar.strftime(m.internaldate, "%d-%b-%Y %H:%M:%S +0000"), "\""]

  defp fetch_part(:labels, m) do
    labels = for l <- m.labels, do: if(String.starts_with?(l, "\\"), do: l, else: astring(l))
    ["X-GM-LABELS (", Enum.intersperse(labels, " "), ")"]
  end

  defp body_part(:all, raw), do: ["BODY[] ", literal(raw)]

  defp body_part({:fields, names}, raw) do
    wanted = Enum.map(names, &String.downcase/1)
    lines = for {name, lines} <- fields(raw), name in wanted, line <- lines, do: [line, "\r\n"]
    header = IO.iodata_to_binary([lines, "\r\n"])
    ["BODY[HEADER.FIELDS (", Enum.join(names, " "), ")] ", literal(header)]
  end

  defp literal(bin), do: ["{", Integer.to_string(byte_size(bin)), "}\r\n", bin]

  defp quote_string(s), do: [?", String.replace(s, ["\\", "\""], &("\\" <> &1)), ?"]

  # An IMAP atom when it is one (and not NIL), else a quoted string.
  defp astring(s) do
    if Regex.match?(~r/^[\x21\x23\x24\x26\x27\x2b-\x5b\x5e-\x7a\x7c-\x7e]+$/, s) and
         String.upcase(s) != "NIL",
       do: s,
       else: quote_string(s)
  end

  ## Message headers

  # Each header field as {lowercased name, its lines as stored, folds kept}:
  # the header block ends at the first blank line.
  defp fields(raw) do
    [header | _body] = :binary.split(raw, ["\r\n\r\n", "\n\n"])

    header
    |> String.split(["\r\n", "\n"])
    |> Enum.reduce([], fn
      <<ch, _::binary>> = line, [{name, lines} | rest] when ch in [?\s, ?\t] ->
        [{name, [line | lines]} | rest]

      line, acc ->
        case :binary.split(line, ":") do
          [name, _value] -> [{String.downcase(String.trim(name)), [line]} | acc]
          [_] -> acc
        end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {name, lines} -> {name, Enum.reverse(lines)} end)
  end

  defp field(fields, name) do
    Enum.find_value(fields, fn
      {^name, lines} -> lines |> Enum.join() |> :binary.split(":") |> List.last() |> String.trim()
      _ -> nil
    end)
  end

  defp ids(nil), do: []
  defp ids(value), do: for([_, id] <- Regex.scan(~r/<([^<>]+)>/, value), do: id)

  defp message_id(raw) do
    with value when is_binary(value) <- field(fields(raw), "message-id"),
         do: List.first(ids(value)) || if(value != "", do: value)
  end

  ## SMTP

  defp smtp_session(c) do
    c = Map.merge(c, %{greeted: false, authed: nil, from: nil, rcpts: [], data: nil})
    write(c, "220 smtp.gmail.com ESMTP fake - gsmtp")
    loop(c, &smtp_line/2)
  end

  defp smtp_line(".", %{data: data} = c) when data != nil, do: smtp_data(%{c | data: nil}, data)

  defp smtp_line(line, %{data: data} = c) when data != nil,
    do: {:ok, %{c | data: [data, with("." <> rest <- line, do: rest), "\r\n"]}}

  defp smtp_line(line, c) do
    [verb | arg] = String.split(line, " ", parts: 2)
    verb = String.upcase(verb)

    case smtp_order(verb, c) do
      nil -> smtp_verb(verb, String.trim(Enum.join(arg)), c)
      refusal -> smtp_reply(c, refusal)
    end
  end

  # What Gmail refuses out of order.
  defp smtp_order(verb, c) do
    cond do
      verb in ~w(AUTH MAIL RCPT DATA) and not c.greeted -> "503 5.5.1 EHLO/HELO first. x - gsmtp"
      verb == "AUTH" and c.authed != nil -> "503 5.5.1 Already authenticated. x - gsmtp"
      verb == "MAIL" and c.authed == nil -> @auth_required
      verb == "MAIL" and c.from != nil -> "503 5.5.1 Nested MAIL command. x - gsmtp"
      verb in ~w(RCPT DATA) and c.from == nil -> "503 5.5.1 MAIL first. x - gsmtp"
      verb == "DATA" and c.rcpts == [] -> "503 5.5.1 RCPT first. x - gsmtp"
      true -> nil
    end
  end

  defp smtp_verb("EHLO", _arg, c) do
    write(c, [
      ["250-smtp.gmail.com at your service, [", c.peer, "]\r\n"],
      "250-SIZE 35882577\r\n250-8BITMIME\r\n",
      "250-AUTH LOGIN PLAIN XOAUTH2 PLAIN-CLIENTTOKEN OAUTHBEARER XOAUTH\r\n",
      "250-ENHANCEDSTATUSCODES\r\n250-PIPELINING\r\n250 SMTPUTF8"
    ])

    {:ok, %{c | greeted: true, from: nil, rcpts: []}}
  end

  defp smtp_verb("AUTH", "PLAIN " <> response, c) do
    with {:ok, decoded} <- Base.decode64(response),
         [_authzid, user, password] <- :binary.split(decoded, <<0>>, [:global]) do
      case GenServer.call(c.server, {:login, :smtp, user, password}) do
        {:ok, account} -> smtp_reply(%{c | authed: account}, "235 2.7.0 Accepted")
        {:no, reply} -> smtp_reply(c, reply)
      end
    else
      _ -> smtp_reply(c, "501 5.5.2 Cannot Decode response x - gsmtp")
    end
  end

  defp smtp_verb("AUTH", _arg, c),
    do: smtp_reply(c, "504 5.7.4 Unrecognized authentication type. x - gsmtp")

  defp smtp_verb("MAIL", arg, c) do
    case Regex.run(~r/^FROM:\s*<([^>]*)>/i, arg) do
      [_, from] -> smtp_reply(%{c | from: from, rcpts: []}, "250 2.1.0 OK x - gsmtp")
      nil -> smtp_reply(c, "555 5.5.2 Syntax error. x - gsmtp")
    end
  end

  defp smtp_verb("RCPT", arg, c) do
    case Regex.run(~r/^TO:\s*<([^>]+)>/i, arg) do
      [_, to] -> smtp_reply(%{c | rcpts: c.rcpts ++ [to]}, "250 2.1.5 OK x - gsmtp")
      nil -> smtp_reply(c, "555 5.5.2 Syntax error. x - gsmtp")
    end
  end

  defp smtp_verb("DATA", _arg, c), do: smtp_reply(%{c | data: []}, "354  Go ahead x - gsmtp")

  defp smtp_verb("QUIT", _arg, c) do
    write(c, "221 2.0.0 closing connection x - gsmtp")
    :ssl.close(c.sock)
    :stop
  end

  defp smtp_verb(_verb, _arg, c), do: smtp_reply(c, "502 5.5.1 Unrecognized command. x - gsmtp")

  defp smtp_reply(c, line) do
    write(c, line)
    {:ok, c}
  end

  defp smtp_data(c, data) do
    message = {:smtp_data, c.from, c.rcpts, IO.iodata_to_binary(data)}
    c = %{c | from: nil, rcpts: []}

    case GenServer.call(c.server, message) do
      {:ok, unix} ->
        smtp_reply(c, "250 2.0.0 OK  #{unix} x - gsmtp")

      {:reply, "421" <> _ = reply} ->
        write(c, reply)
        :ssl.close(c.sock)
        :stop

      {:reply, reply} ->
        smtp_reply(c, reply)

      :drop ->
        :ssl.close(c.sock)
        :stop
    end
  end
end
