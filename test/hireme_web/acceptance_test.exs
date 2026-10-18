defmodule HiremeWeb.AcceptanceTest do
  @moduledoc """
  The cutover acceptance of docs/rebuild.md, items 3 and 4, against a
  running endpoint: HTTP for the sign-in ceremony, a real `/wire`
  WebSocket for everything after it.
  """

  use HiremeWeb.ConnCase, async: false

  import Hireme.WireCase, only: [op: 3, op: 4, tables: 1]
  alias Hireme.{Schema, WireClient}
  alias HiremeWeb.Wire.Codec

  setup do
    {:ok, server} =
      Bandit.start_link(plug: HiremeWeb.Endpoint, ip: :loopback, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Hireme.Sequencer.Dynamic),
          do: DynamicSupervisor.terminate_child(Hireme.Sequencer.Dynamic, pid)
    end)

    {:ok, port: port}
  end

  # A fresh account signs in by email link; the page it opens carries a wire ticket.
  defp email_sign_in(conn) do
    page = get(conn, "/sign-in")
    csrf = csrf(page)

    conn =
      page
      |> recycle()
      |> post("/sign-in/email", %{"email" => "acceptance@example.com", "_csrf_token" => csrf})

    assert html_response(conn, 200) =~ "on its way"
    assert_receive {:email, mail}, 1_000
    [_, token] = Regex.run(~r/token=([A-Za-z0-9_%-]+)/, mail.text_body)
    token = URI.decode_www_form(token)

    shown =
      build_conn(:get, "https://www.example.com/") |> get("/sign-in/email", %{"token" => token})

    signed =
      shown
      |> recycle()
      |> post("/sign-in/email/confirm", %{"token" => token, "_csrf_token" => csrf(shown)})

    assert redirected_to(signed) == "/"
    html = signed |> recycle() |> get("/desk") |> html_response(200)
    [_, ticket] = Regex.run(~r/name="hireme-ticket" content="([^"]+)"/, html)
    ticket
  end

  defp csrf(conn) do
    [_, token] =
      Regex.run(
        ~r/name="_csrf_token" value="([^"]+)"|name="csrf-token" content="([^"]+)"/,
        html_response(conn, 200)
      )
      |> Enum.reject(&(&1 == ""))

    token
  end

  defp hello(port, cred, credential, origin \\ nil) do
    client = WireClient.connect(port, origin)
    WireClient.send_frame(client, Codec.encode_hello(cred, credential, "acceptance"))
    {welcome, []} = WireClient.await(client, :WELCOME)
    {boot, _} = WireClient.await(client, :BOOT)
    {client, welcome, boot}
  end

  defp ops_frame(ops) do
    Codec.frame(:OPS, 0, [<<length(ops)::little-32, 0::32>> | Enum.map(ops, & &1.raw)])
  end

  defp acks(%{body: <<n::little-32, 0::32, rest::binary>>}),
    do:
      for(
        <<op_id::little-64, rev::little-64, id::little-32,
          0::32 <- binary_part(rest, 0, n * 24)>>,
        do: %{op_id: op_id, rev: rev, id: id}
      )

  defp nack_refusals(%{body: <<_n::little-32, 0::32, rest::binary>>}), do: refusals(rest)
  defp refusals(<<>>), do: []

  defp refusals(<<_op::little-64, code::little-16, _::48, len::little-32, rest::binary>>) do
    skip = len + rem(8 - rem(4 + len, 8), 8)
    [Schema.refusal_name(code) | refusals(binary_part(rest, skip, byte_size(rest) - skip))]
  end

  # The one put and its verdict.
  defp write(client, op) do
    WireClient.send_frame(client, ops_frame([op]))

    receive do
      {:wire, ^client, %{kind: :ACK} = f} -> {:ack, hd(acks(f))}
      {:wire, ^client, %{kind: :NACK} = f} -> {:nack, hd(nack_refusals(f))}
    after
      3_000 -> flunk("no verdict")
    end
  end

  # A virtual authenticator: a P-256 key, attestation "none", user present and verified.
  defp attest(options, origin) do
    {<<4, x::binary-32, y::binary-32>>, _priv} = :crypto.generate_key(:ecdh, :prime256v1)
    cred_id = :crypto.strong_rand_bytes(16)
    bytes = &%CBOR.Tag{tag: :bytes, value: &1}
    cose = CBOR.encode(%{1 => 2, 3 => -7, -1 => 1, -2 => bytes.(x), -3 => bytes.(y)})
    rp_id = options["publicKey"]["rp"]["id"]

    auth_data =
      :crypto.hash(:sha256, rp_id) <>
        <<0x45, 0::32>> <> <<0::128>> <> <<16::16>> <> cred_id <> cose

    attestation =
      CBOR.encode(%{"fmt" => "none", "attStmt" => %{}, "authData" => bytes.(auth_data)})

    client_data =
      JSON.encode!(%{
        type: "webauthn.create",
        challenge: options["publicKey"]["challenge"],
        origin: origin
      })

    b64 = &Base.url_encode64(&1, padding: false)

    %{
      "attestationObject" => b64.(attestation),
      "clientDataJSON" => b64.(client_data),
      "name" => "virtual"
    }
  end

  test "3. sign in by email link, enroll a passkey, mint keys: read-only puts are scope, write-only BOOTs empty and ACKs",
       %{conn: conn, port: port} do
    ticket = email_sign_in(conn)
    origin = hd(HiremeWeb.Endpoint.origins())
    {browser, welcome, _boot} = hello(port, :ticket, ticket, origin)
    assert welcome.kind == :WELCOME

    {:ok, options} = WireClient.rpc(browser, 1, "account.passkey.begin", %{"name" => "virtual"})

    {:ok, %{"factor" => factor}} =
      WireClient.rpc(
        browser,
        2,
        "account.passkey.finish",
        attest(options, Application.get_env(:wax_, :origin))
      )

    assert factor["kind"] == "webauthn"

    {:ok, %{"secret" => ro}} =
      WireClient.rpc(browser, 3, "account.key.mint", %{
        "name" => "reader",
        "preset" => "read_only"
      })

    {:ok, %{"secret" => wo}} =
      WireClient.rpc(browser, 4, "account.key.mint", %{
        "name" => "writer",
        "preset" => "write_only"
      })

    {reader, _, _} = hello(port, :key, ro)
    assert {:error, %{"code" => "scope"}} = WireClient.rpc(reader, 1, "lease.claim", %{})

    assert {:nack, :scope} =
             write(reader, op(:put, :corporations, %{domain: "ro.example", name: "RO"}))

    {writer, _, boot} = hello(port, :key, wo)

    assert Enum.all?(tables(boot.body), fn {name, rows} ->
             name in ~w(catalog clock) or rows == 0
           end)

    {:ok, _} = WireClient.rpc(writer, 1, "lease.claim", %{})

    assert {:ack, %{id: id}} =
             write(writer, op(:put, :corporations, %{domain: "wo.example", name: "WO"}))

    assert id > 0
  end

  test "4. an agent leases 16, moves one to draft_ready, adds a cited corporation and an office; the browser sees all three without reconnecting",
       %{conn: conn, port: port} do
    ticket = email_sign_in(conn)
    origin = hd(HiremeWeb.Endpoint.origins())
    {browser, _, _} = hello(port, :ticket, ticket, origin)

    for i <- 1..20 do
      {:ack, _} =
        write(browser, op(:put, :applications, %{company: "Company #{i}", role: "Engineer"}))
    end

    {:ok, options} = WireClient.rpc(browser, 1, "account.passkey.begin", %{"name" => "virtual"})

    {:ok, _} =
      WireClient.rpc(
        browser,
        2,
        "account.passkey.finish",
        attest(options, Application.get_env(:wax_, :origin))
      )

    {:ok, %{"secret" => rw}} =
      WireClient.rpc(browser, 3, "account.key.mint", %{
        "name" => "agent",
        "preset" => "read_write"
      })

    flush(browser)

    {agent, _, _} = hello(port, :key, rw)
    {:ok, %{"ids" => ids}} = WireClient.rpc(agent, 1, "lease.claim", %{"count" => 16})
    assert length(ids) == 16
    app = hd(ids)

    {:ack, %{id: batch}} = write(agent, op(:put, :batches, %{code: "B-1", ordinal: 1}))
    {:ack, _} = write(agent, op(:put, :applications, %{batch_id: batch}, target: app))
    {:ack, _} = write(agent, op(:command, :stage, %{stage: :draft_ready}, target: app))

    {:ack, %{id: corp}} =
      write(
        agent,
        op(
          :put,
          :corporations,
          %{
            domain: "acme.example",
            name: "Acme",
            headcount: 120,
            as_of: ~D[2026-10-01],
            source: "https://acme.example/about"
          },
          keyed: true
        )
      )

    {:ack, %{id: place}} =
      write(
        agent,
        op(:put, :places, %{kind: :country, iso2: "AC", name: "Acmeland"}, keyed: true)
      )

    {:ack, %{id: office}} =
      write(agent, op(:put, :offices, %{corporation_id: corp, place_id: place, kind: :hq}))

    # The application's move arrives as a row; the server-side rows as a rev
    # that moved, which the world view answers with a find on the same session.
    stage = Codec.enum_code("stage", :draft_ready)
    stage_col = Schema.column(:applications, "stage").id
    patches = collect_patches(browser, 600)
    model = Enum.reduce(patches, %{}, &Hireme.WireCase.ingest(&2, :PATCH, &1.body))
    assert get_in(model, ["applications", app, stage_col]) == stage

    {:ok, %{"rows" => [found]}} =
      WireClient.rpc(browser, 9, "find", %{
        "table" => "corporations",
        "where" => %{"domain" => "acme.example"},
        "cols" => ["id", "headcount", "headcount_on"]
      })

    assert found["id"] == corp and found["headcount"] == 120 and
             found["headcount_on"] == "2026-10-01"

    {:ok, %{"rows" => offices}} =
      WireClient.rpc(browser, 10, "find", %{
        "table" => "offices",
        "where" => %{"corporation_id" => corp}
      })

    assert Enum.map(offices, & &1["id"]) == [office]

    {:ok, %{"citations" => [cite | _]}} =
      WireClient.rpc(browser, 11, "history", %{
        "table" => "corporations",
        "id" => corp,
        "column" => "headcount"
      })

    assert cite["source"]["host"] == "acme.example"
  end

  defp collect_patches(client, quiet_ms, acc \\ []) do
    receive do
      {:wire, ^client, %{kind: :PATCH} = f} -> collect_patches(client, quiet_ms, [f | acc])
      {:wire, ^client, _} -> collect_patches(client, quiet_ms, acc)
    after
      quiet_ms -> Enum.reverse(acc)
    end
  end

  defp flush(client) do
    receive do
      {:wire, ^client, _} -> flush(client)
    after
      100 -> :ok
    end
  end
end
