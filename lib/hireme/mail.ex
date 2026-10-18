defmodule Hireme.Mail do
  @moduledoc """
  The node's outbound mail: the sign-in link, and the notices an account
  gets on this second channel when something is bound to it or removed
  from it (NIST SP 800-63B-4 Sec. 4.1.2; ASVS 6.3.7). Plain text only:
  nothing to render, nothing to click but the link, no tracking pixels.

  The adapter is `config :hireme, Hireme.Mail` (`Hireme.Mail.Cloudflare`
  in production); the sender is `config :hireme, :mail_from`.

  Two paths, on purpose. A sign-in link is sent from a supervised task
  with two retries and is never written down, so a secret never sits in
  a table. A notice is queued in `outbox` by the request that caused it
  (`enqueue/4`) and sent by `Hireme.Mail.Outbox` with bounded retries:
  durable intent, not guaranteed delivery.

  This module is also the supervisor of both: the task supervisor and,
  unless `config :hireme, :mail_outbox, false` (tests drain it
  themselves), the outbox worker.
  """

  use Swoosh.Mailer, otp_app: :hireme
  use Supervisor
  import Swoosh.Email
  require Logger
  alias Hireme.Security

  # A sign-in link's send: the wait before each retry.
  @link_backoff [2_000, 8_000]

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    outbox =
      if Application.get_env(:hireme, :mail_outbox, true), do: [__MODULE__.Outbox], else: []

    Supervisor.init([{Task.Supervisor, name: __MODULE__.Tasks} | outbox], strategy: :one_for_one)
  end

  @doc "Send a sign-in link from a supervised task; the caller does not wait on the provider."
  @spec sign_in_link(String.t(), String.t()) :: :ok
  def sign_in_link(to, url) do
    {:ok, _} =
      Task.Supervisor.start_child(__MODULE__.Tasks, fn -> send_link(to, url, @link_backoff) end)

    :ok
  end

  defp send_link(to, url, backoff) do
    case {post(to, "Your Hireme sign-in link", link_body(url)), backoff} do
      {{:ok, _}, _} ->
        :ok

      {{:error, _}, [wait | rest]} ->
        Process.sleep(wait)
        send_link(to, url, rest)

      {{:error, _}, []} ->
        :error
    end
  end

  defp link_body(url) do
    """
    Open this link to sign in. It works once, for #{div(Security.magic_link_ttl(), 60)} minutes:

    #{url}

    If you did not ask for it, ignore this mail; nobody can use the link without it.
    """
  end

  @doc "Send one notice now; the outbox worker is the caller."
  @spec notice(String.t(), atom(), map()) :: {:ok, term()} | {:error, term()}
  def notice(to, kind, meta \\ %{}) do
    post(to, "Hireme: #{line(kind, meta)}", """
    #{line(kind, meta)}

    If this was you, there is nothing to do. If it was not, sign in, end your other sessions, and revoke your keys from the account lens.
    """)
  end

  @doc "The notice kinds and their one line each; the account lens shows the same words."
  @spec line(atom(), map()) :: String.t()
  def line(:api_key_created, m), do: ~s(an API key named "#{m[:name]}" was created)
  def line(:api_key_revoked, m), do: ~s(the API key named "#{m[:name]}" was revoked)
  def line(:api_key_widened, m), do: ~s(the API key named "#{m[:name]}" was given more access)
  def line(:authenticator_added, m), do: "a second factor (#{m[:kind]}) was added"
  def line(:authenticator_removed, m), do: "a second factor (#{m[:kind]}) was removed"
  def line(:authenticator_disabled, m), do: "a second factor (#{m[:kind]}) was disabled"
  def line(:recovery_code_used, m), do: "a recovery code was used; #{m[:left]} left"

  def line(:recovery_codes_issued, _),
    do: "new recovery codes were issued; the old ones no longer work"

  def line(:identity_linked, m), do: "#{m[:provider]} sign-in #{m[:display]} was linked"
  def line(:identity_unlinked, m), do: "#{m[:provider]} sign-in #{m[:display]} was unlinked"
  def line(kind, _), do: kind |> Atom.to_string() |> String.replace("_", " ")

  @doc """
  Queue one notice per address for `account_id` and wake the worker. One
  insert in the caller's process; a failed insert is logged and the
  change it reports stands.
  """
  @spec enqueue(pos_integer(), [String.t()], atom(), map()) :: :ok | {:error, :not_queued}
  def enqueue(_account_id, [], _kind, _meta), do: :ok

  def enqueue(account_id, addresses, kind, meta) when is_atom(kind) and is_map(meta) do
    now = Hireme.Store.now()

    rows =
      for address <- addresses,
          do: %{
            account_id: account_id,
            address: address,
            kind: Atom.to_string(kind),
            meta: meta,
            attempts: 0,
            next_at: now,
            rev: 1,
            inserted_at: now,
            updated_at: now
          }

    try do
      Hireme.Store.write(fn ->
        Hireme.Repo.insert_all(Hireme.Rows.Outbox, rows, skip_account: true)
      end)

      if pid = GenServer.whereis(__MODULE__.Outbox), do: send(pid, :drain)
      :ok
    rescue
      e ->
        Logger.error(
          "notice #{kind} for account #{account_id} was not queued: #{Security.clip(Exception.message(e))}"
        )

        {:error, :not_queued}
    end
  end

  defp post(to, subject, body) do
    {name, address} = Application.get_env(:hireme, :mail_from, {"Hireme", "hireme@localhost"})

    email =
      new() |> to(to) |> from({name, address}) |> subject(header_safe(subject)) |> text_body(body)

    case deliver(email) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = error ->
        Logger.error("outbound mail failed: #{Security.clip(inspect(reason))}")
        error
    end
  end

  # One subject header. Control characters would fold a second header in;
  # anything outside ASCII becomes encoded-words so the bytes stay one field.
  defp header_safe(text) do
    text = text |> to_string() |> String.replace(~r/[\r\n\t]/, " ")
    if String.match?(text, ~r/[^\x20-\x7e]/), do: encoded_words(text), else: text
  end

  defp encoded_words(text) do
    {chunks, last} =
      text
      |> String.graphemes()
      |> Enum.reduce({[], ""}, fn g, {chunks, buf} ->
        if buf != "" and byte_size(buf <> g) > 45,
          do: {[buf | chunks], g},
          else: {chunks, buf <> g}
      end)

    [last | chunks]
    |> Enum.reject(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.map_join(" ", &"=?utf-8?B?#{Base.encode64(&1)}?=")
  end
end

defmodule Hireme.Mail.Outbox do
  @moduledoc """
  Sends due notices one at a time, waits longer after each failure, and
  gives a notice up after the last delay with its error kept. Notices
  still pending at a restart are sent after it.
  """

  use GenServer
  require Logger
  import Ecto.Query
  alias Hireme.Repo
  alias Hireme.Rows.Outbox, as: Notice
  alias Hireme.Store

  # Seconds to wait after each failure; past the last, the notice is given up.
  @backoff [30, 120, 480, 1_800, 7_200, 21_600, 43_200, 86_400]
  @tick :timer.seconds(60)
  @batch 50

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Send every notice due at `now` in the calling process. Answers how many were sent."
  @spec drain(DateTime.t()) :: non_neg_integer()
  def drain(now \\ Store.now()) do
    # A notice's kind and fields are atoms of Hireme.Mail's lines; in a
    # release modules load on first use, so load it before matching rows.
    Code.ensure_loaded(Hireme.Mail)

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

    # A failed drain tries again at the next tick; it must not restart this
    # process often enough to take the node down with it.
    try do
      drain()
    rescue
      e -> Logger.error("outbox drain failed: #{Hireme.Security.clip(Exception.message(e))}")
    end

    if timer, do: Process.cancel_timer(timer)
    {:noreply, Process.send_after(self(), :drain, @tick)}
  end

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
        Hireme.Mail.notice(
          notice.address,
          String.to_existing_atom(notice.kind),
          fields(notice.meta || %{})
        )
      rescue
        e -> {:error, e}
      end

    changes =
      case result do
        {:ok, _} ->
          [sent_at: Store.now()]

        {:error, reason} ->
          [
            next_at: DateTime.add(Store.now(), Enum.at(@backoff, notice.attempts)),
            last_error: error(reason)
          ]
      end

    notice
    |> Ecto.Changeset.change([attempts: notice.attempts + 1, rev: notice.rev + 1] ++ changes)
    |> then(&Store.write(fn -> Repo.update!(&1, skip_account: true) end))

    if match?({:ok, _}, result), do: :sent, else: :failed
  end

  # JSON gave the keys back as strings. A key no line reads may not exist
  # as an atom; it is dropped, never created.
  defp fields(meta) do
    for {key, value} <- meta, atom = existing_atom(key), into: %{}, do: {atom, value}
  end

  defp existing_atom(key) when is_atom(key), do: key

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp error(%{__exception__: true} = e), do: Hireme.Security.clip(Exception.message(e))
  defp error(reason), do: Hireme.Security.clip(inspect(reason))
end

defmodule Hireme.Mail.Cloudflare do
  @moduledoc "Cloudflare Email Sending over HTTPS, for plain-text transactional mail."
  use Swoosh.Adapter, required_config: [:account_id, :api_token]

  @impl true
  def deliver(email, config) do
    {name, address} = email.from
    recipients = Enum.map(email.to, fn {_, address} -> address end)

    request =
      Req.new(
        url:
          "https://api.cloudflare.com/client/v4/accounts/#{config[:account_id]}/email/sending/send",
        auth: {:bearer, config[:api_token]},
        retry: false,
        receive_timeout: 15_000
      )
      |> Req.merge(Keyword.get(config, :request_options, []))

    payload = %{
      from: %{name: name, address: address},
      to: recipients,
      subject: email.subject,
      text: email.text_body
    }

    case Req.post(request, json: payload) do
      {:ok, %Req.Response{status: status, body: %{"success" => true, "result" => result}}}
      when status in 200..299 ->
        accepted(result, recipients)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:cloudflare_http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp accepted(%{"permanent_bounces" => [_ | _]}, _), do: {:error, :permanent_bounce}

  defp accepted(%{} = result, recipients) do
    taken = Map.get(result, "delivered", []) ++ Map.get(result, "queued", [])

    if Enum.all?(recipients, &(&1 in taken)),
      do: {:ok, Map.take(result, ["delivered", "queued"])},
      else: {:error, :recipients_not_accepted}
  end
end
