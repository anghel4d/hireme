defmodule Hireme.Gmail do
  @moduledoc """
  The node's Gmail link (docs/mail/passthrough.md): an account's own Gmail
  as hireme's mailbox, so what hireme sends sits in Gmail's Sent and the
  replies land in the Gmail inbox as always.

  - **Linking** verifies the app password with one IMAP login before
    anything is stored, then seals it on the mailbox row (server_only, no
    key or replica carries it). Only `@gmail.com` and `@googlemail.com`
    addresses, at most `mailbox_link` tries per account.
  - **A session** per linked account (`Hireme.Gmail.Session`) keeps All
    Mail in step over IMAP IDLE, ingests the search's mail and sends the
    email missions fired under a key, over Gmail's SMTP.
  - **Ingestion** is one door for both pipes, Gmail and the domain's Email
    Worker: parse within bounds (`Hireme.Gmail.Mime`), ask the kernel's
    filer whether the mail is the search's, and put it through the
    sequencer as the mail actor, keyed by its Message-ID, so a copy that
    comes twice is kept once. Mail the filer does not take is read and
    dropped: never stored, never labelled.

  The sequencer tells this module what its commits moved (`moved/2`): a
  mission gone in flight is sent, a mailbox unlinked forgets its secret.
  """

  use Supervisor

  import Ecto.Query
  require Hireme.Outreach
  require Logger

  alias Hireme.{Accounts, Audit, Grants, Repo, Schema, Security, Sequencer}
  alias Hireme.Gmail.{Imap, Mime, Session}
  alias Hireme.Kernel.Nif
  alias Hireme.Outreach
  alias Hireme.Outreach.Email
  alias Hireme.Rows.Mailbox
  alias HiremeWeb.Wire.Codec

  @password "hireme mail app password"
  @pipe "hireme mail pipe secret"

  # ------------------------------------------------------------ supervisor

  @doc false
  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl Supervisor
  def init(_arg) do
    # Every linked mailbox's session, once the node is up; a test's
    # sandboxed database starts its own.
    resume =
      if Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox,
        do: [],
        else: [Supervisor.child_spec({Task, &resume/0}, id: :resume, restart: :temporary)]

    children =
      [
        {Registry, keys: :unique, name: Hireme.Gmail.Registry},
        {DynamicSupervisor, name: Hireme.Gmail.Sessions, strategy: :one_for_one}
      ] ++ resume

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp resume do
    Repo.all(
      from(m in Mailbox,
        where: m.status != :unlinked and not is_nil(m.secret),
        select: m.account_id
      ),
      skip_account: true
    )
    |> Enum.each(&start/1)
  end

  @doc false
  def start(account_id) do
    case DynamicSupervisor.start_child(Hireme.Gmail.Sessions, {Session, account_id}) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        Logger.error("gmail #{account_id}: session did not start: #{inspect(reason)}")
    end
  end

  # ---------------------------------------------------------------- link

  @doc """
  Links the account's Gmail: one IMAP login with `password` (an app
  password; Google shows it in groups of four, spaces are dropped), and
  only once it holds, the address and the sealed password are stored and
  the session starts. Answers `{:ok, %{status: "linking"}}` (the first
  sync reads 180 days back, then the mailbox is live), or `{:error, why}`:
  `:address` (not a Gmail address), `:limit` (too many tries), `:auth`
  (Gmail refused the password), `:imap_disabled`, `:all_mail_hidden`
  (All Mail is not shown in IMAP), `:unreachable`.
  """
  @spec link(pos_integer, String.t(), String.t()) :: {:ok, map} | {:error, atom}
  def link(account_id, address, password) when is_binary(address) and is_binary(password) do
    address = address |> String.trim() |> String.downcase()
    password = String.replace(password, ~r/\s+/, "")

    with :ok <- gmail_address(address),
         :ok <- link_limit(account_id),
         :ok <- verify(address, password),
         :ok <- store(account_id, address, password) do
      Audit.record(:mailbox_linked, %{address: address}, %{account_id: account_id})
      Accounts.notify(account_id, :mailbox_linked, %{address: address})
      restart(account_id)
      {:ok, %{status: "linking"}}
    end
  end

  def link(_account_id, _address, _password), do: {:error, :address}

  defp gmail_address(address) do
    if byte_size(address) <= 254 and
         address =~ ~r/\A[a-z0-9.!#$%&'*+\/=?^_`{|}~-]+@(gmail|googlemail)\.com\z/,
       do: :ok,
       else: {:error, :address}
  end

  defp link_limit(account_id) do
    case Security.limit(:mailbox_link, account_id) do
      :ok -> :ok
      {:error, :rate_limited} -> {:error, :limit}
    end
  end

  defp verify(address, password) do
    {host, port} = endpoint(:imap)

    with {:ok, conn} <- Imap.connect(host, port, cacerts()) |> link_error(),
         {:ok, conn} <- Imap.login(conn, address, password) |> link_error(),
         {:ok, _folders, conn} <- Imap.folders(conn) |> link_error() do
      Imap.logout(conn)
    end
  end

  defp link_error({:ok, _} = ok), do: ok
  defp link_error({:ok, _, _} = ok), do: ok
  defp link_error({:error, why}) when why in [:auth, :imap_disabled], do: {:error, why}
  defp link_error({:error, :no_all_mail}), do: {:error, :all_mail_hidden}
  defp link_error({:error, _}), do: {:error, :unreachable}

  # The row first (a put by the mail actor creates the singleton or names
  # it again), then the sealed password, and a new address starts reading
  # afresh.
  defp store(account_id, address, password) do
    before = mailbox(account_id)

    with {:ok, _} <- put(account_id, "mailboxes", %{provider: :gmail, address: address}),
         {:ok, _} <-
           command(account_id, "mailbox_state", 0, %{status: :linking, last_error: nil}),
         :ok <-
           Sequencer.server_write(
             account_id,
             "mailboxes",
             nil,
             Map.merge(
               %{secret: Security.seal(password, @password)},
               if(before && before.address == address,
                 do: %{},
                 else: %{folder: nil, uidvalidity: nil, last_uid: nil}
               )
             )
           ) do
      :ok
    else
      _ -> {:error, :unreachable}
    end
  end

  @doc """
  Unlinks the account's Gmail as the operator (`unlink_mail`); once that
  lands, `moved/2` forgets the password. `{:error, :no_mailbox}` when none
  is linked.
  """
  @spec unlink(pos_integer) :: :ok | {:error, :no_mailbox}
  def unlink(account_id) do
    c = Schema.command("unlink_mail")
    op = encode(:command, c.id, 0, %{}, %{}, 0)

    case Sequencer.call(account_id, %{label: "account", grants: Grants.operator(), key_id: nil}, [
           op
         ]) do
      {:ok, _rev, [_ack], []} -> :ok
      _ -> {:error, :no_mailbox}
    end
  end

  @doc """
  The operator unlinked (`unlink_mail`, seen by `moved/2`): the session
  stops, and the sealed password, the pipe and the cursor are erased.
  """
  @spec forget(pos_integer) :: :ok
  def forget(account_id) do
    Session.stop(account_id)

    Sequencer.server_write(account_id, "mailboxes", nil, %{
      secret: nil,
      pipe_id: nil,
      pipe_secret: nil,
      folder: nil,
      uidvalidity: nil,
      last_uid: nil
    })

    Audit.record(:mailbox_unlinked, %{}, %{account_id: account_id})
    Accounts.notify(account_id, :mailbox_unlinked, %{})
  end

  defp restart(account_id) do
    Session.stop(account_id)
    start(account_id)
  end

  @doc "The app password of the account's mailbox, for its session alone."
  @spec password(pos_integer) :: {:ok, String.t()} | :error
  def password(account_id) do
    case mailbox(account_id) do
      %{secret: sealed} when is_binary(sealed) -> Security.unseal(sealed, @password)
      _ -> :error
    end
  end

  @doc "The account's mailbox row, or nil."
  @spec mailbox(pos_integer) :: Mailbox.t() | nil
  def mailbox(account_id), do: Repo.with_account(account_id, fn -> Repo.one(Mailbox) end)

  # ---------------------------------------------------------------- pipe

  @doc """
  Turns the domain pipe on, or gives it a new secret: a fresh public id
  (12 base62) and secret, the secret sealed on the mailbox row and
  answered once, for the Email Worker's configuration.
  """
  @spec enable_pipe(pos_integer) ::
          {:ok, %{pipe_id: String.t(), secret: String.t()}} | {:error, :no_mailbox}
  def enable_pipe(account_id) do
    pipe_id = Security.base62(12)
    secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    case Sequencer.server_write(account_id, "mailboxes", nil, %{
           pipe_id: pipe_id,
           pipe_secret: Security.seal(secret, @pipe)
         }) do
      :ok ->
        Audit.record(:mailbox_pipe, %{pipe_id: pipe_id}, %{account_id: account_id})
        {:ok, %{pipe_id: pipe_id, secret: secret}}

      _ ->
        {:error, :no_mailbox}
    end
  end

  @doc "The account and unsealed secret of an enabled pipe (`HiremeWeb.MailInbound`)."
  @spec pipe(String.t()) :: {:ok, pos_integer, String.t()} | :error
  def pipe(pipe_id) when is_binary(pipe_id) do
    found =
      Repo.one(
        from(m in Mailbox,
          where: m.pipe_id == ^pipe_id and m.status != :unlinked,
          select: {m.account_id, m.pipe_secret}
        ),
        skip_account: true
      )

    with {account_id, sealed} when is_binary(sealed) <- found,
         {:ok, secret} <- Security.unseal(sealed, @pipe) do
      {:ok, account_id, secret}
    else
      _ -> :error
    end
  end

  # -------------------------------------------------------------- ingest

  @doc """
  One message from either pipe: `:gmail` (with `meta`: its Gmail ids,
  labels and internal date) or `:domain`. Answers `{:ok, :stored}`,
  `{:ok, :duplicate}` (a copy already held: Gmail's copy fills in its
  Gmail ids, nothing else moves), `{:ok, :ignored}` (not the search's:
  nothing kept), or `{:error, why}`.
  """
  @spec ingest(pos_integer, binary, :gmail | :domain, map) ::
          {:ok, :stored | :duplicate | :ignored} | {:error, term}
  def ingest(account_id, raw, pipe, meta \\ %{}) when pipe in [:gmail, :domain] do
    with {:ok, mail} <- Mime.parse(raw),
         {:ok, match} <- match(account_id, filer_input(mail, meta)) do
      if match["relevant"], do: keep(account_id, mail, pipe, meta), else: {:ok, :ignored}
    end
  end

  @doc """
  The filer's answer for a parsed message (or envelope): whether it is the
  search's, and where it would go. Read on the account's kernel.
  """
  @spec match(pos_integer, map) :: {:ok, map} | {:error, term}
  def match(account_id, input) do
    case query(account_id, "mail_match", input) do
      {:ok, %{"relevant" => _} = answer} -> {:ok, answer}
      _ -> {:error, :not_ready}
    end
  end

  @doc "A kernel query on the account's kernel, under every domain (the mail actor reads all)."
  @spec query(pos_integer, String.t(), map) ::
          {:ok, term} | {:refused, atom, map} | {:error, term}
  def query(account_id, op, args) do
    all = Grants.all()
    req = JSON.encode!(Map.put(args, "op", op))

    case Sequencer.read(account_id, fn k, _ -> Nif.query(k.res, req, all, all, false) end) do
      {:ok, {:ok, json}} -> {:ok, JSON.decode!(json)}
      {:ok, {:refused, code, data}} -> {:refused, code, JSON.decode!(data)}
      _ -> {:error, :unavailable}
    end
  end

  # The mail as an OutreachEmail (`Hireme.Outreach.Email.inbound/1`), put
  # by its Message-ID; the judge files it. A copy already held only gains
  # the Gmail ids it lacked (eliza's rules for the two pipes): nothing
  # else of a row moves, and its filing never.
  defp keep(account_id, mail, pipe, meta) do
    case held(account_id, mail.key) do
      # A copy from Gmail adds the ids it lacked, and says whether the mail
      # now sits in Spam or was rescued from it.
      %{"id" => id} = row ->
        if pipe == :gmail and meta[:msgid] != nil and
             (row["gmail_msgid"] == nil or spam?(row["labels"]) != spam?(meta[:labels])),
           do: duplicate(write(account_id, id, gmail(meta))),
           else: {:ok, :duplicate}

      _ ->
        item = Email.inbound(inbound(mail, pipe, meta))
        item = if meta[:direction] == :outbound, do: %{item | direction: :outbound}, else: item

        case run(account_id, Outreach.op(item)) do
          {:ok, _} -> {:ok, :stored}
          {:refused, code, data} -> {:error, {code, data}}
          {:error, _} = e -> e
        end
    end
  end

  # The row a Message-ID names, however its brackets were written.
  defp held(account_id, key) do
    where = %{"message_id" => %{"in" => [key, "<#{key}>"]}}

    case query(account_id, "find", %{"table" => "outreach", "where" => where, "limit" => 1}) do
      {:ok, %{"rows" => [row | _]}} -> row
      _ -> nil
    end
  end

  defp spam?(labels),
    do:
      labels
      |> List.wrap()
      |> Enum.flat_map(&String.split(&1, <<0x1F>>))
      |> Enum.member?("\\Spam")

  defp duplicate({:ok, _}), do: {:ok, :duplicate}
  defp duplicate({:refused, code, data}), do: {:error, {code, data}}
  defp duplicate(other), do: other

  defp write(account_id, id, values) do
    t = Schema.table("outreach")
    run(account_id, encode(:put, t.id, id, Map.new(t.cols, &{&1.name, &1}), values, 0))
  end

  defp inbound(mail, pipe, meta) do
    %{
      message_id: mail.key,
      in_reply_to: mail.in_reply_to,
      refs: mail.refs,
      from: mail.from && mail.from.addr,
      to: Enum.map(mail.to, & &1.addr),
      cc: Enum.map(mail.cc, & &1.addr),
      reply_to: Enum.find_value(mail.reply_to, & &1.addr),
      subject: mail.subject,
      text: mail.text,
      date: meta[:internaldate] || mail.date || System.os_time(:second),
      gmail_msgid: signed(meta[:msgid]),
      gmail_thrid: signed(meta[:thrid]),
      labels: meta[:labels],
      pipe: pipe,
      headers: mail.headers,
      report: mail.report
    }
  end

  defp gmail(meta) do
    %{
      gmail_msgid: signed(meta[:msgid]),
      gmail_thrid: signed(meta[:thrid]),
      labels: Enum.join(meta[:labels] || [], <<0x1F>>)
    }
  end

  # Gmail's ids are unsigned 64-bit; the rows and the kernel keep them as i64.
  @doc false
  def signed(nil), do: nil
  def signed(n) when n >= 0x8000_0000_0000_0000, do: n - 0x1_0000_0000_0000_0000
  def signed(n), do: n

  @doc "The filer's input for a parsed message: the envelope, its text, the Gmail thread."
  @spec filer_input(map, map) :: map
  def filer_input(mail, meta) do
    %{
      message_id: mail.message_id,
      in_reply_to: mail.in_reply_to,
      refs: mail.refs,
      from: address(mail.from),
      to: Enum.map(mail.to, &address/1),
      cc: Enum.map(mail.cc, &address/1),
      subject: mail.subject,
      text: mail.text,
      date: mail.date,
      reply_to: mail.reply_to |> List.first() |> address(),
      direction: Map.get(meta, :direction, :inbound),
      gmail_thrid: signed(meta[:thrid]),
      headers: mail.headers,
      report: mail.report
    }
  end

  defp address(nil), do: nil
  defp address(%{name: nil, addr: addr}), do: addr
  defp address(%{name: name, addr: addr}), do: "#{name} <#{addr}>"

  # --------------------------------------------------- the sequencer's side

  @doc """
  Called by the sequencer after each commit with the batch's deltas, in
  its own process: only messages leave here. An email mission gone in
  flight is the session's to send; an unlinked mailbox is forgotten.
  """
  @spec moved(pos_integer, list) :: :ok
  def moved(account_id, deltas) do
    Enum.each(deltas, fn
      {:put, %{name: "missions"}, %{state: :in_flight} = m, changed}
      when Outreach.is_email_mission(m) ->
        if changed == :all or :state in changed, do: Session.fire(account_id, m.id)

      {:put, %{name: "mailboxes"}, %{status: :unlinked}, changed} ->
        if changed == :all or :status in changed,
          do: Task.start(fn -> forget(account_id) end)

      _ ->
        :ok
    end)
  end

  # --------------------------------------------------------------- writes

  @doc false
  def actor, do: %{label: "mail", grants: Grants.mail(), key_id: nil}

  @doc """
  Runs one command as the mail actor on `target` (0: the singleton's row):
  `{:ok, ack}` or `{:refused, refusal, data}`.
  """
  @spec command(pos_integer, String.t(), non_neg_integer, map) ::
          {:ok, map} | {:refused, atom, map} | {:error, term}
  def command(account_id, name, target, values) do
    c = Schema.command(name)
    run(account_id, encode(:command, c.id, target, Map.new(c.params, &{&1.name, &1}), values, 0))
  end

  @doc "Puts `values` into `table` as the mail actor (a singleton's one row)."
  @spec put(pos_integer, String.t(), map) :: {:ok, map} | {:refused, atom, map} | {:error, term}
  def put(account_id, table, values) do
    t = Schema.table(table)
    run(account_id, encode(:put, t.id, 0, Map.new(t.cols, &{&1.name, &1}), values, 0))
  end

  defp encode(verb, subject, target, cols, values, flags) do
    cells =
      for {name, v} <- values, col = cols[to_string(name)] do
        if v == nil,
          do: {col.id, 0, nil},
          else: {col.id, Codec.cell_type(col), Codec.to_wire(col, v)}
      end

    raw = Codec.encode_op({Codec.op_id(), verb, flags, subject, target, nil, cells})
    {:ok, op, ""} = Codec.op(raw)
    op
  end

  defp run(account_id, op) do
    case Sequencer.call(account_id, actor(), [op]) do
      {:ok, _rev, [ack], []} -> {:ok, ack}
      {:ok, _rev, [], [nack]} -> {:refused, Schema.refusal_name(nack.code), nack.data}
      {:error, _} = e -> e
    end
  end

  # ---------------------------------------------------------------- config

  @doc false
  def endpoint(which) do
    conf = Application.get_env(:hireme, __MODULE__, [])

    case which do
      :imap -> Keyword.get(conf, :imap, {"imap.gmail.com", 993})
      :smtp -> Keyword.get(conf, :smtp, {"smtp.gmail.com", 465})
    end
  end

  @doc false
  def cacerts, do: Keyword.get(Application.get_env(:hireme, __MODULE__, []), :cacerts, :system)
end
