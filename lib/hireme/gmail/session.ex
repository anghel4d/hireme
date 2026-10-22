defmodule Hireme.Gmail.Session do
  @moduledoc """
  One linked mailbox's connector: the process that holds its IMAP
  connection to All Mail, walks the cursor, ingests the search's mail and
  sends the email missions fired under a key.

  A cycle: connect (the app password is unsealed here and nowhere else),
  read every UID past the cursor (the first time, 180 days of envelopes),
  keep what the filer takes and label it `hireme`, send what is in flight,
  then IDLE until Gmail pushes new mail, a mission is fired, or 25 minutes
  pass (Gmail ends an IDLE at 29).

  Sending is the operator's rule 2 with no double send: a shot's
  Message-ID is minted and stamped on the mission before SMTP, a stamped
  mission is looked for in All Mail before it is ever sent again (after a
  restart, once Gmail has had 90 seconds to show it), `landed` burns the
  shot, `failed` hands the mission back to fire ready under the same key.
  A first-contact mail goes with the application's CV file or not at all.

  Trouble: a refused app password stops the mailbox (`auth_failed`, the
  trail, a notice) and is tried again at most once an hour; network
  trouble backs off from one minute to 30, and after five failures in a
  row the missions in flight are handed back.
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
    :address,
    :status,
    :daily_cap,
    :last_uid,
    :noted,
    :renew,
    :retry,
    :started,
    locked: nil,
    tries: 0,
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
          Enum.any?(pushed, &match?({:bye, _}, &1)) -> cycle(drop(s))
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
         {:ok, s} <- sync(s),
         {:ok, s} <- shoot_all(s),
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
             {:ok, folder, conn} <- Imap.all_mail(conn),
             {:ok, info, conn} <- Imap.select(conn, folder) do
          s = %{s | imap: conn, address: box.address, status: status, daily_cap: box.daily_cap}
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
  defp cursor(s, box, folder, %{uidvalidity: validity}) do
    if box.folder == folder and box.uidvalidity == validity do
      %{s | last_uid: box.last_uid}
    else
      server(s, %{folder: folder, uidvalidity: validity, last_uid: nil})
      %{s | last_uid: nil}
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
      {:ok, uids, imap} -> walk(%{s | imap: imap}, uids)
      {:error, why} -> {:error, why, %{s | imap: nil}}
    end
  end

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

  defp take(s, env) do
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

  # Mail from the linked address is mail hireme or the operator sent.
  defp direction(%{from: %{addr: addr}}, addr) when is_binary(addr), do: :outbound
  defp direction(_mail, _address), do: :inbound

  defp fetch(s, env) do
    case Imap.message(s.imap, env.uid) do
      {:ok, %{raw: raw}, imap} ->
        case Gmail.ingest(s.account_id, raw, :gmail, env) do
          {:ok, outcome} when outcome in [:stored, :duplicate] -> {:kept, imap}
          {:ok, :ignored} -> {:dropped, imap}
          {:error, :not_ready} -> {:wait, imap}
          {:error, why} -> refused(s, env, why, imap)
        end

      {:ok, nil, imap} ->
        {:dropped, imap}

      {:error, _} = e ->
        e
    end
  end

  # The judge refused it: logged by UID and refusal code only (its data may
  # quote the mail), and passed over.
  defp refused(s, env, why, imap) do
    code = with {code, _data} <- why, do: code
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

  # Unstamped: mint, stamp, send. Stamped: a shot that may have left, so
  # All Mail is asked first.
  defp shoot(s, %{message_id: nil} = m) do
    id = mint(s.address)

    case Gmail.command(s.account_id, "stamp", m.id, %{message_id: id}) do
      {:ok, _} -> transmit(s, %{m | message_id: id})
      _ -> {:ok, s}
    end
  end

  defp shoot(s, m) do
    case Imap.message_id(s.imap, m.message_id) do
      {:ok, [uid | _], imap} ->
        landed(%{s | imap: imap}, m, uid)

      {:ok, [], imap} ->
        s = %{s | imap: imap}
        wait = @settle_ms - (now() - Map.get(s.tried, m.id, s.started))
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
      s = %{
        s
        | tried: Map.put(s.tried, m.id, now()),
          attempts: Map.update(s.attempts, m.id, 1, &(&1 + 1))
      }

      {host, port} = Gmail.endpoint(:smtp)
      at = %{host: host, port: port, cacerts: Gmail.cacerts()}

      case Smtp.deliver(at, s.address, password, s.address, rcpts, Smtp.compose(mail)) do
        {:ok, _} -> located(s, m, 5)
        {:error, :auth} -> {:error, :auth, s}
        {:error, {:permanent, reply}} -> {:ok, failed(s, m, reply)}
        {:error, other} -> again(s, m, other)
      end
    else
      {:refuse, why} -> {:ok, failed(s, m, why)}
      {:error, :auth} -> {:error, :auth, s}
    end
  end

  # Gmail accepted it: its ids, once All Mail shows it (a few seconds at
  # most); the next sync fills them in otherwise.
  defp located(s, m, 0), do: done(s, m, %{})

  defp located(s, m, n) do
    case Imap.message_id(s.imap, m.message_id) do
      {:ok, [uid | _], imap} ->
        landed(%{s | imap: imap}, m, uid)

      {:ok, [], imap} ->
        Process.sleep(2_000)
        located(%{s | imap: imap}, m, n - 1)

      {:error, _} ->
        done(%{s | imap: nil}, m, %{})
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
        {:error, why, %{s | imap: nil}}
    end
  end

  defp done(s, m, ids) do
    Gmail.command(s.account_id, "landed", m.id, ids)
    {:ok, forget(s, m)}
  end

  defp again(s, m, why) do
    if Map.get(s.attempts, m.id, 0) >= @attempts,
      do: {:ok, failed(s, m, describe(why))},
      else: {:ok, later(s, Security.mail_backoff(Map.get(s.attempts, m.id, 0)))}
  end

  defp failed(s, m, reason) do
    Gmail.command(s.account_id, "failed", m.id, %{reason: Security.clip(reason)})
    forget(s, m)
  end

  defp forget(s, m),
    do: %{s | tried: Map.delete(s.tried, m.id), attempts: Map.delete(s.attempts, m.id)}

  defp fail_all(s, reason) do
    s.account_id |> in_flight() |> Enum.reduce(s, &failed(&2, &1, reason))
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

    if landed < (s.daily_cap || 0),
      do: :ok,
      else: {:refuse, "the daily cap of #{s.daily_cap} sends is spent; it resets at midnight UTC"}
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

  defp idle(s) do
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
