defmodule Hireme.Letterbox.LineageGate do
  @moduledoc false

  use GenServer

  def child_spec(lineage_id) do
    %{
      id: {__MODULE__, lineage_id},
      start: {__MODULE__, :start_link, [lineage_id]},
      restart: :temporary
    }
  end

  def start_link(lineage_id) do
    GenServer.start_link(__MODULE__, lineage_id, name: via(lineage_id))
  end

  def acquire(lineage_id, letterbox_id, owner) when is_pid(owner) do
    {:ok, pid} = ensure(lineage_id)
    GenServer.call(pid, {:acquire, letterbox_id, owner})
  end

  def release(lineage_id, letterbox_id) do
    case Registry.lookup(Hireme.Letterbox.Registry, {:lineage, lineage_id}) do
      [{pid, _}] -> GenServer.call(pid, {:release, letterbox_id})
      [] -> :ok
    end
  end

  def init(lineage_id) do
    {:ok, %{lineage_id: lineage_id, owner: nil, monitor: nil}}
  end

  def handle_call({:acquire, letterbox_id, owner}, _from, %{owner: nil} = state) do
    monitor = Process.monitor(owner)
    {:reply, :ok, %{state | owner: {letterbox_id, owner}, monitor: monitor}}
  end

  def handle_call({:acquire, letterbox_id, owner}, _from, %{owner: {letterbox_id, owner}} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:acquire, _letterbox_id, _owner}, _from, state) do
    {:reply, {:error, :lineage_busy}, state}
  end

  def handle_call(
        {:release, letterbox_id},
        _from,
        %{owner: {letterbox_id, _}, monitor: monitor} = state
      ) do
    if monitor, do: Process.demonitor(monitor, [:flush])
    {:reply, :ok, %{state | owner: nil, monitor: nil}}
  end

  def handle_call({:release, _letterbox_id}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state) do
    {:noreply, %{state | owner: nil, monitor: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ensure(lineage_id) do
    case Registry.lookup(Hireme.Letterbox.Registry, {:lineage, lineage_id}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(Hireme.Letterbox.Supervisor, {__MODULE__, lineage_id}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
        end
    end
  end

  defp via(lineage_id) do
    {:via, Registry, {Hireme.Letterbox.Registry, {:lineage, lineage_id}}}
  end
end
