defmodule HiremeWeb.SessionTest do
  @moduledoc """
  The session hosted in the test process, as a carrier hosts it: frames
  in through `event/2`, the account's deltas through `info/2`, and every
  frame it writes caught by a carrier that mails them back here.
  """

  use Hireme.DataCase, async: false

  import Hireme.Fixtures
  alias HiremeWeb.Packet
  alias HiremeWeb.Session

  defmodule Carrier do
    @moduledoc false
    def send({__MODULE__, pid}, id, io), do: Kernel.send(pid, {:out, id, IO.iodata_to_binary(io)})
    def fin(_c, _id), do: :ok
    def open_uni({__MODULE__, pid}, id), do: Kernel.send(pid, {:uni, id})
    def reset({__MODULE__, pid}, id, code), do: Kernel.send(pid, {:reset, id, code})
    def ready({__MODULE__, pid}), do: Kernel.send(pid, :ready)
    def close({__MODULE__, pid}, code, reason), do: Kernel.send(pid, {:close, code, reason})
  end

  defp hello(snapshot \\ 0) do
    IO.iodata_to_binary(
      Packet.frame(
        :hello,
        0,
        <<0::little-16, 0::48, snapshot::little-64, 7::little-32, 1::little-32>>
      )
    )
  end

  defp op(op_id, kind, target, fields) do
    body = for f <- fields, into: <<>>, do: <<byte_size(f)::little-16, f::binary>>

    IO.iodata_to_binary(
      Packet.frame(
        :op,
        0,
        <<op_id::little-64, kind::8, length(fields)::8, 0::16, target::little-32, body::binary>>
      )
    )
  end

  # Every frame written to stream `id` so far, in order.
  defp all_out(id \\ 0) do
    receive do
      {:out, ^id, bin} ->
        {:ok, frames, ""} = Packet.split(bin)
        frames ++ all_out(id)
    after
      50 -> []
    end
  end

  # Feed every delta, and every message the session sent itself, waiting
  # in this process's mailbox to the session.
  defp drain(s) do
    receive do
      message when elem(message, 0) in [:ops_delta, :ops_reply, Session] ->
        {:ok, s} = Session.info(message, s)
        drain(s)
    after
      50 -> s
    end
  end

  # The sequencer's answer to the one op in flight, and nothing else.
  defp answered(s) do
    assert_receive {:ops_reply, _, _} = reply
    {:ok, s} = Session.info(reply, s)
    s
  end

  defp open(account) do
    {_token, session} = Hireme.Accounts.start_session(account)
    {:ok, s} = Session.init({Carrier, self()}, %{account_id: account.id, session_id: session.id})
    s
  end

  test "a refused op answers NACK with its code and keeps nothing", %{account: account} do
    p = profile()
    job = job(p)
    s = open(account)
    {:ok, s} = Session.event({:data, 0, hello()}, s)
    s = drain(s)
    _ = all_out()

    {:ok, s} = Session.event({:data, 0, op(42, 1, job.id, ["no_such_stage"])}, s)
    answered(s)

    assert [{:nack, 0, _, <<42::little-64, code::8, _::binary>>}] = all_out()
    assert code == Packet.refusal_code(:argument)
  end

  test "a replayed op id is answered from the ledger, once", %{account: account} do
    p = profile()
    job = job(p)
    s = open(account)
    {:ok, s} = Session.event({:data, 0, hello()}, s)
    s = drain(s)
    _ = all_out()

    {:ok, s} = Session.event({:data, 0, op(43, 2, job.id, ["Call", ""])}, s)
    s = drain(s)
    assert Enum.any?(all_out(), &match?({:ack, _, _, <<43::little-64>>}, &1))

    {:ok, s} = Session.event({:data, 0, op(43, 2, job.id, ["Call", ""])}, s)
    answered(s)
    assert [{:ack, 0, _, <<43::little-64>>}] = all_out()
    refute_receive {:ops_delta, _, _}, 100
  end

  test "tickets are single use and name a live session", %{account: account} do
    {_token, session} = Hireme.Accounts.start_session(account)
    t = Session.ticket(account.id, session.id)
    assert {:ok, account_id, session_id} = Session.redeem(t)
    assert {account_id, session_id} == {account.id, session.id}
    assert :error = Session.redeem(t)
    assert :error = Session.redeem("garbage")
  end

  test "the websocket carrier admits a live cookie session, and an agent only as far as HELLO",
       %{account: account} do
    {token, session} = Hireme.Accounts.start_session(account)
    Hireme.Repo.put_account(nil)
    info = %{connect_info: %{session: %{HiremeWeb.Auth.session_key() => token}}}
    assert {:ok, %{account_id: id, session_id: sid}} = HiremeWeb.WireSocket.connect(info)
    assert {id, sid} == {account.id, session.id}

    assert {:ok, %{origin: "", path: "/wt"}} =
             HiremeWeb.WireSocket.connect(%{connect_info: %{session: %{}}})
  end

  test "an op on a line or job that is not there is refused, and the next op still answers",
       %{account: account} do
    job = job(profile())
    s = open(account)
    {:ok, s} = Session.event({:data, 0, hello()}, s)
    s = drain(s)
    _ = all_out()

    {:ok, s} = Session.event({:data, 0, op(51, 5, job.id, ["99999999", "hidden", "", ""])}, s)
    {:ok, s} = Session.event({:data, 0, op(52, 2, 99_999_999, ["x", ""])}, s)
    {:ok, s} = Session.event({:data, 0, op(53, 4, job.id, ["70"])}, s)
    _s = drain(s)

    out = all_out()
    nack = Packet.refusal_code(:not_found)
    assert Enum.any?(out, &match?({:nack, _, _, <<51::little-64, ^nack::8, _::binary>>}, &1))
    assert Enum.any?(out, &match?({:nack, _, _, <<52::little-64, ^nack::8, _::binary>>}, &1))
    assert Enum.any?(out, &match?({:ack, _, _, <<53::little-64>>}, &1))
  end

  test "a raw hello boots raw tables, account tables and the clock",
       %{account: account} do
    # A batch written before the sequencer starts is in its first read.
    Hireme.Repo.insert!(%Hireme.Desk.Batch{
      code: "B-raw",
      ordinal: 1,
      fire: :hold,
      account_id: account.id
    })

    job = job(profile(), %{listing: "Elixir, Rust and WebAssembly."})

    s = open(account)
    {:ok, s} = Session.event({:data, 0, hello()}, s)
    s = drain(s)
    [{:boot, 0x02, rev, body}, {:patch, 0, rev2, listings} | _] = Enum.map(all_out(), &plain/1)
    # The listings follow the board in their own frame, at the same rev.
    assert rev2 == rev
    refute body =~ "Elixir, Rust and WebAssembly."
    assert listings =~ "Elixir, Rust and WebAssembly."
    ids = Map.keys(tables(body))
    for t <- [:job_apps, :profiles, :clock, :acct, :stages], do: assert(Packet.table_id(t) in ids)
    refute Packet.table_id(:cards) in ids

    {:ok, s} = Session.event({:data, 0, op(61, 2, job.id, ["Call", ""])}, s)
    _s = drain(s)
    out = all_out()
    [{:patch, 0, prev, pbody} | _] = Enum.filter(out, &match?({:patch, _, _, _}, &1))
    assert prev > rev
    # Only the columns the write changed travel, never the listing.
    assert [%{next_action: "Call", listing: nil}] = named(tables(pbody), :job_apps)

    assert Enum.find_index(out, &match?({:patch, _, _, _}, &1)) <
             Enum.find_index(out, &match?({:ack, _, _, <<61::little-64>>}, &1))
  end

  test "a resume replays only the revisions since the snapshot; garbage says bye",
       %{account: account} do
    job = job(profile())
    s = open(account)
    {:ok, s} = Session.event({:data, 0, hello()}, s)
    s = drain(s)
    [{:boot, _, rev0, _} | _] = all_out()
    {:ok, s} = Session.event({:data, 0, op(62, 2, job.id, ["One", ""])}, s)
    {:ok, s} = Session.event({:data, 0, op(63, 2, job.id, ["Two", ""])}, s)
    s = drain(s)
    rev = all_out() |> Enum.filter(&match?({:patch, _, _, _}, &1)) |> List.last() |> elem(2)

    {:ok, _} = Session.event({:data, 0, hello(rev0)}, open(account))
    out = all_out()
    patches = for {:patch, _, r, _} <- out, do: r
    assert List.last(patches) == rev
    assert length(patches) == 3

    assert [{:patch, 0x02, _, _} | _] =
             Enum.reverse(Enum.filter(out, &match?({:patch, _, _, _}, &1)))

    refute Enum.any?(out, &match?({:boot, _, _, _}, &1))

    # At the current rev there is nothing to replay: one PATCH, then the ticket.
    {:ok, _} = Session.event({:data, 0, hello(rev)}, open(account))
    assert [{:patch, 0x02, ^rev, _}, {:ticket, 0, ^rev, _}] = all_out()

    # A frame of no schema ends the session with BYE.
    assert {:stop, :normal, _} = Session.event({:data, 0, <<12::little-32, 0::96>>}, s)
    assert [{:bye, 0, _, _}] = all_out()
  end

  test "account commands ride the session as RPC, tables before the reply", %{account: account} do
    {:ok, %{key: key}} = Hireme.ApiKeys.create("bench")
    s = open(account)
    {:ok, s} = Session.event({:data, 0, hello()}, s)
    s = drain(s)
    _ = all_out()

    req =
      Jason.encode!(%{
        id: 9,
        method: "account/rename_key",
        params: %{id: key.id, name: "renamed"}
      })

    {:ok, _s} =
      Session.event({:data, 0, IO.iodata_to_binary(HiremeWeb.Account.rpc_frame(req))}, s)

    out = all_out()
    pi = Enum.find_index(out, &match?({:patch, _, _, _}, &1))
    ri = Enum.find_index(out, &match?({:rpc, _, _, _}, &1))
    assert pi < ri
    {:rpc, _, _, <<len::little-32, _::32, json::binary-size(len), _::binary>>} = Enum.at(out, ri)
    assert %{"id" => 9, "result" => _} = Jason.decode!(json)
  end

  test "an agent hello boots raw tables like a browser, hears raw rows and sends ops", %{
    account: account
  } do
    Hireme.Repo.insert!(%Hireme.Desk.Batch{code: "B-agent", ordinal: 1, account_id: account.id})
    job = job(profile())
    {:ok, %{secret: secret}} = Hireme.ApiKeys.create("session")

    {a, [{:boot, 0x03, _, _} = boot | _]} = agent(secret, "198.51.100.9")
    # An agent gets the browser's raw BOOT and derives its own views.
    {:boot, 0x02, _, body} = plain(boot)
    booted = tables(body)
    assert [%{code: "B-agent"}] = named(booted, :batches)
    assert Enum.map(named(booted, :job_apps), & &1.id) == [job.id]

    op = %{op_id: 70, kind: :next, target: job.id, fields: ["Agent sees", ""]}
    assert {:ok, _} = Hireme.Ops.run(account.id, op)
    a = drain(a)
    assert [{:patch, 0, _, pbody}] = all_out()
    assert [%{next_action: "Agent sees"}] = named(tables(pbody), :job_apps)

    # Its writes go up as OPs on control; one outside a block is refused.
    {:ok, a} = Session.event({:data, 0, op(71, 2, job.id, ["Agent writes", ""])}, a)
    _a = drain(a)
    assert Enum.any?(all_out(), &match?({:nack, _, _, <<71::little-64, _::binary>>}, &1))
  end

  test "a browser that does not ask for raw tables is told its bundle is stale",
       %{account: account} do
    s = open(account)

    old =
      IO.iodata_to_binary(
        Packet.frame(:hello, 0, <<0::little-16, 0::48, 0::64, 7::little-32, 0::32>>)
      )

    assert {:stop, :normal, _} = Session.event({:data, 0, old}, s)
    assert [{:bye, 0, _, <<6::little-16, "schema">>}] = all_out()
  end

  # An agent's session through its API-key HELLO, with every frame its BOOT wrote.
  defp agent(secret, ip) do
    {:ok, a} = Session.init({Carrier, self()}, %{ip: ip, origin: "", path: "/wt"})
    pad = :binary.copy(<<0>>, rem(8 - rem(2 + byte_size(secret), 8), 8))

    body = [
      <<byte_size(secret)::little-16, secret::binary>>,
      pad,
      <<0::little-64, 3::little-32, 0::little-32>>
    ]

    a = send_in(a, Packet.frame(:hello, 0, body, flags: 0x80))
    {a, all_out()}
  end

  defp send_in(a, frame) do
    {:ok, a} = Session.event({:data, 0, IO.iodata_to_binary(frame)}, a)
    drain(a)
  end

  # One lease RPC, and its decoded reply.
  defp call(a, id, method, params) do
    a =
      send_in(
        a,
        HiremeWeb.Account.rpc_frame(Jason.encode!(%{id: id, method: method, params: params}))
      )

    [reply] =
      for {:rpc, _, _, <<len::little-32, _::32, json::binary-size(len), _::binary>>} <- all_out(),
          do: Jason.decode!(json)

    {a, reply}
  end

  defp leased?(job_id), do: MapSet.member?(Hireme.Letterbox.leased_jobs(), job_id)
  defp answers, do: Enum.filter(all_out(), &(elem(&1, 0) in [:ack, :nack]))

  test "an agent leases a block by RPC and writes only what it holds", %{account: _account} do
    {:ok, %{secret: secret}} = Hireme.ApiKeys.create("blocks")
    jobs = for i <- 1..6, do: job(profile(), %{company: "Co #{i}"})
    [j1, _j2, j3, j4 | _] = jobs
    {{:ok, _, _}, other} = hold_lease(j3.id)
    {s, _} = agent(secret, "198.51.100.10")

    # A block over another agent's entry is refused whole, and says where to go.
    {s, %{"error" => %{"data" => %{"code" => "busy", "held" => [3], "free" => [5, 6]}}}} =
      call(s, 1, "lease/acquire", %{"from" => 2, "to" => 4})

    {s, %{"result" => %{"from" => 1, "to" => 2, "lane" => 1, "jobs" => held, "warnings" => []}}} =
      call(s, 2, "lease/acquire", %{"count" => 2})

    assert held == [[1, j1.id], [2, Enum.at(jobs, 1).id]]

    # A write in the block lands, after its delta; one outside is refused `leased`.
    s = send_in(s, op(81, 2, j1.id, ["From the block", ""]))
    s = send_in(s, op(82, 4, j4.id, ["1"]))

    assert [{:ack, 0, _, <<81::little-64>>}, {:nack, 0, _, <<82::little-64, 3, _::binary>>}] =
             answers()

    assert Repo.get!(Hireme.Desk.Job, j1.id).next_action == "From the block"

    # One block per agent: release it first.
    {s, %{"error" => %{"data" => %{"code" => "held", "from" => 1, "to" => 2}}}} =
      call(s, 3, "lease/acquire", %{"count" => 1})

    {s, %{"result" => %{"released" => true}}} = call(s, 4, "lease/release", %{})
    refute leased?(j1.id)

    # A range past the desk is clamped, with a warning.
    {s, %{"result" => %{"from" => 4, "to" => 6, "warnings" => [%{"code" => "truncated"}]}}} =
      call(s, 5, "lease/acquire", %{"from" => 4, "to" => 60})

    Session.terminate(:normal, s)
    refute leased?(j4.id)
    let_go(other)
  end

  test "a revoked key, or the session ending, gives the block back", %{account: _account} do
    {:ok, %{key: key, secret: secret}} = Hireme.ApiKeys.create("revoked")
    job = job(profile(), %{company: "Revoked"})
    {a, _} = agent(secret, "198.51.100.13")
    {s, _} = call(a, 1, "lease/acquire", %{"count" => 1})
    assert leased?(job.id)

    Hireme.ApiKeys.revoke(key)
    assert_receive :api_key_dead
    assert {:stop, :normal, s} = Session.info(:api_key_dead, s)
    Session.terminate(:normal, s)
    refute leased?(job.id)
  end

  test "a page carries the board, and its connection then gets only the rest",
       %{account: account} do
    job(profile(), %{listing: "Rust and Elixir."})
    {token, session} = Hireme.Accounts.start_session(account)
    {rev, board} = Session.board(account.id, session.id)
    assert {:ok, [{:boot, 0x03, ^rev, _}], ""} = Packet.split(board)

    info = %{connect_info: %{session: %{HiremeWeb.Auth.session_key() => token}}}
    params = %{"raw" => "1", "rev" => "0", "cid" => "5", "board" => "#{rev}"}
    {:ok, meta} = HiremeWeb.WireSocket.connect(Map.put(info, :params, params))
    {:ok, s} = Session.init({Carrier, self()}, meta)
    _ = drain(s)
    # The early BOOT stream (3) holds no BOOT, only the rest and the ticket.
    assert [:patch, :ticket] = for({kind, _, _, _} <- all_out(3), do: kind)
  end

  test "an agent that never says HELLO is closed at the deadline" do
    Application.put_env(:hireme, :hello_deadline_ms, 20)
    on_exit(fn -> Application.delete_env(:hireme, :hello_deadline_ms) end)
    {:ok, a} = Session.init({Carrier, self()}, %{ip: "198.51.100.11", origin: "", path: "/wt"})
    assert_receive {Session, :hello_deadline} = deadline, 500
    assert {:stop, :normal, _} = Session.info(deadline, a)
  end

  test "a ticketed raw browser gets its BOOT on a server stream right after accept",
       %{account: account} do
    job(profile())
    {_token, session} = Hireme.Accounts.start_session(account)
    t = Session.ticket(account.id, session.id)
    path = "/wt?" <> URI.encode_query(%{t: t, raw: 1, rev: 0, cid: 9})
    origin = HiremeWeb.Endpoint.url()
    {:ok, s} = Session.init({Carrier, self()}, %{ip: "", origin: origin, path: path})
    s = drain(s)
    assert_received {:uni, 3}
    frames = all_out(3)
    assert [{:boot, _, rev, _} | _] = frames
    assert {:ticket, _, ^rev, _} = List.last(frames)

    # The browser's HELLO afterwards only opens control.
    assert {:ok, _} = Session.event({:data, 0, hello()}, s)
  end

  test "a stopping node tells its sessions to resume elsewhere, waits for them, and admits no more",
       %{account: account} do
    {_token, session} = Hireme.Accounts.start_session(account)
    test = self()

    # The session runs as a carrier's process would, and ends on its BYE.
    live =
      Task.async(fn ->
        {:ok, s} =
          Session.init({Carrier, test}, %{account_id: account.id, session_id: session.id})

        send(test, :admitted)

        receive do
          Session.Drain -> {:stop, :normal, _} = Session.info(Session.Drain, s)
        end
      end)

    assert_receive :admitted
    all_out()
    stopping = Task.async(fn -> Supervisor.terminate_child(Hireme.Supervisor, Session.Drain) end)

    try do
      # The stop returns once the session has gone.
      assert :ok = Task.await(stopping, 1000)
      Task.await(live)
      assert {:bye, _, _, <<7::little-16, "restart", _::binary>>} = List.last(all_out())
      assert :error = HiremeWeb.WireSocket.connect(%{})
      assert {:refuse, 429} = Session.init({Carrier, self()}, %{path: "/wt", origin: ""})
    after
      Supervisor.restart_child(Hireme.Supervisor, Session.Drain)
    end

    refute Session.Drain.draining?()
  end
end
