defmodule Hireme.Letterbox.Box do
  @moduledoc false

  use GenServer

  alias Hireme.CvPair
  alias Hireme.Desk
  alias Hireme.Desk.Signal
  alias Hireme.Letterbox.Handle
  alias Hireme.Letterbox.Id
  alias Hireme.Letterbox.LineageGate
  alias Hireme.Letterbox.Record
  alias Hireme.Letterbox.Token
  alias Hireme.Repo

  def child_spec(letterbox_id) do
    %{
      id: {__MODULE__, letterbox_id},
      start: {__MODULE__, :start_link, [letterbox_id]},
      restart: :temporary
    }
  end

  def start_link(letterbox_id) do
    GenServer.start_link(__MODULE__, letterbox_id, name: via(letterbox_id))
  end

  def init(letterbox_id) do
    {:ok,
     %{
       id: letterbox_id,
       pair: nil,
       token: nil,
       producer: nil,
       monitor: nil
     }}
  end

  def handle_call({:lease, producer}, _from, %{token: nil} = state) when is_pid(producer) do
    case take_lease(producer, state.id) do
      {:ok, handle, pair, monitor} ->
        {:reply, {:ok, handle},
         %{state | pair: pair, token: handle.token.ref, producer: producer, monitor: monitor}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:lease, _producer}, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(
        {:cmd, token, command},
        {caller, _tag},
        %{token: token, producer: caller, pair: pair} = state
      ) do
    {:reply, Desk.perform(pair, command), state}
  end

  def handle_call({:cmd, _token, _command}, _from, state) do
    {:reply, {:error, :lease}, state}
  end

  def handle_call({:release, token}, {caller, _tag}, %{token: token, producer: caller} = state) do
    let_go(state)
    {:stop, :normal, :ok, %{state | token: nil, producer: nil}}
  end

  def handle_call({:release, _token}, _from, state) do
    {:reply, {:error, :lease}, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:desk_event, %Signal{} = signal}, %{producer: producer, pair: pair} = state)
      when is_pid(producer) do
    if Signal.about?(signal, CvPair.job_id(pair)), do: send(producer, {:desk_event, signal})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  def terminate(_reason, state) do
    let_go(state)
    :ok
  end

  # The lease is gone the moment the producer hears `:ok`, so the
  # registry keys are dropped here, before the process exits, instead of
  # waiting on the registry to see the DOWN.
  defp let_go(%{pair: nil}), do: :ok

  defp let_go(%{pair: pair, id: id, producer: producer}) do
    if is_pid(producer), do: Registry.unregister(Hireme.Letterbox.Registry, {:producer, producer})
    Registry.unregister(Hireme.Letterbox.Registry, {:job, CvPair.job_id(pair)})
    Registry.unregister(Hireme.Letterbox.Registry, {:leased, id})

    try do
      LineageGate.release(CvPair.lineage_id(pair), id)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp load_pair(letterbox_id) do
    case Repo.get(Record, letterbox_id) do
      nil -> {:error, :letterbox}
      record -> CvPair.bind(record.job_app_id)
    end
  end

  defp take_lease(producer, letterbox_id) do
    case register_producer(producer, letterbox_id) do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        case load_pair(letterbox_id) do
          {:error, reason} ->
            Registry.unregister(Hireme.Letterbox.Registry, {:producer, producer})
            {:error, reason}

          {:ok, pair} ->
            hold(producer, letterbox_id, pair)
        end
    end
  end

  defp hold(producer, letterbox_id, pair) do
    with :ok <- register_job(pair),
         :ok <- LineageGate.acquire(CvPair.lineage_id(pair), letterbox_id, self()),
         :ok <- register_leased(letterbox_id) do
      token = make_ref()
      monitor = Process.monitor(producer)
      Phoenix.PubSub.subscribe(Hireme.PubSub, Desk.topic())

      handle = %Handle{
        id: Id.new(letterbox_id),
        token: %Token{ref: token},
        pid: self(),
        pair: pair
      }

      {:ok, handle, pair, monitor}
    else
      {:error, reason} ->
        Registry.unregister(Hireme.Letterbox.Registry, {:producer, producer})
        Registry.unregister(Hireme.Letterbox.Registry, {:job, CvPair.job_id(pair)})
        Registry.unregister(Hireme.Letterbox.Registry, {:leased, letterbox_id})
        LineageGate.release(CvPair.lineage_id(pair), letterbox_id)
        {:error, reason}
    end
  end

  defp register_producer(producer, letterbox_id) do
    case Registry.register(Hireme.Letterbox.Registry, {:producer, producer}, letterbox_id) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> {:error, :one_lease}
    end
  end

  defp register_job(pair) do
    case Registry.register(Hireme.Letterbox.Registry, {:job, CvPair.job_id(pair)}, true) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> {:error, :busy}
    end
  end

  defp register_leased(letterbox_id) do
    case Registry.register(Hireme.Letterbox.Registry, {:leased, letterbox_id}, true) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> {:error, :busy}
    end
  end

  defp via(letterbox_id) do
    {:via, Registry, {Hireme.Letterbox.Registry, {:box, letterbox_id}}}
  end
end
