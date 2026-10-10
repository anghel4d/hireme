defmodule Hireme.Mailer do
  @moduledoc """
  The desk's outbound mail: a sign-in link, and the notices an account
  gets through this second channel when something is bound to it or
  removed from it (NIST SP 800-63B-4 Sec. 4.1.2; ASVS 6.3.7). Plain
  text only: nothing to render, nothing to click but the link. The
  adapter is `config :hireme, Hireme.Mailer`; the sender is
  `config :hireme, :mail_from`.
  """

  use Swoosh.Mailer, otp_app: :hireme
  import Swoosh.Email
  require Logger
  alias Hireme.Security

  @spec sign_in_link(String.t(), String.t()) :: :ok | {:error, term()}
  def sign_in_link(to, url) do
    minutes = div(Security.magic_link_ttl(), 60)

    post(to, "Your Hireme sign-in link", """
    Open this link to sign in. It works once, for #{minutes} minutes, and only in the browser that opens it:

    #{url}

    If you did not ask for it, ignore this mail; the link is useless to anyone who did not receive it.
    """)
  end

  @spec notice(String.t(), atom(), map()) :: :ok | {:error, term()}
  def notice(to, kind, meta \\ %{}) do
    post(to, "Hireme: #{line(kind, meta)}", """
    #{line(kind, meta)}

    If this was you, there is nothing to do. If it was not, sign in, end your other sessions, and revoke your keys from the Account page.
    """)
  end

  defp line(:api_key_created, m), do: ~s(an API key named "#{m[:name]}" was created)
  defp line(:api_key_revoked, m), do: ~s(the API key named "#{m[:name]}" was revoked)
  defp line(:authenticator_added, m), do: "a second factor (#{m[:kind]}) was added"
  defp line(:authenticator_removed, m), do: "a second factor (#{m[:kind]}) was removed"
  defp line(:authenticator_disabled, m), do: "a second factor (#{m[:kind]}) was disabled"
  defp line(:recovery_code_used, m), do: "a recovery code was used; #{m[:left]} left"
  defp line(:identity_linked, m), do: "#{m[:provider]} sign-in #{m[:display]} was linked"
  defp line(:identity_unlinked, m), do: "#{m[:provider]} sign-in #{m[:display]} was unlinked"
  defp line(kind, _), do: kind |> Atom.to_string() |> String.replace("_", " ")

  defp post(to, subject, body) do
    {name, address} = Application.get_env(:hireme, :mail_from, {"Hireme", "hireme@localhost"})

    email =
      new()
      |> to(to)
      |> from({name, address})
      |> subject(header_safe(subject))
      |> text_body(body)

    case deliver(email) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("outbound mail failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # One subject header. Control characters would fold in a second header;
  # anything outside ASCII is an encoded-word so the bytes stay one field.
  defp header_safe(text) do
    text = text |> to_string() |> String.replace(~r/[\r\n\t]/, " ")
    if String.match?(text, ~r/[^\x20-\x7e]/), do: encoded_words(text), else: text
  end

  defp encoded_words(text) do
    text
    |> utf8_chunks(45)
    |> Enum.map_join(" ", &"=?utf-8?B?#{Base.encode64(&1)}?=")
  end

  defp utf8_chunks(text, max) do
    {chunks, last} =
      text
      |> String.graphemes()
      |> Enum.reduce({[], <<>>}, fn grapheme, {chunks, buf} ->
        if buf != "" and byte_size(buf <> grapheme) > max do
          {[buf | chunks], grapheme}
        else
          {chunks, buf <> grapheme}
        end
      end)

    Enum.reverse(if last == "", do: chunks, else: [last | chunks])
  end
end

defmodule Hireme.Mailer.Outbox do
  @moduledoc """
  Security notices outside the request that caused them: durable queued
  intent with bounded retries, not guaranteed delivery.

  `enqueue/4` is one insert in the caller's process and a wakeup that does
  not wait. The worker sends due notices one at a time, waits longer after
  each failure, and gives a notice up after the last delay with its error
  kept. Notices still pending at a restart are sent after it. A notice
  whose change committed but whose insert failed is logged and lost; the
  change it reports stands.
  """

  use GenServer
  require Logger
  import Ecto.Query
  alias Hireme.Mailer
  alias Hireme.Mailer.Notice
  alias Hireme.Repo
  alias Hireme.Store

  # Seconds to wait after each failure; after the last one the notice is given up.
  @backoff [30, 120, 480, 1_800, 7_200, 21_600, 43_200, 86_400]
  @tick :timer.seconds(60)
  @batch 50

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Queue one notice per address for `account_id` and wake the worker."
  @spec enqueue(pos_integer(), [String.t()], atom(), map()) :: :ok | {:error, :not_queued}
  def enqueue(_account_id, [], _kind, _meta), do: :ok

  def enqueue(account_id, addresses, kind, meta) when is_atom(kind) and is_map(meta) do
    now = now()

    rows =
      for address <- addresses,
          do: %{
            account_id: account_id,
            address: address,
            kind: Atom.to_string(kind),
            meta: meta,
            next_at: now,
            inserted_at: now
          }

    try do
      Notice |> Store.write(&Repo.insert_all(&1, rows))
      if pid = GenServer.whereis(__MODULE__), do: send(pid, :drain)
      :ok
    rescue
      e ->
        Logger.error(
          "security notice #{kind} for account #{account_id} was not queued: #{error(e)}"
        )

        {:error, :not_queued}
    end
  end

  @doc "Send every notice due at `now`, in the calling process. Returns how many were sent."
  @spec drain(DateTime.t()) :: non_neg_integer()
  def drain(now \\ now()) do
    # Each notice's kind and fields are atoms of Hireme.Mailer's texts. In a
    # release modules load on first use, so load it before matching rows.
    Code.ensure_loaded(Mailer)

    due =
      Repo.all(
        from(n in Notice,
          where: is_nil(n.sent_at) and n.next_at <= ^now and n.attempts < ^length(@backoff),
          order_by: n.id,
          limit: @batch
        ),
        skip_account: true
      )

    sent = Enum.count(due, &(deliver(&1) == :sent))
    if length(due) == @batch, do: sent + drain(now), else: sent
  end

  @impl true
  def init(:ok) do
    send(self(), :drain)
    {:ok, nil}
  end

  @impl true
  def handle_info(:drain, timer) do
    flush()

    # A drain that fails tries again at the next tick; it must not restart
    # this process often enough to take the application down with it.
    try do
      drain()
    rescue
      e -> Logger.error("mail outbox drain failed: #{error(e)}")
    end

    if timer, do: Process.cancel_timer(timer)
    {:noreply, Process.send_after(self(), :drain, @tick)}
  end

  @impl true
  def handle_call(:ping, _from, timer), do: {:reply, :pong, timer}

  defp flush do
    receive do
      :drain -> flush()
    after
      0 -> :ok
    end
  end

  defp deliver(%Notice{} = notice) do
    result =
      try do
        Mailer.notice(notice.address, String.to_existing_atom(notice.kind), fields(notice.meta))
      rescue
        e -> {:error, e}
      end

    changes =
      case result do
        :ok ->
          [sent_at: now()]

        {:error, reason} ->
          [
            next_at: DateTime.add(now(), Enum.at(@backoff, notice.attempts), :second),
            last_error: error(reason)
          ]
      end

    notice
    |> Ecto.Changeset.change([{:attempts, notice.attempts + 1} | changes])
    |> Store.write(&Repo.update!/1)

    if result == :ok, do: :sent, else: :failed
  end

  # JSON gave the keys back as strings. A key no notice text reads may not
  # exist as an atom; it is dropped, never created.
  defp fields(meta) do
    Enum.reduce(meta, %{}, fn {key, value}, fields ->
      case existing_atom(key) do
        nil -> fields
        atom -> Map.put(fields, atom, value)
      end
    end)
  end

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp error(%{__exception__: true} = e), do: clip(Exception.message(e))
  defp error(reason), do: clip(inspect(reason))

  defp clip(text), do: text |> String.replace(~r/[^\x20-\x7e]/, "?") |> String.slice(0, 200)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
