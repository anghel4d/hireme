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

  defp frames(id) do
    receive do
      {:out, ^id, bin} ->
        {:ok, frames, ""} = Packet.split(bin)
        frames
    after
      1_000 -> flunk("no frame on stream #{inspect(id)}")
    end
  end

  # Feed every delta waiting in this process's mailbox to the session.
  defp drain(s) do
    receive do
      {:ops_delta, _, _} = delta ->
        {:ok, s} = Session.info(delta, s)
        drain(s)
    after
      50 -> s
    end
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
    _ = all_out()

    {:ok, _s} = Session.event({:data, 0, op(42, 1, job.id, ["no_such_stage"])}, s)

    assert [
             {:nack, 0, _,
              <<42::little-64, code::8, 0::8, len::little-16, msg::binary-size(len), _::binary>>}
           ] = frames(0)

    assert code == Packet.refusal_code(:argument)
    assert msg =~ "stage"
  end

  test "a replayed op id is answered from the ledger, once", %{account: account} do
    p = profile()
    job = job(p)
    s = open(account)
    {:ok, s} = Session.event({:data, 0, hello()}, s)
    _ = all_out()

    {:ok, s} = Session.event({:data, 0, op(43, 2, job.id, ["Call", ""])}, s)
    s = drain(s)

    first =
      frames(0) ++
        receive do
          {:out, 0, b} -> elem(Packet.split(b), 1)
        after
          100 -> []
        end

    assert Enum.any?(first, &match?({:ack, _, _, <<43::little-64>>}, &1))

    {:ok, _s} = Session.event({:data, 0, op(43, 2, job.id, ["Call", ""])}, s)
    assert [{:ack, 0, _, <<43::little-64>>}] = frames(0)
    refute_receive {:ops_delta, _, _}, 100
  end

  test "a snapshot at the current rev resumes with one PATCH; garbage says bye", %{
    account: account
  } do
    job = job(profile())
    s = open(account)
    {:ok, s} = Session.event({:data, 0, hello()}, s)
    [{:boot, _, _, _} | _] = all_out()
    {:ok, s} = Session.event({:data, 0, op(44, 2, job.id, ["Call", ""])}, s)
    s = drain(s)
    rev = s.rev
    assert rev > 0

    _ = all_out()
    s2 = open(account)
    {:ok, _} = Session.event({:data, 0, hello(rev)}, s2)
    assert [{:patch, 0x02, ^rev, _clock_and_account}, {:ticket, 0, ^rev, _}] = all_out()

    assert {:stop, :normal, _} = Session.event({:data, 0, <<12::little-32, 0::96>>}, s)
    assert [{:bye, 0, _, _}] = all_out()
  end

  # Every frame written so far, in order.
  defp all_out do
    receive do
      {:out, 0, bin} ->
        {:ok, frames, ""} = Packet.split(bin)
        frames ++ all_out()
    after
      50 -> []
    end
  end

  test "tickets are single use and name a live session", %{account: account} do
    {_token, session} = Hireme.Accounts.start_session(account)
    t = Session.ticket(account.id, session.id)
    assert {:ok, account_id, session_id} = Session.redeem(t)
    assert {account_id, session_id} == {account.id, session.id}
    assert :error = Session.redeem(t)
    assert :error = Session.redeem("garbage")
  end

  test "the websocket carrier admits a live cookie session", %{account: account} do
    {token, session} = Hireme.Accounts.start_session(account)
    Hireme.Repo.put_account(nil)
    info = %{connect_info: %{session: %{HiremeWeb.Auth.session_key() => token}}}
    assert {:ok, %{account_id: id, session_id: sid}} = HiremeWeb.WireSocket.connect(info)
    assert {id, sid} == {account.id, session.id}
    # No cookie: an agent, admitted only as far as its API-key HELLO.
    assert {:ok, %{origin: "", path: "/wt"}} =
             HiremeWeb.WireSocket.connect(%{connect_info: %{session: %{}}})
  end

  test "an op on a line or job that is not there is refused, and the next op still answers",
       %{account: account} do
    job = job(profile())
    s = open(account)
    {:ok, s} = Session.event({:data, 0, hello()}, s)
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

  # ---- Raw mode (round two): the client derives every view ----

  defp raw_hello(snapshot \\ 0) do
    IO.iodata_to_binary(
      Packet.frame(
        :hello,
        0,
        <<0::little-16, 0::48, snapshot::little-64, 7::little-32, 1::little-32>>
      )
    )
  end

  defp inflate({kind, flags, rev, body}) when Bitwise.band(flags, 1) == 1 do
    <<_raw::little-32, z_len::little-32, rest::binary>> = body
    <<z::binary-size(^z_len), _::binary>> = rest
    {kind, Bitwise.band(flags, 0xFE), rev, :zlib.unzip(z)}
  end

  defp inflate(frame), do: frame

  defp table_ids(body), do: table_ids(body, [])
  defp table_ids(<<>>, acc), do: Enum.reverse(acc)

  defp table_ids(<<id::little-16, ncols::little-16, _n::little-32, rest::binary>>, acc) do
    rest =
      Enum.reduce(1..ncols//1, rest, fn _, <<_::16, _::8, _::8, size::little-32, rest::binary>> ->
        skip = size + rem(8 - rem(size, 8), 8)
        <<_::binary-size(^skip), rest::binary>> = rest
        rest
      end)

    table_ids(rest, [id | acc])
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
    {:ok, s} = Session.event({:data, 0, raw_hello()}, s)
    [{:boot, 0x02, rev, body}, {:patch, 0, rev2, listings} | _] = Enum.map(all_out(), &inflate/1)
    # The listings follow the board in their own frame, at the same rev.
    assert rev2 == rev
    refute body =~ "Elixir, Rust and WebAssembly."
    assert listings =~ "Elixir, Rust and WebAssembly."
    ids = table_ids(body)
    for t <- [:job_apps, :profiles, :clock, :acct, :stages], do: assert(Packet.table_id(t) in ids)
    refute Packet.table_id(:cards) in ids

    {:ok, s} = Session.event({:data, 0, op(61, 2, job.id, ["Call", ""])}, s)
    _s = drain(s)
    out = all_out()
    [{:patch, 0, prev, pbody} | _] = Enum.filter(out, &match?({:patch, _, _, _}, &1))
    assert prev > rev
    assert Packet.table_id(:job_apps) in table_ids(pbody)
    # Only the columns the write changed travel, never the listing.
    assert byte_size(pbody) < 600

    assert Enum.find_index(out, &match?({:patch, _, _, _}, &1)) <
             Enum.find_index(out, &match?({:ack, _, _, <<61::little-64>>}, &1))
  end

  test "a raw resume replays only the revisions since the snapshot", %{account: account} do
    job = job(profile())
    s = open(account)
    {:ok, s} = Session.event({:data, 0, raw_hello()}, s)
    [{:boot, _, rev0, _} | _] = all_out()
    {:ok, s} = Session.event({:data, 0, op(62, 2, job.id, ["One", ""])}, s)
    {:ok, s} = Session.event({:data, 0, op(63, 2, job.id, ["Two", ""])}, s)
    s = drain(s)
    _ = all_out()

    s2 = open(account)
    {:ok, _} = Session.event({:data, 0, raw_hello(rev0)}, s2)
    out = all_out()
    patches = for {:patch, _, r, _} <- out, do: r
    assert List.last(patches) == s.rev
    assert length(patches) == 3

    assert [{:patch, 0x02, _, _} | _] =
             Enum.reverse(Enum.filter(out, &match?({:patch, _, _, _}, &1)))

    refute Enum.any?(out, &match?({:boot, _, _, _}, &1))
  end

  test "account commands ride the session as RPC, tables before the reply", %{account: account} do
    {:ok, %{key: key}} = Hireme.ApiKeys.create("bench")
    s = open(account)
    {:ok, s} = Session.event({:data, 0, raw_hello()}, s)
    _ = all_out()

    req =
      Jason.encode!(%{
        id: 9,
        method: "account/rename_key",
        params: %{id: key.id, name: "renamed"}
      })

    {:ok, _s} =
      Session.event({:data, 0, IO.iodata_to_binary(HiremeWeb.LetterboxStream.rpc(req))}, s)

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

    {:ok, a} =
      Session.init({Carrier, self()}, %{ip: "198.51.100.9", origin: "", path: "/wt"})

    hello =
      IO.iodata_to_binary(
        Packet.frame(
          :hello,
          0,
          [
            <<byte_size(secret)::little-16, secret::binary>>,
            :binary.copy(<<0>>, rem(8 - rem(2 + byte_size(secret), 8), 8)),
            <<0::little-64, 3::little-32, 0::little-32>>
          ],
          flags: 0x80
        )
      )

    {:ok, a} = Session.event({:data, 0, hello}, a)
    assert [{:boot, 0x03, _, _} = boot | _] = all_out()
    {:boot, 0x02, _, body} = inflate(boot)
    ids = table_ids(body)
    # An agent gets the browser's raw BOOT and derives its own views.
    assert Packet.table_id(:batches) in ids
    assert Packet.table_id(:job_apps) in ids

    op = %{op_id: 70, kind: :next, target: job.id, fields: ["Agent sees", ""]}
    assert {:ok, _} = Hireme.Ops.run(account.id, op)
    a = drain(a)
    assert [{:patch, 0, _, pbody}] = all_out()
    assert Packet.table_id(:job_apps) in table_ids(pbody)

    # Its own writes go up as OPs on control and come back ACKed.
    {:ok, a} = Session.event({:data, 0, op(71, 2, job.id, ["Agent writes", ""])}, a)
    _a = drain(a)
    assert Enum.any?(all_out(), &match?({:ack, _, _, <<71::little-64>>}, &1))
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

  test "on a carrier without streams an agent's lease rides control as a lane",
       %{account: account} do
    job = job(profile())
    letterbox = Hireme.Letterbox.for_job(job.id)
    {:ok, %{secret: secret}} = Hireme.ApiKeys.create("lanes")
    {:ok, a} = Session.init({Carrier, self()}, %{ip: "198.51.100.10", origin: "", path: "/wt"})

    hello =
      IO.iodata_to_binary(
        Packet.frame(
          :hello,
          0,
          [
            <<byte_size(secret)::little-16, secret::binary>>,
            :binary.copy(<<0>>, rem(8 - rem(2 + byte_size(secret), 8), 8)),
            <<0::little-64, 3::little-32, 0::little-32>>
          ],
          flags: 0x80
        )
      )

    {:ok, a} = Session.event({:data, 0, hello}, a)
    _ = all_out()

    lease = IO.iodata_to_binary(Packet.frame(:lease, 1, <<letterbox.id::little-64>>))
    {:ok, a} = Session.event({:data, 0, lease}, a)
    assert Map.has_key?(a.letters, {:lane, 1})

    a = settle_letters(a)
    out = all_out()
    assert out != [] and Enum.all?(out, &match?({_, _, 1, _}, &1))

    {:ok, a} = Session.event({:data, 0, IO.iodata_to_binary(Packet.frame(:bye, 1, <<0::16>>))}, a)
    refute Map.has_key?(a.letters, {:lane, 1})
  end

  test "an agent that never says HELLO is closed", %{account: _account} do
    {:ok, a} = Session.init({Carrier, self()}, %{ip: "198.51.100.11", origin: "", path: "/wt"})
    assert {:stop, :normal, _} = Session.info({Session, :hello_deadline}, a)
  end

  # Feed the lease processes' replies back through the session, as its host would.
  defp settle_letters(s) do
    receive do
      {Session, :letter, _, _} = m ->
        {:ok, s} = Session.info(m, s)
        settle_letters(s)
    after
      200 -> s
    end
  end
end
