defmodule HiremeWeb.MailInbound do
  @moduledoc """
  The domain pipe's way in: `POST /mail/inbound/<pipe id>`, one raw RFC
  822 message from the anghel4d.com Email Worker (`workers/mail`), which
  also forwards it to Gmail. The Gmail link sees the same mail; both
  copies go to `Hireme.Gmail.ingest/3`, which keeps one by its Message-ID.

  A pipe belongs to one account: the operator enables it in the account
  lens, the node mints its secret, keeps it sealed on the mailbox row and
  shows it once for the Worker. The Worker signs each body:
  `X-Hireme-Timestamp` (unix seconds) and `X-Hireme-Signature: v1=<hex
  HMAC-SHA256(secret, "<timestamp>.<hex SHA-256 of the body>")>`.

  Refused, each with a JSON body saying why: an unknown or disabled pipe
  (404), a body over 25 MiB (413, read under that bound before anything
  else), another Content-Type than message/rfc822 (415), a missing or
  wrong signature or one more than 300 s from the node's clock (401), past
  the pipe's `mail_inbound` limit (429), ingestion not ready or the
  account unavailable for now (503, so the Worker retries) or refusing the message (422). There is no nonce store: a replay
  inside the window carries a Message-ID the node already holds, and is a
  duplicate. Nobody is struck or banned: every request comes from
  Cloudflare's Worker egress. The envelope headers are believed only once
  the signature holds, since they are signed with the body's request.
  """

  import Plug.Conn
  require Logger

  @max_body 25 * 1024 * 1024
  @window_s 300

  @doc "Answers one request to `/mail/inbound/<pipe id>`."
  def call(%{method: "POST", path_info: ["mail", "inbound", pipe_id]} = conn) do
    with {:ok, account_id, secret} <- pipe(pipe_id),
         :ok <- limited(pipe_id),
         {:ok, body, conn} <- body(conn),
         :ok <- rfc822(conn),
         :ok <- signed(conn, body, secret) do
      ingest(conn, account_id, body)
    else
      {:refused, status, why} -> refuse(conn, status, why)
      {:refused, conn, status, why} -> refuse(conn, status, why)
    end
  end

  def call(%{method: "POST"} = conn),
    do: refuse(conn, 404, "a pipe's URL is /mail/inbound/<pipe id>")

  def call(conn),
    do: conn |> put_resp_header("allow", "POST") |> refuse(405, "only POST is answered here")

  @doc "The signature the Worker sends for `body` at unix second `ts`."
  def signature(secret, ts, body) do
    digest = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
    mac = :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{digest}")
    "v1=" <> Base.encode16(mac, case: :lower)
  end

  defp conf(key, default),
    do: Keyword.get(Application.get_env(:hireme, __MODULE__, []), key, default)

  # The pipe's account and unsealed secret, from the mailbox row that holds it.
  defp pipe(pipe_id) do
    {mod, fun} = conf(:pipe, {Hireme.Gmail, :pipe})

    # Until the connector has the lookup (`Hireme.Gmail.pipe/1`), every pipe is unknown.
    found? = Code.ensure_loaded?(mod) and function_exported?(mod, fun, 1)

    case found? and pipe_id =~ ~r/^[0-9A-Za-z]{12}$/ and apply(mod, fun, [pipe_id]) do
      {:ok, account_id, secret} when is_binary(secret) -> {:ok, account_id, secret}
      _ -> {:refused, 404, "no enabled pipe has this id"}
    end
  end

  defp limited(pipe_id) do
    case Hireme.Security.limit(:mail_inbound, pipe_id) do
      :ok -> :ok
      {:error, :rate_limited} -> {:refused, 429, "this pipe is past 600 messages in 10 minutes"}
    end
  end

  defp body(conn) do
    case read_body(conn, length: @max_body, read_length: 1_048_576) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _, conn} -> {:refused, conn, 413, "a message is at most 25 MiB"}
      {:error, _} -> {:refused, 400, "the body could not be read"}
    end
  end

  defp rfc822(conn) do
    case get_req_header(conn, "content-type") do
      ["message/rfc822" <> _ | _] -> :ok
      _ -> {:refused, conn, 415, "the body is one raw message, Content-Type message/rfc822"}
    end
  end

  defp signed(conn, body, secret) do
    with [ts] <- get_req_header(conn, "x-hireme-timestamp"),
         {ts, ""} <- Integer.parse(ts),
         true <- abs(System.os_time(:second) - ts) <= @window_s,
         [given] <- get_req_header(conn, "x-hireme-signature"),
         true <- Plug.Crypto.secure_compare(given, signature(secret, ts, body)) do
      :ok
    else
      _ -> {:refused, conn, 401, "the signature or its timestamp does not verify"}
    end
  end

  defp ingest(conn, account_id, body) do
    {mod, fun} = conf(:ingest, {Hireme.Gmail, :ingest})

    case apply(mod, fun, [account_id, body, :domain]) do
      {:ok, outcome} ->
        reply(conn, 200, %{ok: true, outcome: outcome})

      # Transient: ingestion not ready yet, or the account's sequencer busy or restarting.
      {:error, why} when why in [:not_ready, :unavailable] ->
        refuse(
          conn,
          503,
          "the node cannot take mail right now; the Gmail link's copy still arrives"
        )

      {:error, reason} ->
        Logger.warning("mail inbound: ingest refused: #{inspect(reason)}")
        refuse(conn, 422, "the message was not taken: #{inspect(reason)}")
    end
  end

  defp refuse(conn, status, why), do: reply(conn, status, %{ok: false, error: why})

  defp reply(conn, status, map) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode_to_iodata!(map))
  end
end
