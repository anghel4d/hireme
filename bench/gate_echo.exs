# An echoing Session behind the real gate, for native/gate/netem.sh and the
# probe's echo and boot modes. It lifts the gate's caps at OPEN, as a
# ticketed browser session does.
#
#   GATE_SOCKET=/path/to.sock MIX_ENV=test mix run --no-start bench/gate_echo.exs
#
# Control stream: "E" + 8 bytes is echoed back. A CONNECT path with
# `?boot=N` gets N bytes on server uni stream 3, written in one go from
# inside init, ahead of the ACCEPT, as a ticketed browser's BOOT goes out.
defmodule HiremeBench.GateEcho do
  alias HiremeWeb.Gate

  def init(c, meta) do
    Gate.ready(c)

    with %{"boot" => n} <- URI.decode_query(URI.parse(meta.path).query || "") do
      Gate.open_uni(c, 3)
      Gate.send(c, 3, :binary.copy(<<7>>, String.to_integer(n)))
      Gate.fin(c, 3)
    end

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

  defp drain(s), do: s
end

{:ok, _} =
  HiremeWeb.Gate.start_link(
    socket: System.fetch_env!("GATE_SOCKET"),
    session: HiremeBench.GateEcho
  )

Process.sleep(:infinity)
