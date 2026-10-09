# An echoing Session behind the real gate, for native/gate/netem.sh and the
# probe's echo and bulk modes. It lifts the gate's caps at OPEN, as a
# ticketed browser session does.
#
#   GATE_SOCKET=/path/to.sock MIX_ENV=test mix run --no-start bench/gate_echo.exs
#
# Control stream: "E" + 8 bytes is echoed back; "B" + u32 LE asks for that
# many bytes back on the same stream, sent in one write as the real Session
# sends a BOOT.
defmodule HiremeBench.GateEcho do
  alias HiremeWeb.Gate

  def init(c, _meta) do
    Gate.ready(c)
    {:ok, %{c: c, buf: <<>>}}
  end

  def event({:data, 0, bytes}, s), do: {:ok, drain(%{s | buf: s.buf <> bytes})}

  def event(_event, s), do: {:ok, s}
  def info(_message, s), do: {:ok, s}
  def terminate(_reason, _s), do: :ok

  defp drain(%{buf: <<"E", m::binary-size(8), rest::binary>>} = s) do
    Gate.send(s.c, 0, ["E", m])
    drain(%{s | buf: rest})
  end

  defp drain(%{buf: <<"B", n::little-32, rest::binary>>} = s) do
    Gate.send(s.c, 0, :binary.copy(<<7>>, n))
    drain(%{s | buf: rest})
  end

  defp drain(s), do: s
end

{:ok, _} =
  HiremeWeb.Gate.start_link(
    socket: System.fetch_env!("GATE_SOCKET"),
    session: HiremeBench.GateEcho
  )

Process.sleep(:infinity)
