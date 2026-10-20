defmodule HiremeWeb.AcceptanceTest do
  @moduledoc """
  The cutover acceptance of docs/rebuild.md, items 3 and 4, against a
  running endpoint: HTTP for the sign-in ceremony, a real `/wire`
  WebSocket for everything after it.
  """

  use HiremeWeb.ConnCase, async: false

  import Hireme.WireCase, only: [op: 3, op: 4, tables: 1, ingest: 3]
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

  # A fresh account signs in by email link; the page it opens carries a wire
  # ticket, over which it enrols a passkey. Answers the browser's wire session.
  defp browser(conn, port) do
    {signed, _} = email_sign_in(conn, "acceptance@example.com")
    {ticket, _} = ticket(signed)
    {browser, welcome, _} = hello(port, :ticket, ticket, hd(HiremeWeb.Endpoint.origins()))
    assert welcome.kind == :WELCOME
    {:ok, options} = rpc(browser, "account.passkey.begin", %{"name" => "virtual"})
    attestation = attest(options, Application.get_env(:wax_, :origin))
    {:ok, %{"factor" => factor}} = rpc(browser, "account.passkey.finish", attestation)
    assert factor["kind"] == "webauthn"
    browser
  end

  defp mint(browser, name, preset) do
    {:ok, %{"secret" => secret}} =
      rpc(browser, "account.key.mint", %{"name" => name, "preset" => preset})

    secret
  end

  defp rpc(c, method, params),
    do: WireClient.rpc(c, System.unique_integer([:positive]), method, params)

  defp hello(port, cred, credential, origin \\ nil) do
    client = WireClient.connect(port, origin)
    WireClient.send_frame(client, Codec.encode_hello(cred, credential, "acceptance"))
    {welcome, []} = WireClient.await(client, :WELCOME)
    {boot, _} = WireClient.await(client, :BOOT)
    {client, welcome, boot}
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
    browser = browser(conn, port)

    {reader, _, _} = hello(port, :key, mint(browser, "reader", "read_only"))
    assert {:error, %{"code" => "scope"}} = rpc(reader, "lease.claim", %{})

    assert {:nack, :scope} =
             WireClient.put(reader, op(:put, :corporations, %{domain: "ro.example", name: "RO"}))

    {writer, _, boot} = hello(port, :key, mint(browser, "writer", "write_only"))

    assert Enum.all?(tables(boot.body), fn {name, rows} ->
             name in ~w(catalog clock) or rows == 0
           end)

    {:ok, _} = rpc(writer, "lease.claim", %{})

    assert {:ack, id} =
             WireClient.put(writer, op(:put, :corporations, %{domain: "wo.example", name: "WO"}))

    assert id > 0
  end

  test "4. an agent leases 16, moves one to draft_ready, adds a cited corporation and an office; the browser sees all three without reconnecting",
       %{conn: conn, port: port} do
    browser = browser(conn, port)

    {:ack, corp} =
      WireClient.put(browser, op(:put, :corporations, %{domain: "co.example", name: "Co"}))

    linked = %{corporation_id: corp, work_mode: :remote}

    for i <- 1..20 do
      {:ack, _} =
        WireClient.put(
          browser,
          op(:put, :applications, Map.merge(linked, %{company: "Company #{i}", role: "Engineer"}))
        )
    end

    rw = mint(browser, "agent", "read_write")
    WireClient.patches(browser, 100)

    {agent, _, _} = hello(port, :key, rw)
    {:ok, %{"ids" => ids}} = rpc(agent, "lease.claim", %{"count" => 16})
    assert length(ids) == 16
    app = hd(ids)

    {:ack, batch} = WireClient.put(agent, op(:put, :batches, %{code: "B-1", ordinal: 1}))
    {:ack, _} = WireClient.put(agent, op(:put, :applications, %{batch_id: batch}, target: app))
    {:ack, _} = WireClient.put(agent, op(:command, :stage, %{stage: :draft_ready}, target: app))

    acme = %{
      domain: "acme.example",
      name: "Acme",
      headcount: 120,
      as_of: ~D[2026-10-01],
      source: "https://acme.example/about"
    }

    {:ack, corp} = WireClient.put(agent, op(:put, :corporations, acme, keyed: true))
    place = op(:put, :places, %{kind: :country, iso2: "AC", name: "Acmeland"}, keyed: true)
    {:ack, place} = WireClient.put(agent, place)
    office = op(:put, :offices, %{corporation_id: corp, place_id: place, kind: :hq})
    {:ack, office} = WireClient.put(agent, office)

    # Every move arrives as rows of the replica; the browser reads them locally.
    model = Enum.reduce(WireClient.patches(browser, 600), %{}, &ingest(&2, :PATCH, &1.body))
    cell = fn table, id, col -> get_in(model, [table, id, Schema.column(table, col).id]) end
    assert cell.("applications", app, "stage") == Codec.enum_code("stage", :draft_ready)
    assert cell.("corporations", corp, "headcount") == 120
    assert cell.("corporations", corp, "headcount_on") == Date.to_gregorian_days(~D[2026-10-01])
    assert cell.("offices", office, "corporation_id") == corp

    [source] =
      for {_, row} <- model["citations"],
          row[Schema.column("citations", "table").id] == "corporations",
          row[Schema.column("citations", "row_id").id] == corp,
          row[Schema.column("citations", "column").id] == "headcount",
          do: row[Schema.column("citations", "source_id").id]

    assert cell.("sources", source, "host") == "acme.example"
  end
end
