defmodule HiremeWeb.MailInboundTest do
  use HiremeWeb.ConnCase, async: false

  alias HiremeWeb.MailInbound

  @pipe "AbCdEfGh1234"
  @secret String.duplicate("ab", 32)
  @raw "Message-ID: <x1@example.com>\r\nFrom: a@example.com\r\nSubject: Hi\r\n\r\nHello\r\n"

  # The domain pipe's contract with the Worker: a signed raw message to an
  # enabled pipe is handed to ingestion as that account's :domain copy;
  # anything else is refused with a body saying why, and nothing is ingested.
  setup do
    Application.put_env(:hireme, MailInbound,
      pipe: {__MODULE__, :pipe},
      ingest: {__MODULE__, :ingest}
    )

    :persistent_term.put({__MODULE__, :test}, self())
    on_exit(fn -> Application.delete_env(:hireme, MailInbound) end)
  end

  def pipe(@pipe), do: {:ok, 7, @secret}
  def pipe(_), do: :error

  def ingest(_account, "not ready" <> _, :domain), do: {:error, :not_ready}
  def ingest(_account, "unavailable" <> _, :domain), do: {:error, :unavailable}

  def ingest(account, raw, source) do
    send(:persistent_term.get({__MODULE__, :test}), {:ingest, account, raw, source})
    {:ok, :stored}
  end

  defp deliver(body, headers, pipe \\ @pipe) do
    conn = Plug.Test.conn(:post, "https://www.example.com/mail/inbound/#{pipe}", body)

    headers
    |> Enum.reduce(conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    |> HiremeWeb.Endpoint.call([])
  end

  defp signed(body, ts \\ System.os_time(:second)),
    do: [
      {"content-type", "message/rfc822"},
      {"x-hireme-timestamp", "#{ts}"},
      {"x-hireme-signature", MailInbound.signature(@secret, ts, body)}
    ]

  defp refused?(conn, status) do
    assert conn.status == status
    assert %{"ok" => false, "error" => why} = JSON.decode!(conn.resp_body)
    assert why != ""
    refute_received {:ingest, _, _, _}
  end

  test "a signed message to an enabled pipe is handed to ingestion whole, as that account's domain copy" do
    conn = deliver(@raw, signed(@raw))
    assert conn.status == 200
    assert %{"ok" => true, "outcome" => "stored"} = JSON.decode!(conn.resp_body)
    assert_received {:ingest, 7, @raw, :domain}
  end

  test "an unsigned, wrongly signed, tampered or stale message is refused, and nothing is ingested" do
    stale = System.os_time(:second) - 301

    for headers <- [
          [{"content-type", "message/rfc822"}],
          signed("another body"),
          signed(@raw, stale),
          [
            {"content-type", "message/rfc822"},
            {"x-hireme-timestamp", "x"},
            {"x-hireme-signature", "v1=00"}
          ]
        ],
        do: refused?(deliver(@raw, headers), 401)
  end

  test "an unknown pipe, a malformed pipe id, another Content-Type and a body over 25 MiB are refused" do
    refused?(deliver(@raw, signed(@raw), "ZZZZZZZZZZZZ"), 404)
    refused?(deliver(@raw, signed(@raw), "../etc"), 404)
    refused?(deliver(@raw, [{"content-type", "text/plain"} | tl(signed(@raw))]), 415)
    big = :binary.copy("a", 25 * 1024 * 1024 + 1)
    refused?(deliver(big, signed(big)), 413)
  end

  test "while ingestion is not ready or the account is unavailable the node answers 503, which the Worker retries" do
    for raw <- ["not ready\r\n", "unavailable\r\n"], do: refused?(deliver(raw, signed(raw)), 503)
  end

  test "a GET is not answered" do
    conn =
      Plug.Test.conn(:get, "https://www.example.com/mail/inbound/#{@pipe}")
      |> HiremeWeb.Endpoint.call([])

    refused?(conn, 405)
  end

  # The same vector is asserted by the Worker's test (workers/mail/test/sign.test.ts).
  test "the signature is the Worker's: v1 HMAC-SHA256 over the timestamp and the body's SHA-256" do
    assert MailInbound.signature(String.duplicate("k", 32), 1_700_000_000, "hello") ==
             "v1=0eaff2c0f990eb6053aeb018a2e84e9c505be66b0344dd5ec1f8e7efe2ff9675"
  end
end
