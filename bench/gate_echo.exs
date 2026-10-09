# An echoing Session behind the real gate, for native/gate/netem.sh and the
# probe's echo and bulk modes. It lifts the gate's caps at OPEN, as a
# ticketed browser session does.
#
#   GATE_SOCKET=/path/to.sock MIX_ENV=test mix run --no-start bench/gate_echo.exs
#
# Control stream: "E" + 8 bytes is echoed back; "B" + u32 LE asks for that
# many bytes on a new server uni stream at priority -1 (BULK_PRIO overrides),
# sent in one write as the real Session sends a BOOT. Datagrams are echoed.
defmodule HiremeBench.GateEcho do
  alias HiremeWeb.Gate

  @prio String.to_integer(System.get_env("BULK_PRIO", "-1"))

  def init(c, _meta) do
    Gate.ready(c)
    {:ok, %{c: c, buf: <<>>, next_uni: 3}}
  end

  def event({:data, 0, bytes}, s), do: {:ok, drain(%{s | buf: s.buf <> bytes})}

  def event({:dgram, b}, s) do
    Gate.datagram(s.c, b)
    {:ok, s}
  end

  def event(_event, s), do: {:ok, s}
  def info(_message, s), do: {:ok, s}
  def terminate(_reason, _s), do: :ok

  defp drain(%{buf: <<"E", m::binary-size(8), rest::binary>>} = s) do
    Gate.send(s.c, 0, ["E", m])
    drain(%{s | buf: rest})
  end

  defp drain(%{buf: <<"B", n::little-32, rest::binary>>} = s) do
    id = s.next_uni
    Gate.open_uni(s.c, id, @prio)
    Gate.send(s.c, id, :binary.copy(<<7>>, n))
    Gate.fin(s.c, id)
    drain(%{s | buf: rest, next_uni: id + 4})
  end

  defp drain(s), do: s
end

{:ok, _} =
  HiremeWeb.Gate.start_link(
    socket: System.fetch_env!("GATE_SOCKET"),
    session: HiremeBench.GateEcho
  )

Process.sleep(:infinity)
