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

      {:ok, socket} =
        :ssl.connect(~c"localhost", fake.imap_port,
          verify: :verify_peer,
          cacerts: fake.cacerts,
          server_name_indication: ~c"localhost",
          customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
        )

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
      prefix. Names outside ASCII go out in modified UTF-7, as Gmail sends them.
    * `:uidvalidity` (1), `:idle_timeout_ms` (29 minutes), `:ip` (127.0.0.1).
    * `:spool`: a directory that drives the fake (see Standalone).

  The fake stops when the process that started it exits.

  ## Failures

  `fail/2` turns a mode on until `heal/1`; modes add up.

    * `:imap_auth`: every LOGIN fails, as with a revoked app password.
    * `:imap_disabled`: a right LOGIN answers that IMAP is off for the account.
    * `:smtp_auth`: every AUTH fails with Gmail's 535.
    * `{:smtp_reply, reply}`: the end of DATA is answered with `reply` and
      nothing is stored; a 421 also closes the connection.
    * `:smtp_drop_after_data`: the message is accepted (in `sent/1`, and in
      All Mail with `\Sent`), then the connection closes with no reply: the
      window a sender must survive without sending twice.
    * `:imap_bye`: at the call, every open IMAP connection gets
      `* BYE System error` and is closed. It is not kept as a mode.

  A wrong password is always refused. `down/1` closes both listeners and
  every connection; `up/1` listens again on the same ports.
  `set_uidvalidity/2` also renumbers every message from the next free UID,
  since a new UIDVALIDITY says the old UIDs mean nothing.

  ## What it serves

  IMAP: CAPABILITY, NOOP, LOGOUT, LOGIN, AUTHENTICATE PLAIN, LIST, SELECT,
  IDLE, and the UID forms of SEARCH (ALL, UID, SINCE, `X-GM-RAW
  "rfc822msgid:<id>"`, HEADER, an optional CHARSET), FETCH (UID, X-GM-MSGID,
  X-GM-THRID, X-GM-LABELS, INTERNALDATE, RFC822.SIZE, FLAGS, BODY[] and
  BODY[HEADER], BODY[TEXT], BODY[HEADER.FIELDS (...)], each also as
  BODY.PEEK) and STORE (X-GM-LABELS and FLAGS, `+`, `-` or neither,
  `.SILENT`). Anything else is `BAD Unknown command`. Before login,
  CAPABILITY lists what Gmail lists then (its AUTH= mechanisms, none of
  UIDPLUS, MOVE, CONDSTORE or LITERAL-); a login answers the full list
  untagged, as Gmail does. SMTP: EHLO, HELO, AUTH PLAIN and LOGIN, MAIL,
  RCPT, DATA, RSET, NOOP, QUIT.

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
  @system_labels ~W(\Inbox \Sent \Important \Starred \Draft \Trash \Spam)
  @system_flags ~W(\Seen \Answered \Flagged \Deleted \Draft)
  @special_use ~W(\All \Drafts \Flagged \Important \Junk \Sent \Trash)
  @auth_failed "[AUTHENTICATIONFAILED] Invalid credentials (Failure)"
  @imap_disabled "[ALERT] Your account is not enabled for IMAP use. Please visit your Gmail settings page and enable your account for IMAP access. (Failure)"
  @bad_credentials "535-5.7.8 Username and Password not accepted. For more information, go to\r\n535 5.7.8  https://support.google.com/mail/?p=BadCredentials x - gsmtp"
  @auth_required "530-5.7.0 Authentication Required. For more information, go to\r\n530 5.7.0  https://support.google.com/mail/?p=WantAuthError x - gsmtp"
  @too_many_rcpts "452-4.5.3 Your message has too many recipients. For more information regarding\r\n452-4.5.3 Google's sending limits, visit\r\n452 4.5.3  https://support.google.com/mail/?p=TooManyRecipientsError x - gsmtp"
  @modes [:imap_auth, :imap_disabled, :smtp_auth, :smtp_drop_after_data, :imap_bye]
  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)
  # Gmail does not answer FETCH items in the order asked, nor with UID first.
  @fetch_order [:thrid, :msgid, :labels, :uid, :flags, :internaldate, :size]

  ## API

  @doc """
  Starts a fake owned by the caller (options in the moduledoc):
  `{:ok, %{pid: pid, imap_port: port, smtp_port: port, cacerts: [der]}}`.
  """
  def start(opts \\ []) do
    case GenServer.start(__MODULE__, {opts, self()}) do
      {:ok, pid} -> {:ok, GenServer.call(pid, :info)}
      error -> error
    end
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
  Every message in UID order: `[%{uid, seq, msgid, thrid, labels, flags,
  internaldate, raw, message_id}]`. `seq` is the All Mail sequence number
  (nil for spam and trash, which All Mail leaves out); `message_id` has no
  brackets.
  """
  def messages(fake), do: call(fake, :messages)

  @doc "Every message SMTP accepted, oldest first: `[%{from, rcpts, raw, at}]`."
  def sent(fake), do: call(fake, :sent)

  @doc "Every login attempt, oldest first: `[%{proto: :imap | :smtp, user, ok, at}]`."
  def logins(fake), do: call(fake, :logins)

  @doc "Turns a failure mode on (the modes are in the moduledoc)."
  def fail(fake, {:smtp_reply, reply}) when is_binary(reply),
    do: call(fake, {:fail, {:smtp_reply, String.trim_trailing(reply, "\r\n")}})

  def fail(fake, mode) when mode in @modes, do: call(fake, {:fail, mode})

  @doc "Turns every failure mode off."
  def heal(fake), do: call(fake, :heal)

  @doc "Closes both listeners and every open connection: connecting is refused until `up/1`."
  def down(fake), do: call(fake, :down)

  @doc "Listens again on the same ports: `:ok` or `{:error, reason}`."
  def up(fake), do: call(fake, :up)

  @doc """
  Sets UIDVALIDITY, as the next SELECT reports it, and gives every message a
  new UID from the next free one on (open sessions are not told).
  """
  def set_uidvalidity(fake, n) when is_integer(n) and n > 0, do: call(fake, {:uidvalidity, n})

  @doc "Stops the fake, closing everything; a fake already gone is fine."
  def stop(fake) do
    GenServer.stop(pid(fake))
  catch
    :exit, _ -> :ok
  end

  @doc "Standalone mode: parses the flags in the moduledoc, starts a fake and blocks."
  def main(argv) do
    flags = [
      imap_port: :integer,
      smtp_port: :integer,
      cert: :string,
      key: :string,
      user: :string,
      password: :string,
      spool: :string,
      all_mail: :string,
      ip: :string
    ]

    {opts, rest, invalid} = OptionParser.parse(argv, strict: flags)
    ip = :inet.parse_address(to_charlist(opts[:ip] || "0.0.0.0"))

    if rest != [] or invalid != [] or opts[:spool] == nil or match?({:error, _}, ip) or
         is_nil(opts[:cert]) != is_nil(opts[:key]) do
      IO.puts(:stderr, """
      usage: elixir -r test/support/fake_gmail.ex -e 'Hireme.FakeGmail.main(System.argv())' -- \\
        --spool DIR [--imap-port 993] [--smtp-port 465] [--cert PEM --key PEM]
        [--user someone@gmail.com] [--password abcdefghijklmnop] [--all-mail NAME] [--ip 0.0.0.0]\
      """)

      System.halt(2)
    end

    tls = if opts[:cert], do: [certfile: opts[:cert], keyfile: opts[:key]], else: :test_ca

    start_opts =
      [
        imap_port: opts[:imap_port] || 993,
        smtp_port: opts[:smtp_port] || 465,
        tls: tls,
        ip: elem(ip, 1),
        spool: opts[:spool]
      ] ++ Keyword.take(opts, [:user, :password, :all_mail])

    case start(start_opts) do
      {:ok, fake} ->
        if tls == :test_ca do
          pem =
            :public_key.pem_encode(
              for der <- fake.cacerts, do: {:Certificate, der, :not_encrypted}
            )

          File.write!(Path.join(opts[:spool], "ca.pem"), pem)
        end

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
      idle_ms: Keyword.get(opts, :idle_timeout_ms, 29 * 60_000),
      imap_port: Keyword.get(opts, :imap_port, 0),
      smtp_port: Keyword.get(opts, :smtp_port, 0),
      ssl:
        [:binary, active: false, reuseaddr: true, ip: ip, versions: [:"tlsv1.3", :"tlsv1.2"]] ++
          tls,
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
      fails: [],
      inbox_sizes: %{}
    }

    case listen(s) do
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

  defp tls(files) do
    {[certfile: to_charlist(files[:certfile]), keyfile: to_charlist(files[:keyfile])], []}
  end

  defp listen(s) do
    with {:ok, imap} <- :ssl.listen(s.imap_port, s.ssl),
         {:ok, smtp} <- listen_beside(s.smtp_port, s.ssl, imap) do
      {:ok, {_, imap_port}} = :ssl.sockname(imap)
      {:ok, {_, smtp_port}} = :ssl.sockname(smtp)
      me = self()
      spawn(fn -> accept(me, imap, :imap) end)
      spawn(fn -> accept(me, smtp, :smtp) end)
      {:ok, %{s | imap_port: imap_port, smtp_port: smtp_port, listeners: [imap, smtp]}}
    end
  end

  defp listen_beside(port, opts, first) do
    case :ssl.listen(port, opts) do
      {:ok, _} = ok ->
        ok

      error ->
        :ssl.close(first)
        error
    end
  end

  # A closed listener ends its acceptor; so does any other error, rather
  # than spinning on it.
  defp accept(server, listener, proto) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        pid = spawn(fn -> connection(server, proto) end)
        _ = :ssl.controlling_process(socket, pid)
        send(pid, {:socket, socket})
        accept(server, listener, proto)

      {:error, _} ->
        :ok
    end
  end

  defp close_all(s) do
    Enum.each(s.listeners, &:ssl.close/1)
    Enum.each(Map.keys(s.conns), &Process.exit(&1, :kill))
    %{s | listeners: [], conns: %{}}
  end

  @impl true
  def handle_call(:info, _from, s) do
    info = %{pid: self(), imap_port: s.imap_port, smtp_port: s.smtp_port, cacerts: s.cacerts}
    {:reply, info, s}
  end

  def handle_call({:join, _proto}, _from, %{listeners: []} = s), do: {:reply, :down, s}

  def handle_call({:join, proto}, {pid, _}, s) do
    Process.monitor(pid)
    {:reply, {:ok, %{idle_ms: s.idle_ms}}, %{s | conns: Map.put(s.conns, pid, proto)}}
  end

  def handle_call({:deliver, raw, labels, opts}, _from, s) do
    date = DateTime.from_unix!(DateTime.to_unix(opts[:date] || DateTime.utc_now()))
    {uid, s} = append(s, raw, labels, date, Keyword.get(opts, :flags, []))
    {:reply, uid, s}
  end

  def handle_call(:messages, _from, s) do
    seqs = s |> view(:all) |> Map.new(&{&1.uid, &1.seq})
    {:reply, Enum.map(s.msgs, &(&1 |> Map.delete(:modseq) |> Map.put(:seq, seqs[&1.uid]))), s}
  end

  def handle_call(:sent, _from, s), do: {:reply, Enum.reverse(s.sent), s}
  def handle_call(:logins, _from, s), do: {:reply, Enum.reverse(s.logins), s}

  def handle_call({:fail, :imap_bye}, _from, s) do
    for {pid, :imap} <- s.conns, do: send(pid, {__MODULE__, :bye})
    {:reply, :ok, s}
  end

  def handle_call({:fail, {:smtp_reply, _} = mode}, _from, s) do
    {:reply, :ok, %{s | fails: [mode | Enum.reject(s.fails, &match?({:smtp_reply, _}, &1))]}}
  end

  def handle_call({:fail, mode}, _from, s),
    do: {:reply, :ok, %{s | fails: Enum.uniq([mode | s.fails])}}

  def handle_call(:heal, _from, s), do: {:reply, :ok, %{s | fails: []}}
  def handle_call(:down, _from, s), do: {:reply, :ok, close_all(s)}

  def handle_call(:up, _from, %{listeners: []} = s) do
    case listen(s) do
      {:ok, s} -> {:reply, :ok, s}
      error -> {:reply, error, s}
    end
  end

  def handle_call(:up, _from, s), do: {:reply, :ok, s}

  def handle_call({:uidvalidity, n}, _from, s) do
    {msgs, next} = Enum.map_reduce(s.msgs, s.uidnext, fn m, uid -> {%{m | uid: uid}, uid + 1} end)
    {:reply, :ok, spool_state(%{s | uidvalidity: n, msgs: msgs, uidnext: next})}
  end

  def handle_call({:login, proto, user, password}, _from, s) do
    right =
      String.downcase(user) == String.downcase(s.user) and
        String.replace(password, " ", "") == String.replace(s.password, " ", "")

    verdict =
      cond do
        proto == :smtp and (not right or :smtp_auth in s.fails) -> {:no, @bad_credentials}
        proto == :smtp -> {:ok, s.user}
        not right or :imap_auth in s.fails -> {:no, @auth_failed}
        :imap_disabled in s.fails -> {:no, @imap_disabled}
        true -> {:ok, s.user}
      end

    entry = %{
      proto: proto,
      user: user,
      ok: elem(verdict, 0) == :ok,
      at: DateTime.utc_now(:second)
    }

    {:reply, verdict, %{s | logins: [entry | s.logins]}}
  end

  def handle_call(:folders, _from, s), do: {:reply, folders(s), s}

  def handle_call({:select, name}, _from, s) do
    case folder(s, name) do
      {wire, filter} ->
        exists = length(view(s, filter))

        info = %{
          name: wire,
          exists: exists,
          uidvalidity: s.uidvalidity,
          uidnext: s.uidnext,
          modseq: s.modseq
        }

        {:reply, {:ok, info}, s}

      nil ->
        {:reply, :error, s}
    end
  end

  def handle_call({:view, name}, _from, s), do: {:reply, view_named(s, name), s}
  def handle_call({:count, name}, _from, s), do: {:reply, length(view_named(s, name)), s}

  def handle_call({:store, name, uids, field, op, values}, _from, s) do
    uids = MapSet.new(uids)
    canonical = if field == :labels, do: &label/1, else: &flag/1
    values = values |> Enum.map(canonical) |> Enum.uniq()
    seqs = s |> view_named(name) |> Map.new(&{&1.uid, &1.seq})
    modseq = s.modseq + 1

    msgs =
      Enum.map(s.msgs, fn m ->
        if MapSet.member?(uids, m.uid),
          do: %{m | field => change(Map.fetch!(m, field), op, values), modseq: modseq},
          else: m
      end)

    user_labels =
      if field == :labels and op != :remove,
        do: add_user_labels(s.user_labels, values),
        else: s.user_labels

    s = spool_state(%{s | msgs: msgs, modseq: modseq, user_labels: user_labels})

    changed =
      for m <- msgs, MapSet.member?(uids, m.uid), seqs[m.uid], do: Map.put(m, :seq, seqs[m.uid])

    {:reply, changed, s}
  end

  def handle_call({:smtp_data, from, rcpts, raw}, _from, s) do
    case Enum.find(s.fails, &match?({:smtp_reply, _}, &1)) do
      {:smtp_reply, reply} ->
        {:reply, {:reply, reply}, s}

      nil ->
        at = DateTime.utc_now(:second)
        entry = %{from: from, rcpts: rcpts, raw: raw, at: at}
        s = %{s | sent: [entry | s.sent]}
        spool_sent(s.spool, length(s.sent), entry)
        # Gmail files what it sends in All Mail, as read and with a Message-ID
        # of its own when the sender gave none.
        {_uid, s} = append(s, with_message_id(raw), ["\\Sent"], at, ["\\Seen"])
        reply = if :smtp_drop_after_data in s.fails, do: :drop, else: {:ok, DateTime.to_unix(at)}
        {:reply, reply, s}
    end
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
  def terminate(_reason, s) do
    close_all(s)
    :ok
  end

  defp append(s, raw, labels, date, flags) do
    # Gmail's X-GM-MSGIDs grow with time: about 1.9e18 in 2026, inside an i64.
    msgid = max(s.last_msgid + 1, System.os_time(:millisecond) * 1_048_576)
    labels = labels |> Enum.map(&label/1) |> Enum.uniq() |> Enum.sort()

    m = %{
      uid: s.uidnext,
      msgid: msgid,
      thrid: thread(s.msgs, raw) || msgid,
      labels: labels,
      flags: flags |> Enum.map(&flag/1) |> Enum.uniq() |> Enum.sort(),
      internaldate: date,
      raw: raw,
      message_id: message_id(raw),
      modseq: s.modseq + 1
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
    if message_id(raw) do
      raw
    else
      id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      "Message-ID: <#{id}@mx.google.com>\r\n" <> raw
    end
  end

  defp add_user_labels(set, labels),
    do: labels |> Enum.reject(&String.starts_with?(&1, "\\")) |> Enum.into(set)

  defp change(old, :add, values), do: Enum.sort(Enum.uniq(old ++ values))
  defp change(old, :remove, values), do: old -- values
  defp change(_old, :set, values), do: Enum.sort(values)

  defp label("\\" <> _ = l),
    do: Enum.find(@system_labels, l, &(String.downcase(&1) == String.downcase(l)))

  defp label(l), do: l

  defp flag(f), do: Enum.find(@system_flags, f, &(String.downcase(&1) == String.downcase(f)))

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

  # A selectable folder by its name on the wire: {wire name, view}.
  defp folder(s, name) do
    Enum.find_value(folders(s), fn {folder, _, filter} ->
      wire = mutf7(folder)

      if filter != :none and
           (wire == name or (wire == "INBOX" and String.upcase(name) == "INBOX")),
         do: {wire, filter}
    end)
  end

  defp view_named(s, name) do
    case folder(s, name) do
      {_, filter} -> view(s, filter)
      nil -> []
    end
  end

  defp view(s, filter) do
    s.msgs
    |> Enum.filter(&visible?(&1, filter))
    |> Enum.with_index(1)
    |> Enum.map(fn {m, seq} -> Map.put(m, :seq, seq) end)
  end

  # All Mail leaves out spam and trash, as Gmail's does.
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
    rows =
      for m <- s.msgs do
        %{
          "uid" => m.uid,
          "msgid" => m.msgid,
          "thrid" => m.thrid,
          "labels" => m.labels,
          "message_id" => m.message_id
        }
      end

    spool_write(Path.join(s.spool, "state.json"), JSON.encode!(rows))
    s
  end

  defp spool_sent(nil, _n, _entry), do: :ok

  defp spool_sent(dir, n, entry) do
    json = %{"from" => entry.from, "rcpts" => entry.rcpts, "at" => DateTime.to_iso8601(entry.at)}
    spool_write(Path.join([dir, "sent", "#{n}.eml"]), entry.raw)
    spool_write(Path.join([dir, "sent", "#{n}.json"]), JSON.encode!(json))
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

    names =
      case File.ls(inbox) do
        {:ok, names} -> names
        {:error, _} -> []
      end

    sizes =
      for name <- names,
          not String.starts_with?(name, "."),
          {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} <-
            [File.stat(Path.join(inbox, name))],
          into: %{},
          do: {name, {size, mtime}}

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
        with {:ok, conf} <- join(server, proto),
             {:ok, socket} <- :ssl.handshake(socket, 15_000) do
          c = Map.merge(conf, %{sock: socket, server: server, peer: peer(socket), buf: ""})
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

  ## IMAP

  defp imap_session(c) do
    c =
      Map.merge(c, %{
        toks: [],
        need: nil,
        authed: nil,
        sel: nil,
        reported: 0,
        idle: nil,
        cont: nil
      })

    write(c, "* OK Gimap ready for requests from #{c.peer}")
    imap_loop(c)
  end

  defp imap_loop(c) do
    case :ssl.setopts(c.sock, active: :once) do
      :ok -> imap_wait(c)
      {:error, _} -> :ok
    end
  end

  defp imap_wait(c) do
    receive do
      {:ssl, _, data} ->
        case imap_input(%{c | buf: c.buf <> data}) do
          {:wait, c} -> imap_loop(c)
          :stop -> :ok
        end

      {:ssl_closed, _} ->
        :ok

      {:ssl_error, _, _} ->
        :ok

      {__MODULE__, :changed} ->
        imap_loop(if c.idle, do: flush(c), else: c)

      {__MODULE__, :bye} ->
        bye(c, "System error")

      {__MODULE__, :idle_timeout, ref} ->
        case c.idle do
          {_tag, ^ref, _timer} -> bye(c, "IDLE timeout")
          _ -> imap_loop(c)
        end
    end
  end

  defp bye(c, text) do
    write(c, "* BYE " <> text)
    :ssl.close(c.sock)
  end

  defp imap_input(c) do
    result =
      case next_input(c) do
        {:more, c} -> {:wait, c}
        {:line, line, c} -> continuation(line, c)
        {:command, toks, c} -> command(toks, c)
      end

    case result do
      {:ok, c} -> imap_input(c)
      other -> other
    end
  end

  # During IDLE or AUTHENTICATE the next line is bare. Otherwise it is a
  # command: a line, or lines joined by literals ({n} or {n+} at a line's
  # end, then n bytes); a synchronizing literal is answered "+ go ahead".
  defp next_input(%{need: n} = c) when is_integer(n) do
    case c.buf do
      <<literal::binary-size(^n), rest::binary>> ->
        next_input(%{c | buf: rest, need: nil, toks: [{:str, literal} | c.toks]})

      _ ->
        {:more, c}
    end
  end

  defp next_input(c) do
    case :binary.split(c.buf, "\n") do
      [_] ->
        {:more, c}

      [line, rest] ->
        line = String.trim_trailing(line, "\r")
        c = %{c | buf: rest}

        if c.idle != nil or c.cont != nil do
          {:line, line, c}
        else
          case Regex.run(~r/^(.*)\{(\d+)(\+?)\}$/s, line) do
            [_, before, n, plus] ->
              if plus == "", do: write(c, "+ go ahead")

              next_input(%{
                c
                | toks: Enum.reverse(lex(before), c.toks),
                  need: String.to_integer(n)
              })

            nil ->
              {:command, Enum.reverse(c.toks, lex(line)), %{c | toks: []}}
          end
        end
    end
  end

  defp lex(bin), do: lex(bin, [])

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

    cond do
      name in ~w(CAPABILITY NOOP LOGOUT) ->
        reply(tag, run(name, tag, args, c))

      name in ~w(LOGIN AUTHENTICATE) ->
        reply(
          tag,
          if(c.authed, do: {:bad, "Already authenticated", c}, else: run(name, tag, args, c))
        )

      name in ["LIST", "SELECT", "IDLE", "UID SEARCH", "UID FETCH", "UID STORE"] ->
        reply(
          tag,
          if(c.authed, do: run(name, tag, args, c), else: {:bad, "Not authenticated", c})
        )

      true ->
        reply(tag, {:bad, "Unknown command", c})
    end
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
    exec(name, tag, args, c)
  catch
    :parse -> {:bad, "Could not parse command", c}
    {:bad, text} -> {:bad, text, c}
  end

  # Pending EXISTS go out before every tagged reply.
  defp reply(_tag, {:wait, c}), do: {:ok, c}

  defp reply(tag, {status, text, c}) do
    c = flush(c)
    write(c, [tag, " ", status(status), " ", text])
    {:ok, c}
  end

  defp reply(tag, {status, text, c, :close}) do
    write(c, [tag, " ", status(status), " ", text])
    :ssl.close(c.sock)
    :stop
  end

  defp status(:ok), do: "OK"
  defp status(:no), do: "NO"
  defp status(:bad), do: "BAD"

  defp exec("CAPABILITY", _tag, [], c) do
    write(c, ["* CAPABILITY ", if(c.authed, do: @caps, else: @caps_before)])
    {:ok, "Thats all she wrote! (Success)", c}
  end

  defp exec("NOOP", _tag, [], c), do: {:ok, "Success", c}

  defp exec("LOGOUT", _tag, [], c) do
    write(c, "* BYE LOGOUT Requested")
    {:ok, "73 good day (Success)", c, :close}
  end

  defp exec("LOGIN", _tag, [user, password], c), do: login(string(user), string(password), c)

  defp exec("AUTHENTICATE", tag, [mechanism | initial], c) do
    case {String.upcase(string(mechanism)), initial} do
      {"PLAIN", [response]} ->
        plain(string(response), c)

      {"PLAIN", []} ->
        write(c, "+ ")
        {:wait, %{c | cont: tag}}

      _ ->
        {:no, "[ALERT] Unsupported authentication mechanism. (Failure)", c}
    end
  end

  defp exec("LIST", _tag, args, c) do
    {special, args} =
      case args do
        [:lp, {:atom, option}, :rp | rest] ->
          if String.upcase(option) != "SPECIAL-USE", do: throw(:parse)
          {true, rest}

        _ ->
          {false, args}
      end

    case args do
      [reference, pattern | _return] -> list(string(reference) <> string(pattern), special, c)
      _ -> throw(:parse)
    end
  end

  defp exec("SELECT", _tag, [name | _params], c) do
    case GenServer.call(c.server, {:select, string(name)}) do
      {:ok, v} ->
        write(c, ["* FLAGS (", @flags, ")"])
        write(c, ["* OK [PERMANENTFLAGS (", @flags, " \\*)] Flags permitted."])
        write(c, "* OK [UIDVALIDITY #{v.uidvalidity}] UIDs valid.")
        write(c, "* #{v.exists} EXISTS")
        write(c, "* 0 RECENT")
        write(c, "* OK [UIDNEXT #{v.uidnext}] Predicted next UID.")
        write(c, "* OK [HIGHESTMODSEQ #{v.modseq}]")

        {:ok, "[READ-WRITE] #{v.name} selected. (Success)",
         %{c | sel: v.name, reported: v.exists}}

      :error ->
        text =
          "[NONEXISTENT] Unknown Mailbox: #{string(name)} (now in authenticated state) (Failure)"

        {:no, text, %{c | sel: nil}}
    end
  end

  defp exec("IDLE", tag, [], c) do
    write(c, "+ idling")
    ref = make_ref()
    timer = Process.send_after(self(), {__MODULE__, :idle_timeout, ref}, c.idle_ms)
    {:wait, flush(%{c | idle: {tag, ref, timer}})}
  end

  defp exec("UID SEARCH", _tag, args, c) do
    {msgs, c} = snapshot(c)

    args =
      case args do
        [{:atom, charset}, _name | rest] ->
          if String.upcase(charset) == "CHARSET", do: rest, else: args

        _ ->
          args
      end

    if args == [], do: throw(:parse)
    tests = criteria(args, top(msgs), [])
    hits = for m <- msgs, Enum.all?(tests, & &1.(m)), do: [" ", Integer.to_string(m.uid)]
    write(c, ["* SEARCH" | hits])
    {:ok, "SEARCH completed (Success)", c}
  end

  defp exec("UID FETCH", _tag, [{:atom, set} | items], c) do
    ranges = set(set)

    items =
      case items do
        [:lp | rest] -> if List.last(rest) == :rp, do: Enum.drop(rest, -1), else: throw(:parse)
        [_] -> items
        _ -> throw(:parse)
      end

    items = Enum.map(items, &fetch_item/1)
    {msgs, c} = snapshot(c)
    top = top(msgs)
    msgs = Enum.filter(msgs, &in_set?(&1.uid, ranges, top))

    {msgs, items} =
      if Enum.any?(items, &match?({:body, false, _}, &1)) do
        uids = Enum.map(msgs, & &1.uid)

        {GenServer.call(c.server, {:store, c.sel, uids, :flags, :add, ["\\Seen"]}),
         [:flags | items]}
      else
        {msgs, items}
      end

    for m <- msgs, do: write(c, fetch_response(m, items))
    {:ok, "Success", c}
  end

  defp exec("UID STORE", _tag, [{:atom, set}, {:atom, item} | values], c) do
    ranges = set(set)

    {op, field, silent} =
      case Regex.run(~r/^([+-]?)(X-GM-LABELS|FLAGS)(\.SILENT)?$/, String.upcase(item)) do
        [_, sign, name | silent] ->
          op = %{"+" => :add, "-" => :remove, "" => :set}[sign]
          {op, if(name == "FLAGS", do: :flags, else: :labels), silent != []}

        nil ->
          throw(:parse)
      end

    values =
      case values do
        [:lp | rest] -> if List.last(rest) == :rp, do: Enum.drop(rest, -1), else: throw(:parse)
        _ -> values
      end

    values = for v <- values, do: if(field == :labels, do: unmutf7(string(v)), else: string(v))
    {msgs, c} = snapshot(c)
    top = top(msgs)
    uids = for m <- msgs, in_set?(m.uid, ranges, top), do: m.uid
    changed = GenServer.call(c.server, {:store, c.sel, uids, field, op, values})

    if not silent do
      for m <- changed do
        out = if field == :labels, do: fetch_part(:labels, m), else: fetch_part(:flags, m)

        write(c, [
          "* ",
          Integer.to_string(m.seq),
          " FETCH (",
          out,
          " UID ",
          Integer.to_string(m.uid),
          ")"
        ])
      end
    end

    {:ok, "Success", c}
  end

  defp exec(_name, _tag, _args, _c), do: throw(:parse)

  defp continuation(line, %{idle: {tag, _ref, timer}} = c) do
    Process.cancel_timer(timer)
    c = %{c | idle: nil}

    if String.upcase(String.trim(line)) == "DONE",
      do: reply(tag, {:ok, "IDLE terminated (Success)", c}),
      else: reply(tag, {:bad, "Could not parse command", c})
  end

  defp continuation(line, %{cont: tag} = c) do
    c = %{c | cont: nil}

    case String.trim(line) do
      "*" -> reply(tag, {:bad, "AUTHENTICATE aborted", c})
      response -> reply(tag, plain(response, c))
    end
  end

  defp plain(response, c) do
    with {:ok, decoded} <- Base.decode64(response),
         [_authzid, user, password] <- :binary.split(decoded, <<0>>, [:global]) do
      login(user, password, c)
    else
      _ -> {:bad, "Invalid SASL argument.", c}
    end
  end

  # Gmail sends its capabilities again, untagged, after a login.
  defp login(user, password, c) do
    case GenServer.call(c.server, {:login, :imap, user, password}) do
      {:ok, account} ->
        write(c, "* CAPABILITY " <> @caps)
        {:ok, "#{account} authenticated (Success)", %{c | authed: account}}

      {:no, text} ->
        {:no, text, c}
    end
  end

  defp list(pattern, special, c) do
    if pattern == "" do
      write(c, ~S|* LIST (\Noselect) "/" ""|)
    else
      match =
        pattern |> Regex.escape() |> String.replace("\\*", ".*") |> String.replace("%", "[^/]*")

      match = Regex.compile!("^" <> match <> "$", "s")

      for {name, attrs, _view} <- GenServer.call(c.server, :folders),
          wire = mutf7(name),
          Regex.match?(match, wire),
          not special or Enum.any?(attrs, &(&1 in @special_use)) do
        write(c, ["* LIST (", Enum.join(attrs, " "), ~S|) "/" |, quote_string(wire)])
      end
    end

    {:ok, "Success", c}
  end

  defp snapshot(%{sel: nil}), do: throw({:bad, "No mailbox selected"})

  defp snapshot(c) do
    msgs = GenServer.call(c.server, {:view, c.sel})
    {msgs, sync(c, length(msgs))}
  end

  defp flush(%{sel: nil} = c), do: c
  defp flush(c), do: sync(c, GenServer.call(c.server, {:count, c.sel}))

  defp sync(c, count) do
    if count > c.reported, do: write(c, "* #{count} EXISTS")
    %{c | reported: count}
  end

  defp string({:atom, a}), do: a
  defp string({:str, s}), do: s
  defp string(_tok), do: throw(:parse)

  defp top(msgs), do: msgs |> Enum.map(& &1.uid) |> Enum.max(fn -> 0 end)

  # A sequence set: 1,5,9:12 or 457:* or *.
  defp set(text) do
    for part <- String.split(text, ",") do
      case String.split(part, ":") do
        [a] -> {set_number(a), set_number(a)}
        [a, b] -> {set_number(a), set_number(b)}
        _ -> throw(:parse)
      end
    end
  end

  defp set_number("*"), do: :star

  defp set_number(text) do
    case Integer.parse(text) do
      {n, ""} when n > 0 -> n
      _ -> throw(:parse)
    end
  end

  # * is the highest UID, so n:* holds it even when n is above it.
  defp in_set?(uid, ranges, top) do
    Enum.any?(ranges, fn {a, b} ->
      a = if a == :star, do: top, else: a
      b = if b == :star, do: top, else: b
      uid >= min(a, b) and uid <= max(a, b)
    end)
  end

  defp criteria([], _top, acc), do: acc

  defp criteria([{:atom, key} | rest], top, acc) do
    case {String.upcase(key), rest} do
      {"ALL", rest} ->
        criteria(rest, top, [fn _ -> true end | acc])

      {"UID", [{:atom, set} | rest]} ->
        ranges = set(set)
        criteria(rest, top, [fn m -> in_set?(m.uid, ranges, top) end | acc])

      {"SINCE", [date | rest]} ->
        since = search_date(string(date))
        on_or_after = fn m -> Date.compare(DateTime.to_date(m.internaldate), since) != :lt end
        criteria(rest, top, [on_or_after | acc])

      {"X-GM-RAW", [query | rest]} ->
        criteria(rest, top, [raw_search(string(query)) | acc])

      {"HEADER", [name, value | rest]} ->
        criteria(rest, top, [header_search(string(name), string(value)) | acc])

      _ ->
        throw(:parse)
    end
  end

  defp criteria(_args, _top, _acc), do: throw(:parse)

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
      [_, id] ->
        id = String.downcase(id)
        &(&1.message_id != nil and String.downcase(&1.message_id) == id)

      nil ->
        throw({:bad, "Could not parse command"})
    end
  end

  defp header_search(name, value) do
    name = String.downcase(name)
    value = String.downcase(value)

    fn m ->
      Enum.any?(fields(m.raw), fn {field, lines} ->
        field == name and String.contains?(String.downcase(unfold(lines)), value)
      end)
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
      "FLAGS" -> :flags
      item -> body_item(item)
    end
  end

  defp body_item(item) do
    case Regex.run(~r/^BODY(\.PEEK)?\[([^\]]*)\]$/, item) do
      [_, peek, section] -> {:body, peek != "", section(section)}
      nil -> throw(:parse)
    end
  end

  defp section(""), do: :all
  defp section("HEADER"), do: :header
  defp section("TEXT"), do: :text

  defp section("HEADER.FIELDS " <> names) do
    case Regex.run(~r/^\((.*)\)$/, String.trim(names)) do
      [_, names] -> {:fields, names |> String.replace("\"", "") |> String.split()}
      nil -> throw(:parse)
    end
  end

  defp section(_section), do: throw(:parse)

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
    labels =
      Enum.map(m.labels, fn
        "\\" <> _ = system -> system
        user -> astring(mutf7(user))
      end)

    ["X-GM-LABELS (", Enum.intersperse(labels, " "), ")"]
  end

  defp body_part(:all, raw), do: ["BODY[] ", literal(raw)]
  defp body_part(:header, raw), do: ["BODY[HEADER] ", literal(elem(split_message(raw), 0))]
  defp body_part(:text, raw), do: ["BODY[TEXT] ", literal(elem(split_message(raw), 1))]

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

  # Modified UTF-7 (RFC 3501 5.1.3), how Gmail names folders and labels on the wire.
  defp mutf7(name) do
    name
    |> String.to_charlist()
    |> Enum.chunk_by(&(&1 in 0x20..0x7E))
    |> Enum.map_join(fn [first | _] = run ->
      if first in 0x20..0x7E do
        run |> List.to_string() |> String.replace("&", "&-")
      else
        utf16 = :unicode.characters_to_binary(run, :unicode, {:utf16, :big})
        "&" <> String.replace(Base.encode64(utf16, padding: false), "/", ",") <> "-"
      end
    end)
  end

  defp unmutf7(wire) do
    Regex.replace(~r/&([A-Za-z0-9+,]*)-/, wire, fn
      _, "" ->
        "&"

      whole, b64 ->
        with {:ok, utf16} <- Base.decode64(String.replace(b64, ",", "/"), padding: false),
             text when is_binary(text) <- :unicode.characters_to_binary(utf16, {:utf16, :big}) do
          text
        else
          _ -> whole
        end
    end)
  end

  ## Message headers

  # The header block (with the blank line ending it) and the body.
  defp split_message(raw) do
    case :binary.match(raw, ["\r\n\r\n", "\n\n"]) do
      {at, len} ->
        {binary_part(raw, 0, at + len), binary_part(raw, at + len, byte_size(raw) - at - len)}

      :nomatch ->
        {raw, ""}
    end
  end

  # Each header field as {lowercased name, its lines as stored, folds kept}.
  defp fields(raw) do
    {header, _body} = split_message(raw)

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
      {^name, lines} -> unfold(lines)
      _ -> nil
    end)
  end

  defp unfold(lines),
    do: lines |> Enum.join() |> :binary.split(":") |> List.last() |> String.trim()

  defp ids(nil), do: []
  defp ids(value), do: for([_, id] <- Regex.scan(~r/<([^<>]+)>/, value), do: id)

  defp message_id(raw) do
    case field(fields(raw), "message-id") do
      nil ->
        nil

      value ->
        List.first(ids(value)) || if(String.trim(value) == "", do: nil, else: String.trim(value))
    end
  end

  ## SMTP

  defp smtp_session(c) do
    c = Map.merge(c, %{greeted: false, authed: nil, from: nil, rcpts: [], mode: :cmd, data: []})
    write(c, "220 smtp.gmail.com ESMTP fake - gsmtp")
    smtp_loop(c)
  end

  defp smtp_loop(c) do
    case :ssl.setopts(c.sock, active: :once) do
      :ok -> smtp_wait(c)
      {:error, _} -> :ok
    end
  end

  defp smtp_wait(c) do
    receive do
      {:ssl, _, data} ->
        case smtp_input(%{c | buf: c.buf <> data}) do
          {:wait, c} -> smtp_loop(c)
          :stop -> :ok
        end

      {:ssl_closed, _} ->
        :ok

      {:ssl_error, _, _} ->
        :ok
    end
  end

  defp smtp_input(c) do
    case :binary.split(c.buf, "\r\n") do
      [_] ->
        {:wait, c}

      [line, rest] ->
        case smtp_line(line, %{c | buf: rest}) do
          {:ok, c} -> smtp_input(c)
          :stop -> :stop
        end
    end
  end

  defp smtp_line(line, %{mode: :data} = c) do
    case line do
      "." -> smtp_data(%{c | mode: :cmd})
      "." <> rest -> {:ok, %{c | data: [c.data, rest, "\r\n"]}}
      _ -> {:ok, %{c | data: [c.data, line, "\r\n"]}}
    end
  end

  defp smtp_line(line, %{mode: :auth_plain} = c), do: smtp_plain(line, %{c | mode: :cmd})

  defp smtp_line(line, %{mode: :auth_user} = c) do
    case Base.decode64(line) do
      {:ok, user} ->
        write(c, "334 UGFzc3dvcmQ6")
        {:ok, %{c | mode: {:auth_password, user}}}

      :error ->
        smtp_reply(%{c | mode: :cmd}, "501 5.5.2 Cannot Decode response x - gsmtp")
    end
  end

  defp smtp_line(line, %{mode: {:auth_password, user}} = c) do
    case Base.decode64(line) do
      {:ok, password} -> smtp_login(user, password, %{c | mode: :cmd})
      :error -> smtp_reply(%{c | mode: :cmd}, "501 5.5.2 Cannot Decode response x - gsmtp")
    end
  end

  defp smtp_line(line, c) do
    case String.split(line, " ", parts: 2) do
      [verb, arg] -> smtp_verb(String.upcase(verb), String.trim(arg), c)
      [verb] -> smtp_verb(String.upcase(verb), "", c)
    end
  end

  defp smtp_verb(verb, _arg, %{greeted: false} = c) when verb in ~w(AUTH MAIL RCPT DATA),
    do: smtp_reply(c, "503 5.5.1 EHLO/HELO first. x - gsmtp")

  defp smtp_verb("EHLO", _arg, c) do
    write(c, [
      ["250-smtp.gmail.com at your service, [", c.peer, "]\r\n"],
      "250-SIZE 35882577\r\n250-8BITMIME\r\n",
      "250-AUTH LOGIN PLAIN XOAUTH2 PLAIN-CLIENTTOKEN OAUTHBEARER XOAUTH\r\n",
      "250-ENHANCEDSTATUSCODES\r\n250-PIPELINING\r\n250 SMTPUTF8"
    ])

    {:ok, %{c | greeted: true, from: nil, rcpts: []}}
  end

  defp smtp_verb("HELO", _arg, c) do
    write(c, "250 smtp.gmail.com at your service")
    {:ok, %{c | greeted: true, from: nil, rcpts: []}}
  end

  defp smtp_verb("AUTH", _arg, %{authed: authed} = c) when authed != nil,
    do: smtp_reply(c, "503 5.5.1 Already authenticated. x - gsmtp")

  defp smtp_verb("AUTH", arg, c) do
    [mechanism | initial] = String.split(arg, " ", parts: 2)

    case {String.upcase(mechanism), initial} do
      {"PLAIN", [response]} ->
        smtp_plain(response, c)

      {"PLAIN", []} ->
        write(c, "334 ")
        {:ok, %{c | mode: :auth_plain}}

      {"LOGIN", []} ->
        write(c, "334 VXNlcm5hbWU6")
        {:ok, %{c | mode: :auth_user}}

      {"LOGIN", [user]} ->
        smtp_line(user, %{c | mode: :auth_user})

      _ ->
        smtp_reply(c, "504 5.7.4 Unrecognized authentication type. x - gsmtp")
    end
  end

  defp smtp_verb("MAIL", _arg, %{authed: nil} = c), do: smtp_reply(c, @auth_required)

  defp smtp_verb("MAIL", _arg, %{from: from} = c) when from != nil,
    do: smtp_reply(c, "503 5.5.1 Nested MAIL command. x - gsmtp")

  defp smtp_verb("MAIL", arg, c) do
    case Regex.run(~r/^FROM:\s*<([^>]*)>/i, arg) do
      [_, from] ->
        write(c, "250 2.1.0 OK x - gsmtp")
        {:ok, %{c | from: from, rcpts: []}}

      nil ->
        smtp_reply(c, "555 5.5.2 Syntax error. x - gsmtp")
    end
  end

  defp smtp_verb("RCPT", _arg, %{from: nil} = c),
    do: smtp_reply(c, "503 5.5.1 MAIL first. x - gsmtp")

  defp smtp_verb("RCPT", _arg, %{rcpts: rcpts} = c) when length(rcpts) >= 100,
    do: smtp_reply(c, @too_many_rcpts)

  defp smtp_verb("RCPT", arg, c) do
    case Regex.run(~r/^TO:\s*<([^>]+)>/i, arg) do
      [_, to] ->
        write(c, "250 2.1.5 OK x - gsmtp")
        {:ok, %{c | rcpts: c.rcpts ++ [to]}}

      nil ->
        smtp_reply(c, "555 5.5.2 Syntax error. x - gsmtp")
    end
  end

  defp smtp_verb("DATA", _arg, %{from: nil} = c),
    do: smtp_reply(c, "503 5.5.1 MAIL first. x - gsmtp")

  defp smtp_verb("DATA", _arg, %{rcpts: []} = c),
    do: smtp_reply(c, "503 5.5.1 RCPT first. x - gsmtp")

  defp smtp_verb("DATA", _arg, c) do
    write(c, "354  Go ahead x - gsmtp")
    {:ok, %{c | mode: :data, data: []}}
  end

  defp smtp_verb("RSET", _arg, c),
    do: smtp_reply(%{c | from: nil, rcpts: []}, "250 2.1.5 Flushed x - gsmtp")

  defp smtp_verb("NOOP", _arg, c), do: smtp_reply(c, "250 2.0.0 OK x - gsmtp")

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

  defp smtp_plain(response, c) do
    with {:ok, decoded} <- Base.decode64(response),
         [_authzid, user, password] <- :binary.split(decoded, <<0>>, [:global]) do
      smtp_login(user, password, c)
    else
      _ -> smtp_reply(c, "501 5.5.2 Cannot Decode response x - gsmtp")
    end
  end

  defp smtp_login(user, password, c) do
    case GenServer.call(c.server, {:login, :smtp, user, password}) do
      {:ok, account} -> smtp_reply(%{c | authed: account}, "235 2.7.0 Accepted")
      {:no, reply} -> smtp_reply(c, reply)
    end
  end

  defp smtp_data(c) do
    message = {:smtp_data, c.from, c.rcpts, IO.iodata_to_binary(c.data)}
    c = %{c | from: nil, rcpts: [], data: []}

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
