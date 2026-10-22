defmodule Hireme.Gmail.Session do
  @moduledoc """
  One linked mailbox's connector: the process that holds its IMAP
  connection to All Mail, walks the cursor, ingests the search's mail and
  sends the email missions fired under a key.

  A cycle: connect (the app password is unsealed here and nowhere else),
  send what is in flight, read every UID past the cursor (the first time,
  180 days of envelopes) and then Spam's, keep what the filer takes and
  label it `hireme`, then IDLE until Gmail pushes new mail, a mission is
  fired, or 25 minutes pass (Gmail ends an IDLE at 29).

  Sending is the operator's rule 2 with no double send. A shot's
  Message-ID is minted and stamped on the mission before SMTP, and a
  stamped mission is looked for in All Mail (Gmail's index, and the
  headers of what is newer than the cursor) before it is ever sent again,
  never sooner than 90 seconds after its last attempt in this process (or
  after the process started). A shot that may have reached Gmail (the
  connection lost after the message's last dot) is never handed back
  until All Mail has been asked. `landed` burns the shot; `failed` hands
  the mission back to fire ready under the same key, its Message-ID kept,
  so a refire is looked for again first. A first-contact mail goes with
  the CV the key covered, or not at all; Gmail drafts are never read as
  mail.

  Trouble: a refused app password stops the mailbox (`auth_failed`, the
  trail, a notice) and is tried again at most once an hour; network
  trouble backs off from one minute to 30, and after five failures in a
  row the shots known not to have gone out are handed back.
  """

  use GenServer, restart: :transient

  import Ecto.Query
  require Logger

  alias Hireme.{Accounts, Audit, Blobs, Gmail, Repo, Security}
  alias Hireme.Gmail.{Imap, Mime, Smtp}
  alias Hireme.Outreach.Email
  alias Hireme.Rows.{CvVersion, Mission}

  # Envelopes per IMAP fetch.
  @batch 100
  @renew_ms :timer.minutes(25)
  # How long Gmail may take to show a mail it accepted in All Mail.
  @settle_ms 90_000
  # How often an idle mailbox notes its sync on the row.
  @note_ms :timer.minutes(10)
  # A shot's temporary failures before it goes back to fire ready.
  @attempts 3
  # Connection failures in a row before the shots in flight go back.
  @patience 5

  defstruct [
    :account_id,
    :imap,
    :folder,
    :junk,
    :junk_validity,
    :address,
    :status,
    :last_uid,
    # The highest All Mail UID the last sync listed, kept or held, and the
    # next UID All Mail had when it was selected.
    :listed,
    :uidnext,
    :noted,
    :renew,
    :retry,
    :started,
    locked: nil,
    # Spam's UIDs read this session: Gmail empties Spam after 30 days, so
    # it is read whole once a session and then only what is new.
    junk_seen: MapSet.new(),
    tries: 0,
    # Per mission: the sends Gmail answered with a no (or that never reached
    # it whole), and the time of an attempt that may have reached Gmail,
    # kept until All Mail settles it: its settle clock outlives a failed
    # shot and a refire.
    attempts: %{},
    tried: %{}
  ]

  # ------------------------------------------------------------------ API

  @doc false
  def child_spec(account_id),
    do: %{
      id: {__MODULE__, account_id},
      start: {__MODULE__, :start_link, [account_id]},
      restart: :transient
    }

  @doc false
  def start_link(account_id),
    do: GenServer.start_link(__MODULE__, account_id, name: via(account_id))

  defp via(account_id), do: {:via, Registry, {Hireme.Gmail.Registry, account_id}}

  @doc "A mission went in flight: the session sends it now (or when it is connected again)."
  @spec fire(pos_integer, pos_integer) :: :ok
  def fire(account_id, mission_id), do: GenServer.cast(via(account_id), {:fire, mission_id})

  @doc "Stops the account's session, if one runs."
  @spec stop(pos_integer) :: :ok
  def stop(account_id) do
    case Registry.lookup(Hireme.Gmail.Registry, account_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Hireme.Gmail.Sessions, pid)
      [] -> :ok
    end

    :ok
  end

  # --------------------------------------------------------------- server

  @impl GenServer
  def init(account_id) do
    Repo.put_account(account_id)
    s = %__MODULE__{account_id: account_id, started: now()}

    # A password Gmail refused waits its hour, across restarts too.
    s =
      case Gmail.mailbox(account_id) do
        %{status: :auth_failed} ->
          %{s | status: :auth_failed, locked: now() + Security.mail_credential_retry_ms()}

        _ ->
          s
      end

    {:ok, s, {:continue, :cycle}}
  end

  @impl GenServer
  def handle_continue(:cycle, s), do: cycle(s)

  @impl GenServer
  def handle_cast({:fire, _mission_id}, s), do: wake(s)

  @impl GenServer
  def handle_info(tick, s) when tick in [:wake, :renew, :retry], do: wake(s)

  def handle_info({:ssl, socket, data}, %{imap: %Imap{socket: socket, idle: tag}} = s)
      when tag != nil do
    case Imap.idle_data(s.imap, data) do
      {:ok, pushed, imap} ->
        s = %{s | imap: imap}

        cond do
          # Gmail ends an IDLE it has held too long; a new connection follows at once.
          Enum.any?(pushed, &match?({:bye, _}, &1)) -> wake(drop(s))
          Enum.any?(pushed, &match?({:exists, _}, &1)) -> wake(s)
          true -> {:noreply, s}
        end

      {:error, why} ->
        trouble(drop(s), why)
    end
  end

  def handle_info({:ssl_closed, socket}, %{imap: %Imap{socket: socket}} = s),
    do: trouble(drop(s), {:network, :closed})

  def handle_info({:ssl_error, socket, why}, %{imap: %Imap{socket: socket}} = s),
    do: trouble(drop(s), {:network, why})

  def handle_info(_, s), do: {:noreply, s}

  @impl GenServer
  def terminate(_reason, %{imap: %Imap{} = imap}), do: Imap.close(imap)
  def terminate(_reason, _s), do: :ok

  defp wake(s) do
    s = %{s | renew: cancel(s.renew), retry: cancel(s.retry)}

    s =
      case s.imap do
        %Imap{idle: tag} = imap when tag != nil ->
          case Imap.done(imap) do
            {:ok, _pushed, imap} -> %{s | imap: imap}
            {:error, _} -> %{s | imap: nil}
          end

        _ ->
          s
      end

    cycle(s)
  end

  defp cycle(s) do
    with {:ok, s} <- connected(s),
         {:ok, s} <- shoot_all(s),
         {:ok, s} <- sync(s),
         {:ok, s} <- spam(s),
         {:ok, s} <- idle(s) do
      {:noreply, %{s | tries: 0}}
    else
      {:stop, s} -> {:stop, :normal, drop(s)}
      {:error, why, s} -> trouble(s, why)
    end
  end

  defp drop(%{imap: %Imap{} = imap} = s) do
    Imap.close(imap)
    %{s | imap: nil}
  end

  defp drop(s), do: s

  # ------------------------------------------------------------- connect

  defp connected(%{imap: %Imap{}} = s), do: {:ok, s}

  defp connected(%{locked: until} = s) when until != nil do
    if now() < until, do: {:error, :locked, s}, else: connected(%{s | locked: nil})
  end

  defp connected(s) do
    case Gmail.mailbox(s.account_id) do
      %{status: status, secret: sealed} = box when status != :unlinked and is_binary(sealed) ->
        {host, port} = Gmail.endpoint(:imap)

        with {:ok, password} <- unsealed(s),
             {:ok, conn} <- Imap.connect(host, port, Gmail.cacerts()),
             {:ok, conn} <- Imap.login(conn, box.address, password),
             {:ok, %{all: folder, junk: junk}, conn} <- Imap.folders(conn),
             {:ok, info, conn} <- Imap.select(conn, folder) do
          s = %{s | imap: conn, folder: folder, junk: junk, address: box.address, status: status}

          {:ok, cursor(s, box, folder, info)}
        else
          {:error, why} -> {:error, why, %{s | imap: nil}}
        end

      _ ->
        {:stop, s}
    end
  end

  defp unsealed(s) do
    case Gmail.password(s.account_id) do
      {:ok, password} -> {:ok, password}
      # A seal that no longer opens (the application secret changed) is a
      # credential to enter again.
      :error -> {:error, :auth}
    end
  end

  # All Mail named again, or its UIDs renumbered: the walk starts afresh
  # (Message-IDs keep what is already held from coming twice).
  defp cursor(s, box, folder, %{uidvalidity: validity, uidnext: next}) do
    cursor(%{s | uidnext: next}, box, folder, validity)
  end

  defp cursor(s, box, folder, validity) do
    if box.folder == folder and box.uidvalidity == validity do
      %{s | last_uid: box.last_uid, listed: box.last_uid}
    else
      server(s, %{folder: folder, uidvalidity: validity, last_uid: nil})
      %{s | last_uid: nil, listed: nil}
    end
  end

  defp server(s, cells), do: Hireme.Sequencer.server_write(s.account_id, "mailboxes", nil, cells)

  # ---------------------------------------------------------------- read

  defp sync(s) do
    found =
      if s.last_uid,
        do: Imap.since_uid(s.imap, s.last_uid + 1),
        else: Imap.since_date(s.imap, Date.add(Date.utc_today(), -Security.mail_backfill_days()))

    case found do
      {:ok, uids, imap} ->
        walk(%{s | imap: imap, listed: Enum.max(uids, fn -> s.listed end)}, uids)

      {:error, why} ->
        {:error, why, %{s | imap: nil}}
    end
  end

  # A first sync that found nothing in its window starts after what All Mail
  # held: what came before it is older than the backfill reads.
  defp walk(%{last_uid: nil, uidnext: next} = s, []) when is_integer(next) and next > 1,
    do: walk(%{advance(s, next - 1) | listed: max(s.listed || 0, next - 1)}, [])

  defp walk(s, []), do: {:ok, noted(s)}

  defp walk(s, uids) do
    {batch, rest} = Enum.split(uids, @batch)

    with {:ok, envelopes, imap} <- Imap.envelopes(s.imap, batch),
         {:ok, kept, held, imap} <- keep(%{s | imap: imap}, Enum.sort_by(envelopes, & &1.uid)),
         {:ok, imap} <- Imap.label(imap, kept, "hireme") do
      case held do
        nil -> walk(advance(%{s | imap: imap}, List.last(batch)), rest)
        # A mail the filer could not answer yet holds the walk before it.
        {:at, upto} -> {:ok, later(advance(%{s | imap: imap}, upto), @renew_ms)}
      end
    else
      {:error, why} -> {:error, why, %{s | imap: nil}}
    end
  end

  # Walks the envelopes in UID order: the UIDs kept (to label), and where
  # the walk was held, if it was: the last UID settled before the mail the
  # filer could not answer.
  defp keep(s, envelopes) do
    Enum.reduce_while(envelopes, {:ok, [], nil, s.imap, s.last_uid}, fn env,
                                                                        {:ok, kept, nil, imap,
                                                                         upto} ->
      case take(%{s | imap: imap}, env) do
        {:kept, imap} -> {:cont, {:ok, [env.uid | kept], nil, imap, env.uid}}
        {:dropped, imap} -> {:cont, {:ok, kept, nil, imap, env.uid}}
        {:wait, imap} -> {:halt, {:ok, kept, {:at, upto}, imap, upto}}
        {:error, why} -> {:halt, {:error, why}}
      end
    end)
    |> case do
      {:ok, kept, held, imap, _} -> {:ok, kept, held, imap}
      error -> error
    end
  end

  # A Gmail draft is no mail: every autosave is a new message.
  defp take(s, %{labels: labels} = env) when is_list(labels) and labels != [] do
    if "\\Draft" in labels, do: {:dropped, s.imap}, else: take_mail(s, env)
  end

  defp take(s, env), do: take_mail(s, env)

  defp take_mail(s, env) do
    with {:ok, envelope} <- Mime.parse(Map.get(env, :header, "")),
         env = Map.put(env, :direction, direction(envelope, s.address)),
         {:ok, %{"relevant" => true}} <-
           Gmail.match(s.account_id, Gmail.filer_input(envelope, env)) do
      if Map.get(env, :size, 0) > Security.mail_max_bytes(),
        do: {:dropped, s.imap},
        else: fetch(s, env)
    else
      {:ok, %{"relevant" => false}} -> {:dropped, s.imap}
      {:error, :too_large} -> {:dropped, s.imap}
      _ -> {:wait, s.imap}
    end
  end

  # Mail from the linked address (as Gmail reads it: dots and a +tag in the
  # name ignored, googlemail.com as gmail.com) is mail the operator sent.
  defp direction(%{from: %{addr: from}}, address) when is_binary(from) and is_binary(address) do
    if gmail_name(from) == gmail_name(address), do: :outbound, else: :inbound
  end

  defp direction(_mail, _address), do: :inbound

  defp gmail_name(addr) do
    case String.split(String.downcase(addr), "@") do
      [local, domain] when domain in ["gmail.com", "googlemail.com"] ->
        [name | _] = String.split(local, "+")
        String.replace(name, ".", "") <> "@gmail.com"

      _ ->
        String.downcase(addr)
    end
  end

  defp fetch(s, env) do
    case Imap.message(s.imap, env.uid) do
      {:ok, %{raw: raw}, imap} ->
        case Gmail.ingest(s.account_id, raw, :gmail, env) do
          {:ok, outcome} when outcome in [:stored, :duplicate] -> {:kept, imap}
          {:ok, :ignored} -> {:dropped, imap}
          {:error, why} when why in [:not_ready, :unavailable] -> {:wait, imap}
          {:error, why} -> refused(s, env, why, imap)
        end

      {:ok, nil, imap} ->
        {:dropped, imap}

      {:error, _} = e ->
        e
    end
  end

  # Spam, under the same rules as All Mail: the filer's candidates kept and
  # labelled, marked with Gmail's own \\Spam label (the page's "rescue it
  # there" badge), nothing moved; then All Mail is selected again, which
  # the searches and the IDLE read.
  defp spam(%{junk: nil} = s), do: {:ok, s}

  defp spam(s) do
    with {:ok, info, imap} <- Imap.select(s.imap, s.junk),
         s = junk_validity(%{s | imap: imap}, info.uidvalidity),
         {:ok, uids, imap} <- Imap.since_uid(s.imap, 1),
         {:ok, s} <-
           spam_walk(%{s | imap: imap}, Enum.reject(uids, &MapSet.member?(s.junk_seen, &1))),
         {:ok, _info, imap} <- Imap.select(s.imap, s.folder) do
      {:ok, %{s | imap: imap}}
    else
      {:error, why} -> {:error, why, %{s | imap: nil}}
    end
  end

  defp junk_validity(%{junk_validity: v} = s, v), do: s
  defp junk_validity(s, v), do: %{s | junk_validity: v, junk_seen: MapSet.new()}

  defp spam_walk(s, []), do: {:ok, s}

  defp spam_walk(s, uids) do
    {batch, rest} = Enum.split(uids, @batch)

    with {:ok, envelopes, imap} <- Imap.envelopes(s.imap, batch) do
      {kept, seen, held, imap} =
        envelopes
        |> Enum.sort_by(& &1.uid)
        |> Enum.reduce_while({[], s.junk_seen, false, imap}, fn env, {kept, seen, _, imap} ->
          env = Map.update(env, :labels, ["\\Spam"], &Enum.uniq(&1 ++ ["\\Spam"]))

          case take(%{s | imap: imap}, env) do
            {:kept, imap} -> {:cont, {[env.uid | kept], MapSet.put(seen, env.uid), false, imap}}
            {:dropped, imap} -> {:cont, {kept, MapSet.put(seen, env.uid), false, imap}}
            {:wait, imap} -> {:halt, {kept, seen, true, imap}}
            {:error, why} -> {:halt, {kept, seen, {:error, why}, nil}}
          end
        end)

      case held do
        {:error, why} ->
          {:error, why}

        _ ->
          with {:ok, imap} <- Imap.label(imap, kept, "hireme") do
            s = %{s | imap: imap, junk_seen: seen}
            if held, do: {:ok, s}, else: spam_walk(s, rest)
          end
      end
    end
  end

  # The judge refused it for good: logged by UID and refusal code only, and
  # passed over.
  defp refused(s, env, code, imap) do
    Logger.error("gmail #{s.account_id}: uid #{env.uid} not kept: #{inspect(code)}")
    {:dropped, imap}
  end

  defp advance(s, nil), do: s
  defp advance(%{last_uid: uid} = s, uid), do: s

  defp advance(s, uid) do
    server(s, %{last_uid: uid})
    %{s | last_uid: uid}
  end

  defp noted(s) do
    if s.status != :live or s.noted == nil or now() - s.noted > @note_ms do
      state(s, :live, nil, %{last_sync_at: DateTime.utc_now()})
      %{s | status: :live, noted: now()}
    else
      s
    end
  end

  defp state(s, status, error, more \\ %{}) do
    Gmail.command(
      s.account_id,
      "mailbox_state",
      0,
      Map.merge(%{status: status, last_error: error}, more)
    )
  end

  # ---------------------------------------------------------------- send

  # Shots go first in a cycle: no catch-up holds one back.
  defp shoot_all(s) do
    s.account_id
    |> in_flight()
    |> Enum.reduce_while({:ok, s}, fn m, {:ok, s} ->
      case shoot(s, m) do
        {:ok, s} -> {:cont, {:ok, s}}
        error -> {:halt, error}
      end
    end)
  end

  defp in_flight(account_id) do
    Repo.with_account(account_id, fn ->
      Repo.all(
        from(m in Mission, where: m.kind == :email and m.state == :in_flight, order_by: m.id)
      )
    end)
  end

  # Unstamped: mint, stamp, send. Stamped: a shot that may have left before
  # (a restart, a lost connection, a refire), so All Mail is asked first,
  # and only once Gmail has had time to show it.
  defp shoot(s, %{message_id: nil} = m) do
    id = mint(s.address)

    case Gmail.command(s.account_id, "stamp", m.id, %{message_id: id}) do
      {:ok, _} -> transmit(s, %{m | message_id: id})
      other -> {:ok, said(s, m, "stamp", other)}
    end
  end

  defp shoot(s, m) do
    case Imap.message_id(s.imap, m.message_id, s.listed || 0) do
      {:ok, [uid | _], imap} ->
        landed(%{s | imap: imap}, m, uid)

      # Never sent again without a look that can find it.
      {:ok, :unsearchable, imap} ->
        {:ok, said(%{s | imap: imap}, m, "search", :unsearchable)}

      {:ok, [], imap} ->
        s = %{s | imap: imap}
        wait = settle() - (now() - Map.get(s.tried, m.id, s.started))
        if wait > 0, do: {:ok, later(s, wait)}, else: transmit(s, m)

      {:error, why} ->
        {:error, why, %{s | imap: nil}}
    end
  end

  defp mint(address) do
    [_, domain] = String.split(address, "@")

    "hm." <>
      Base.encode32(:crypto.strong_rand_bytes(15), case: :lower, padding: false) <> "@" <> domain
  end

  defp transmit(s, m) do
    with :ok <- under_cap(s),
         {:ok, rcpts, mail} <- compose(s, m),
         {:ok, password} <- unsealed(s) do
      # From here the mail may reach Gmail.
      s = %{s | tried: Map.put(s.tried, m.id, now())}
      {host, port} = Gmail.endpoint(:smtp)
      at = %{host: host, port: port, cacerts: Gmail.cacerts()}

      case Smtp.deliver(at, s.address, password, s.address, rcpts, Smtp.compose(mail)) do
        {:ok, _} ->
          located(s, m, 5)

        {:error, :auth} ->
          {:error, :auth, unsent(s, m)}

        {:error, {:permanent, reply}} ->
          {:ok, failed(unsent(s, m), m, reply)}

        # Gmail may hold it: only All Mail, asked after the settle, says.
        {:error, {:unknown, _}} ->
          {:ok, later(s, settle())}

        {:error, why} ->
          again(unsent(s, m), m, why)
      end
    else
      {:refuse, why} -> {:ok, failed(s, m, why)}
      {:error, :auth} -> {:error, :auth, s}
    end
  end

  # Gmail took it: its ids, once All Mail shows it (the headers past the
  # cursor show it at once); landed without them otherwise, the next sync's
  # copy filling them in.
  defp located(s, m, n) do
    case Imap.message_id(s.imap, m.message_id, s.listed || 0) do
      {:ok, [uid | _], imap} ->
        landed(%{s | imap: imap}, m, uid)

      {:ok, [], imap} when n > 0 ->
        Process.sleep(2_000)
        located(%{s | imap: imap}, m, n - 1)

      {:ok, _, imap} ->
        done(%{s | imap: imap}, m, %{})

      {:error, why} ->
        {:ok, s} = done(%{s | imap: nil}, m, %{})
        {:error, why, s}
    end
  end

  defp landed(s, m, uid) do
    case Imap.envelopes(s.imap, [uid]) do
      {:ok, [env | _], imap} ->
        done(%{s | imap: imap}, m, %{
          gmail_msgid: Gmail.signed(env[:msgid]),
          gmail_thrid: Gmail.signed(env[:thrid])
        })

      {:ok, [], imap} ->
        done(%{s | imap: imap}, m, %{})

      {:error, why} ->
        {:ok, s} = done(%{s | imap: nil}, m, %{})
        {:error, why, s}
    end
  end

  # A landed the judge refuses leaves the shot in flight, its settle clock
  # kept: the next cycle finds it in All Mail again and tries once more.
  defp done(s, m, ids) do
    case Gmail.command(s.account_id, "landed", m.id, ids) do
      {:ok, _} -> {:ok, forget(s, m)}
      other -> {:ok, said(s, m, "landed", other)}
    end
  end

  # Gmail said no (or could not be reached before the message was whole):
  # tried again, and after three such answers handed back.
  defp again(s, m, why) do
    tries = Map.get(s.attempts, m.id, 0) + 1
    s = %{s | attempts: Map.put(s.attempts, m.id, tries)}

    if tries >= @attempts,
      do: {:ok, failed(s, m, describe(why))},
      else: {:ok, later(s, Security.mail_backoff(tries))}
  end

  defp failed(s, m, reason) do
    case Gmail.command(s.account_id, "failed", m.id, %{reason: Security.clip(reason)}) do
      {:ok, _} -> %{s | attempts: Map.delete(s.attempts, m.id)}
      other -> said(s, m, "failed", other)
    end
  end

  # Gmail answered, or never had the whole of it: it did not take this one.
  defp unsent(s, m), do: %{s | tried: Map.delete(s.tried, m.id)}

  defp forget(s, m),
    do: %{s | tried: Map.delete(s.tried, m.id), attempts: Map.delete(s.attempts, m.id)}

  # Handed back: only the shots known not to have reached Gmail (never
  # stamped, or last answered with a no in this process). One that may
  # have (its last attempt lost after the last dot, or stamped before this
  # process) stays in flight until All Mail can be asked.
  defp fail_all(s, reason) do
    s.account_id
    |> in_flight()
    |> Enum.filter(
      &(&1.message_id == nil or
          (Map.has_key?(s.attempts, &1.id) and not Map.has_key?(s.tried, &1.id)))
    )
    |> Enum.reduce(s, &failed(&2, &1, reason))
  end

  # How long Gmail may take to show a mail it took in All Mail.
  defp settle,
    do: Keyword.get(Application.get_env(:hireme, Gmail, []), :settle_ms, @settle_ms)

  # A command the judge refused, logged by mission and refusal code.
  defp said(s, m, what, {:refused, code, _data}) do
    Logger.error("gmail #{s.account_id}: mission #{m.id}: #{what} refused #{code}")
    s
  end

  defp said(s, m, what, other) do
    Logger.error("gmail #{s.account_id}: mission #{m.id}: #{what}: #{inspect(other)}")
    s
  end

  # The judge counted the shot against the cap when it fired; the node
  # counts again what landed today before it sends.
  defp under_cap(s) do
    today = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")

    landed =
      Repo.with_account(s.account_id, fn ->
        Repo.aggregate(
          from(m in Mission,
            where: m.kind == :email and m.state == :fired and m.fired_at >= ^today
          ),
          :count
        )
      end)

    cap = with %{daily_cap: cap} <- Gmail.mailbox(s.account_id), do: cap

    if is_integer(cap) and landed < cap,
      do: :ok,
      else: {:refuse, "the daily cap of #{cap} sends is spent; it resets at midnight UTC"}
  end

  # What goes out is the mission as the key froze it (`Email.shot/2`), from
  # the linked address.
  defp compose(s, m) do
    shot = Email.shot(Map.from_struct(m), s.address)
    to = Email.recipients(shot)
    cc = Email.copies(shot)

    cond do
      to == [] -> {:refuse, "no recipient"}
      length(to) + length(cc) > 10 -> {:refuse, "more than 10 recipients"}
      true -> with {:ok, files} <- cv(s, m), do: {:ok, to ++ cc, mail(s, shot, files)}
    end
  end

  defp mail(s, shot, files) do
    %{
      from: s.address,
      from_name: from_name(s.account_id),
      to: Email.recipients(shot),
      cc: Email.copies(shot),
      subject: shot.subject || "",
      body: shot.body || "",
      message_id: shot.message_id,
      in_reply_to: shot.in_reply_to,
      refs: shot.refs,
      date: System.os_time(:second),
      attachments: files
    }
  end

  # A first contact carries the CV the fire key's hash covered (the
  # mission keeps its version from the shot); a reply in a thread goes
  # without (shannon's ruling).
  defp cv(_s, %{in_reply_to: irt}) when irt not in [nil, ""], do: {:ok, []}

  defp cv(s, %{cv_version_id: version}) when is_integer(version) do
    with %{blob_sha: sha} = v when is_binary(sha) <-
           Repo.with_account(s.account_id, fn -> Repo.get(CvVersion, version) end),
         %{data: data, type: type} <-
           Repo.with_account(s.account_id, fn -> Blobs.about(sha, [:data]) end) do
      {:ok, [%{name: v.blob_name || "cv", type: type, data: data}]}
    else
      _ -> {:refuse, "cv_file: the CV the key covered has no file to attach"}
    end
  end

  defp cv(_s, _m), do: {:refuse, "cv_file: the mission names no CV version"}

  defp from_name(account_id) do
    Repo.one(
      from(a in Hireme.Rows.Account, where: a.id == ^account_id, select: a.name),
      skip_account: true
    )
  end

  # ------------------------------------------------------------- trouble

  defp trouble(s, :auth) do
    s = drop(s)

    if s.status != :auth_failed do
      state(s, :auth_failed, "Gmail refused the app password: create a new one and link again")
      Audit.record(:mailbox_auth_failed, %{}, %{account_id: s.account_id})
      Accounts.notify(s.account_id, :mailbox_auth_failed, %{})
    end

    s = fail_all(%{s | status: :auth_failed}, "the mailbox's app password was refused")
    retry = Security.mail_credential_retry_ms()
    {:noreply, later(%{s | locked: now() + retry}, retry)}
  end

  defp trouble(s, :locked), do: {:noreply, later(s, max(s.locked - now(), 1_000))}

  defp trouble(s, why) when why in [:imap_disabled, :no_all_mail, :not_gmail] do
    s = drop(s)
    if s.status != :error, do: state(s, :error, settings(why))
    {:noreply, later(%{s | status: :error}, Security.mail_backoff(@patience))}
  end

  defp trouble(s, why) do
    s = drop(s)
    tries = s.tries + 1
    if s.status != :error, do: state(s, :error, "Gmail could not be reached; retrying")
    s = %{s | status: :error, tries: tries}

    s =
      if tries == @patience,
        do: fail_all(s, "Gmail could not be reached (#{describe(why)})"),
        else: s

    {:noreply, later(s, Security.mail_backoff(tries - 1))}
  end

  defp settings(:imap_disabled),
    do: "IMAP is off in Gmail's settings: turn it on (Forwarding and POP/IMAP)"

  defp settings(:no_all_mail),
    do: "All Mail is hidden from IMAP: show it in Gmail's label settings"

  defp settings(:not_gmail), do: "the server is not Gmail"

  defp describe({:network, why}), do: "network: #{inspect(why)}"
  defp describe({:temporary, reply}), do: reply
  defp describe(why), do: inspect(why)

  # ---------------------------------------------------------------- time

  # Mail that came while other commands ran was counted in their answers,
  # never pushed to an IDLE: one look past what the sync listed first.
  defp idle(%{imap: nil} = s), do: {:error, {:network, :closed}, s}

  defp idle(s) do
    case Imap.since_uid(s.imap, (s.listed || 0) + 1) do
      {:ok, [], imap} -> really_idle(%{s | imap: imap})
      {:ok, _new, imap} -> cycle_again(%{s | imap: imap})
      {:error, why} -> {:error, why, %{s | imap: nil}}
    end
  end

  defp cycle_again(s) do
    send(self(), :wake)
    {:ok, s}
  end

  defp really_idle(s) do
    case Imap.idle(s.imap) do
      {:ok, pushed, imap} ->
        if Enum.any?(pushed, &match?({:exists, _}, &1)), do: send(self(), :wake)
        {:ok, %{s | imap: imap, renew: Process.send_after(self(), :renew, @renew_ms)}}

      {:error, why} ->
        {:error, why, %{s | imap: nil}}
    end
  end

  # The earliest of what waits: a deferred shot, a retry.
  defp later(s, ms) do
    case s.retry && Process.read_timer(s.retry) do
      left when is_integer(left) and left <= ms ->
        s

      _ ->
        cancel(s.retry)
        %{s | retry: Process.send_after(self(), :retry, ms)}
    end
  end

  defp cancel(nil), do: nil

  defp cancel(ref) do
    Process.cancel_timer(ref)
    nil
  end

  defp now, do: System.monotonic_time(:millisecond)
end
