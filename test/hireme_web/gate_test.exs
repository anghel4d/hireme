defmodule HiremeWeb.GateTest do
  # The bridge protocol from the BEAM's side: a fake gate speaks bytes on
  # the Unix socket, and a stand-in Session records what it is handed.
  use ExUnit.Case, async: false

  alias HiremeWeb.Gate

  defmodule Echo do
    @moduledoc false
    # A Session that reports every callback to the test and runs the
    # writes the test sends it, from its own process.
    def init(carrier, meta) do
      test = Application.fetch_env!(:hireme, :gate_test_pid)
      send(test, {:init, meta})

      case meta.path do
        "/wt/refuse" ->
          {:refuse, 403}

        "/wt/boot" ->
          :ok = Gate.ready(carrier)
          :ok = Gate.open_uni(carrier, 3)
          :ok = Gate.send(carrier, 3, "BOOT")
          :ok = Gate.fin(carrier, 3)
          {:ok, {test, carrier}}

        _ ->
          {:ok, {test, carrier}}
      end
    end

    def event(event, {test, _} = state) do
      send(test, {:event, event})
      if event == {:data, 0, "bye"}, do: {:stop, :bye, state}, else: {:ok, state}
    end

    def info({:write, fun}, {_, carrier} = state) do
      fun.(carrier)
      {:ok, state}
    end

    def terminate(reason, {test, _}), do: send(test, {:terminate, reason})
  end

  setup do
    path = Path.join(System.tmp_dir!(), "gate-#{System.unique_integer([:positive])}.sock")
    Application.put_env(:hireme, :gate_test_pid, self())
    start_supervised!({Gate, socket: path, session: Echo})

    on_exit(fn ->
      Application.delete_env(:hireme, :gate_test_pid)
      File.rm(path)
    end)

    %{path: path}
  end

  defp dial(path, origin \\ "http://localhost:4000", route \\ "/wt?t=abc") do
    {:ok, s} = :gen_tcp.connect({:local, path}, 0, [:binary, packet: 4, active: false])
    ip = "203.0.113.9"

    :ok =
      :gen_tcp.send(
        s,
        <<0x01, byte_size(ip), ip::binary, byte_size(origin)::16, origin::binary,
          byte_size(route)::16, route::binary>>
      )

    s
  end

  defp session_pid do
    [{_, pid, _, _}] = Supervisor.which_children(HiremeWeb.Gate.Sessions)
    pid
  end

  test "OPEN reaches init with its fields, and the answer is ACCEPT", %{path: path} do
    s = dial(path, "", "/wt")
    assert_receive {:init, %{ip: "203.0.113.9", origin: "", path: "/wt"}}
    assert {:ok, <<0x02>>} = :gen_tcp.recv(s, 0, 1000)
  end

  test "a refusing Session answers REFUSE with its status and the socket closes", %{path: path} do
    s = dial(path, "http://localhost:4000", "/wt/refuse")
    assert {:ok, <<0x03, 403::16>>} = :gen_tcp.recv(s, 0, 1000)
    assert {:error, :closed} = :gen_tcp.recv(s, 0, 1000)
  end

  test "writes made in init reach the gate ahead of the ACCEPT, in order", %{path: path} do
    s = dial(path, "http://localhost:4000", "/wt/boot")

    for bytes <- [<<0x04>>, <<0x15, 3::32>>, <<0x11, 3::32, "BOOT">>, <<0x12, 3::32>>, <<0x02>>],
        do: assert({:ok, ^bytes} = :gen_tcp.recv(s, 0, 1000))
  end

  test "gate messages arrive as events in order (seeded)", %{path: path} do
    seed = :rand.uniform(1_000_000)
    :rand.seed(:exsss, {seed, seed, seed})
    s = dial(path)
    assert {:ok, <<0x02>>} = :gen_tcp.recv(s, 0, 1000)

    events =
      for _ <- 1..300 do
        id = 4 * (:rand.uniform(50) - 1)
        bytes = :crypto.strong_rand_bytes(:rand.uniform(200) - 1)
        code = :rand.uniform(0xFFFFFFFF) - 1

        Enum.random([
          {:stream, id},
          {:data, id, bytes},
          {:fin, id},
          {:reset, id, code},
          {:stop, id, code},
          {:dgram, bytes}
        ])
      end

    for e <- events, do: :ok = :gen_tcp.send(s, encode(e))

    for e <- events do
      assert_receive {:event, ^e}, 1000, "seed #{seed}"
    end
  end

  test "carrier writes reach the gate as the documented bytes", %{path: path} do
    s = dial(path)
    assert {:ok, <<0x02>>} = :gen_tcp.recv(s, 0, 1000)

    send(
      session_pid(),
      {:write,
       fn c ->
         :ok = Gate.ready(c)
         :ok = Gate.send(c, 0, ["PA", "TCH"])
         :ok = Gate.fin(c, 0)
         :ok = Gate.reset(c, 4, 7)
         :ok = Gate.close(c, 42, "done")
       end}
    )

    expected = [
      <<0x04>>,
      <<0x11, 0::32, "PATCH">>,
      <<0x12, 0::32>>,
      <<0x13, 4::32, 7::32>>,
      <<0x30, 42::32, "done">>
    ]

    for bytes <- expected, do: assert({:ok, ^bytes} = :gen_tcp.recv(s, 0, 1000))
  end

  test "a Session's stop closes the socket, and a closed socket ends the Session", %{path: path} do
    s = dial(path)
    assert {:ok, <<0x02>>} = :gen_tcp.recv(s, 0, 1000)
    :ok = :gen_tcp.send(s, encode({:data, 0, "bye"}))
    assert_receive {:terminate, :bye}
    assert {:error, :closed} = :gen_tcp.recv(s, 0, 1000)

    s = dial(path)
    assert {:ok, <<0x02>>} = :gen_tcp.recv(s, 0, 1000)
    :ok = :gen_tcp.send(s, encode({:closed, 0, "peer"}))
    assert_receive {:event, {:closed, 0, "peer"}}
    :gen_tcp.close(s)
    assert_receive {:event, {:closed, 0, "bridge closed"}}
    assert_receive {:terminate, :normal}
  end

  @tag capture_log: true
  test "a second node leaves a live socket alone, and a dead one is taken over", %{path: path} do
    assert :ignore = Gate.start_link(socket: path, session: Echo)
    s = dial(path)
    assert {:ok, <<0x02>>} = :gen_tcp.recv(s, 0, 1000)

    stale = Path.join(System.tmp_dir!(), "gate-stale-#{System.unique_integer([:positive])}.sock")
    {:ok, l} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, stale}])
    :gen_tcp.close(l)
    assert File.exists?(stale)
    stop_supervised!(Gate)
    start_supervised!({Gate, socket: stale, session: Echo})
    s = dial(stale)
    assert {:ok, <<0x02>>} = :gen_tcp.recv(s, 0, 1000)
    File.rm(stale)
  end

  test "a connection that never sends OPEN is dropped", %{path: path} do
    {:ok, s} = :gen_tcp.connect({:local, path}, 0, [:binary, packet: 4, active: false])
    assert {:error, :closed} = :gen_tcp.recv(s, 0, 3000)
    refute_received {:init, _}
  end

  describe "the gate binary as a Port" do
    # A stand-in gate: it records its socket, each stdin line, and EOF (a
    # moment after it, as the gate drains), and exits when told to.
    defp stand_in(dir) do
      script =
        ~s(echo "$GATE_SOCKET" >> started; while read l; do echo "$l" >> lines; ) <>
          ~s([ "$l" = die ] && exit 3; done; sleep 0.3; echo eof >> lines)

      [cmd: ["sh", "-c", script], cd: dir]
    end

    defp eventually(fun, tries \\ 100) do
      cond do
        fun.() -> :ok
        tries == 0 -> flunk("condition never held")
        true -> Process.sleep(30) && eventually(fun, tries - 1)
      end
    end

    defp read(dir, file), do: File.read(Path.join(dir, file)) |> elem(1) |> to_string()

    setup %{path: path} do
      stop_supervised!(Gate)
      dir = Path.join(System.tmp_dir!(), "gate-bin-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      start_supervised!({Gate, [socket: path, session: Echo] ++ stand_in(dir)})
      %{dir: dir}
    end

    test "starts with the socket, takes commands, and is gone when the node has stopped it",
         %{dir: dir, path: path} do
      eventually(fn -> read(dir, "started") == path <> "\n" end)
      Gate.reload()
      Gate.stats()
      eventually(fn -> read(dir, "lines") == "reload\nstats\n" end)
      stop_supervised!(Gate)
      assert read(dir, "lines") == "reload\nstats\neof\n"
    end

    @tag :capture_log
    test "a gate that exits is started again; the bridge keeps its sessions",
         %{dir: dir, path: path} do
      eventually(fn -> read(dir, "started") != "" end)
      s = dial(path)
      assert {:ok, <<0x02>>} = :gen_tcp.recv(s, 0, 1000)
      send(HiremeWeb.Gate.Binary, {:command, "die"})
      eventually(fn -> read(dir, "started") == String.duplicate(path <> "\n", 2) end)
      :ok = :gen_tcp.send(s, <<0x12, 0::32>>)
      assert_receive {:event, {:fin, 0}}
    end
  end

  defp encode({:stream, id}), do: <<0x10, id::32>>
  defp encode({:data, id, b}), do: <<0x11, id::32, b::binary>>
  defp encode({:fin, id}), do: <<0x12, id::32>>
  defp encode({:reset, id, c}), do: <<0x13, id::32, c::32>>
  defp encode({:stop, id, c}), do: <<0x14, id::32, c::32>>
  defp encode({:dgram, b}), do: <<0x20, b::binary>>
  defp encode({:closed, c, r}), do: <<0x30, c::32, r::binary>>
end
