defmodule Hireme.Letterbox.Box do
  @moduledoc """
  The consumer side of one lease.

  The process lives exactly as long as the lease. Every exclusion is a
  unique key in `Hireme.Letterbox.Registry` owned by this process: the
  producer, the application, the employer's lineage, and the box itself.
  When the lease fails, is released, or the producer dies, the process
  stops and the registry drops every key with it.
  """

  use GenServer

  alias Hireme.CvPair
  alias Hireme.Desk
  alias Hireme.Desk.Signal
  alias Hireme.Letterbox.Handle
  alias Hireme.Letterbox.Record
  alias Hireme.Repo

  @registry Hireme.Letterbox.Registry

  def child_spec(letterbox_id) do
    %{
      id: {__MODULE__, letterbox_id},
      start: {__MODULE__, :start_link, [letterbox_id]},
      restart: :temporary
    }
  end

  def start_link(letterbox_id) do
    GenServer.start_link(__MODULE__, letterbox_id,
      name: {:via, Registry, {@registry, {:box, letterbox_id}}}
    )
  end

  def init(letterbox_id), do: {:ok, %{id: letterbox_id, pair: nil, token: nil, producer: nil}}

  def handle_call({:lease, producer}, _from, %{token: nil, id: id} = state)
      when is_pid(producer) do
    with :ok <- claim({:producer, producer}, :one_lease),
         {:ok, pair} <- load_pair(id),
         :ok <- claim({:job, CvPair.job_id(pair)}, :busy),
         :ok <- claim({:lineage, CvPair.lineage_id(pair)}, :lineage_busy) do
      Process.monitor(producer)
      Phoenix.PubSub.subscribe(Hireme.PubSub, Desk.topic())
      token = make_ref()
      handle = %Handle{id: id, token: token, pid: self(), pair: pair}
      {:reply, {:ok, handle}, %{state | pair: pair, token: token, producer: producer}}
    else
      {:error, reason} -> {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call({:lease, _producer}, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call(
        {:cmd, token, command},
        {caller, _},
        %{token: token, producer: caller, pair: pair} = state
      ) do
    {:reply, Desk.perform(pair, command), state}
  end

  def handle_call({:cmd, _token, _command}, _from, state), do: {:reply, {:error, :lease}, state}

  # The registry clears keys on exit asynchronously; the caller must see
  # the lease gone the moment it hears `:ok`.
  def handle_call(
        {:release, token},
        {caller, _},
        %{token: token, producer: caller, pair: pair} = state
      ) do
    Registry.unregister(@registry, {:producer, caller})
    Registry.unregister(@registry, {:job, CvPair.job_id(pair)})
    Registry.unregister(@registry, {:lineage, CvPair.lineage_id(pair)})
    {:stop, :normal, :ok, state}
  end

  def handle_call({:release, _token}, _from, state), do: {:reply, {:error, :lease}, state}

  def handle_info({:DOWN, _ref, :process, producer, _reason}, %{producer: producer} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:desk_event, %Signal{} = signal}, %{producer: producer, pair: pair} = state) do
    if Signal.about?(signal, CvPair.job_id(pair)), do: send(producer, {:desk_event, signal})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp claim(key, refusal) do
    case Registry.register(@registry, key, true) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> {:error, refusal}
    end
  end

  defp load_pair(letterbox_id) do
    case Repo.get(Record, letterbox_id) do
      nil -> {:error, :letterbox}
      record -> CvPair.bind(record.job_app_id)
    end
  end
end
