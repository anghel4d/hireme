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
    def open_uni({__MODULE__, pid}, id, prio), do: Kernel.send(pid, {:uni, id, prio})
    def open_bi(_c, _id, _prio), do: :ok
    def priority(_c, _id, _prio), do: :ok
    def datagram(c, io), do: __MODULE__.send(c, :dgram, io)
    def ready({__MODULE__, pid}), do: Kernel.send(pid, :ready)
    def close({__MODULE__, pid}, code, reason), do: Kernel.send(pid, {:close, code, reason})
  end

  defp hello(snapshot \\ 0) do
    IO.iodata_to_binary(
      Packet.frame(:hello, 0, <<0::little-16, 0::48, snapshot::little-64, 7::little-32, 0::32>>)
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

  test "hello boots the desk, then a write answers PATCH before its ACK", %{account: account} do
    p = profile()
    item(p)
    job = job(p, %{company: "Acme"})
    s = open(account)

    {:ok, s} = Session.event({:stream, 0}, s)
    {:ok, s} = Session.event({:data, 0, hello()}, s)
    assert_received :ready
    assert [{:boot, flags, rev, _}] = frames(0)
    assert Bitwise.band(flags, 0x03) == 0x03
    assert [{:ticket, 0, ^rev, _}] = frames(0)
    assert_receive {:uni, 3, -1}

    stage = Packet.op_kind(1)
    assert stage == :stage
    {:ok, s} = Session.event({:data, 0, op(41, 1, job.id, ["gated"])}, s)
    s = drain(s)

    out = frames(0)
    kinds = Enum.map(out, &elem(&1, 0))
    assert [:patch | _] = kinds
    [{:patch, 0, patch_rev, _} | _] = out
    assert patch_rev > rev

    acks = if :ack in kinds, do: out, else: frames(0)
    assert Enum.any?(acks, &match?({:ack, 0, ^patch_rev, <<41::little-64>>}, &1))
    assert s.rev == patch_rev
  end

  test "a refused op answers NACK with its code and keeps nothing", %{account: account} do
    p = profile()
    job = job(p)
    s = open(account)
    {:ok, s} = Session.event({:data, 0, hello()}, s)
    _ = frames(0)
    _ = frames(0)

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
    _ = frames(0)
    _ = frames(0)

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

  test "a snapshot at the current rev resumes with an empty PATCH; garbage says bye", %{
    account: account
  } do
    job = job(profile())
    s = open(account)
    {:ok, s} = Session.event({:data, 0, hello()}, s)
    [{:boot, _, _, _}] = frames(0)
    [{:ticket, _, _, _}] = frames(0)
    {:ok, s} = Session.event({:data, 0, op(44, 2, job.id, ["Call", ""])}, s)
    s = drain(s)
    rev = s.rev
    assert rev > 0

    _ = all_out()
    s2 = open(account)
    {:ok, _} = Session.event({:data, 0, hello(rev)}, s2)
    assert [{:patch, 0x02, ^rev, <<>>}, {:ticket, 0, ^rev, _}] = all_out()

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

  test "the focus cache serves until a delta marks the job dirty", %{account: account} do
    start_supervised!(HiremeWeb.Session.Cache)
    p = profile()
    job = job(p, %{company: "Cached"})
    cache = HiremeWeb.Session.Cache

    first = cache.focus(account.id, job.id, 5)
    assert first.job.company == "Cached"
    Hireme.Repo.update_all(Hireme.Desk.Job, set: [company: "Moved"])
    assert cache.focus(account.id, job.id, 6).job.company == "Cached"

    cache.dirty(account.id, [job.id], 7)
    assert cache.focus(account.id, job.id, 7).job.company == "Moved"
  end

  test "the websocket carrier admits a live cookie session", %{account: account} do
    {token, session} = Hireme.Accounts.start_session(account)
    Hireme.Repo.put_account(nil)
    info = %{connect_info: %{session: %{HiremeWeb.Auth.session_key() => token}}}
    assert {:ok, %{account_id: id, session_id: sid}} = HiremeWeb.WireSocket.connect(info)
    assert {id, sid} == {account.id, session.id}
    assert :error = HiremeWeb.WireSocket.connect(%{connect_info: %{session: %{}}})
  end
end
