defmodule HiremeWeb.LetterboxStream do
  @moduledoc """
  One agent lease: one small process, the lease's only holder.

  An agent authenticates once, in its session's HELLO, and then leases
  any number of applications, each on its own lane (a bidi stream, or on
  the WebSocket a header `rev` the session routes by). The Session calls
  `open/3` for each lane, feeds it the lane's bytes with `data/2`, and
  calls `fin/1` when the agent closes it. This process claims the lease
  itself (`Hireme.Letterbox.claim/1`) and runs the lease's writes through
  `Hireme.Ops` as the holder, so they pass the lease check that refuses
  everyone else. Closing the lane, the session ending, or the key being
  revoked releases the lease.

  On the lane, as everywhere else, frames are the wire's:

    * `LEASE`, first and once: `u64 job_id`. Answered `ACK` with op id 0,
      or `NACK` with op id 0 and the refusal (`not_found`, `busy`,
      `lineage_busy`), after which the lane closes.
    * `OP` for the leased job: one of the job's own kinds (stage, next,
      note, score, overlay, heat override, generation). Answered `ACK` or
      `NACK` by op id, after the delta that carries the write has been
      sent on the session.

  The agent reads everything else from the raw tables its session
  receives, as the browser does.
  """

  use GenServer

  alias Hireme.ApiKeys
  alias Hireme.Letterbox
  alias Hireme.Ops
  alias Hireme.Repo
  alias HiremeWeb.Packet

  @lease_kinds [:stage, :next, :note, :score, :overlay, :heat_override, :generation]
  @recheck_ms 60_000

  @type agent :: %{account_id: pos_integer(), key_id: String.t() | nil, expires_at: term()}
  @type sender :: (iodata() -> any())
  @type closer :: (atom() -> any())

  @doc """
  The agent a presented API key names, counted once against the peer's
  key limiter. An agent session calls this once for its HELLO.
  """
  @spec agent_key(term(), String.t()) :: {:ok, agent()} | :error
  def agent_key(token, peer) when is_binary(peer) do
    case ApiKeys.authenticate(token, peer) do
      {:ok, key} ->
        {:ok, %{account_id: key.account_id, key_id: key.key_id, expires_at: key.expires_at}}

      :error ->
        :error
    end
  end

  @doc """
  Start the process for one lane. `send` writes bytes to the lane and
  `close` ends it with a reason; both are called from this process. The
  caller is the session, and the lane dies with it. `lane:` is the
  number a lane on the session's own channel answers with in its frames'
  `rev`; a lane on a stream of its own (0, the default) answers an ACK
  with the revision it settles.
  """
  @spec open(agent(), sender(), closer(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open(%{account_id: account_id} = agent, send, close, opts \\ [])
      when is_integer(account_id) and is_function(send, 1) and is_function(close, 1) do
    callers = [self() | Process.get(:"$callers", [])]
    lane = Keyword.get(opts, :lane, 0)
    GenServer.start(__MODULE__, {agent, send, close, lane, self(), callers})
  end

  @doc "Bytes the agent wrote on this lane, in order."
  @spec data(pid(), binary()) :: :ok
  def data(pid, bytes) when is_binary(bytes), do: GenServer.cast(pid, {:data, bytes})

  @doc "The agent closed the lane: release the lease."
  @spec fin(pid()) :: :ok
  def fin(pid), do: GenServer.cast(pid, :fin)

  @impl true
  def init({agent, send, close, lane, session, callers}) do
    Process.put(:"$callers", callers)
    Repo.put_account(agent.account_id)
    Process.monitor(session)

    if key_id = agent[:key_id] do
      Phoenix.PubSub.subscribe(Hireme.PubSub, ApiKeys.topic(key_id))
      Process.send_after(self(), :recheck_key, @recheck_ms)
    end

    {:ok,
     %{
       key_id: agent[:key_id],
       account_id: agent.account_id,
       send: send,
       close: close,
       lane: lane,
       buffer: <<>>,
       pair: nil
     }}
  end

  @impl true
  def handle_cast({:data, bytes}, state) do
    case Packet.split(state.buffer <> bytes) do
      {:ok, frames, rest} -> frames(frames, %{state | buffer: rest})
      {:error, _} -> shut(state, :frame)
    end
  end

  def handle_cast(:fin, state), do: {:stop, :normal, state}

  @impl true
  def handle_info(:api_key_dead, state), do: shut(state, :revoked)

  def handle_info(:recheck_key, state) do
    if ApiKeys.usable?(state.key_id, state.account_id) do
      Process.send_after(self(), :recheck_key, @recheck_ms)
      {:noreply, state}
    else
      shut(state, :expired)
    end
  end

  def handle_info({:DOWN, _ref, :process, _session, _reason}, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{pair: pair}) when pair != nil, do: Letterbox.release(pair)
  def terminate(_reason, _state), do: :ok

  defp frames([], state), do: {:noreply, state}

  defp frames([frame | rest], state) do
    case frame(frame, state) do
      {:ok, state} -> frames(rest, state)
      stop -> stop
    end
  end

  defp frame({:lease, _flags, _rev, <<job_id::little-64, _::binary>>}, %{pair: nil} = state) do
    case Letterbox.claim(job_id) do
      {:ok, pair} ->
        state.send.(Packet.ack(0, state.lane))
        {:ok, %{state | pair: pair}}

      {:error, reason} ->
        state.send.(Packet.nack(0, reason, state.lane))
        shut(state, reason)
    end
  end

  defp frame({:op, _flags, _rev, body}, %{pair: pair} = state) when pair != nil do
    job_id = Hireme.CvPair.job_id(pair)

    answer =
      case Packet.op(body) do
        {:ok, %{kind: kind, target: ^job_id} = op} when kind in @lease_kinds ->
          case Ops.run(state.account_id, op) do
            {:ok, rev} -> Packet.ack(op.op_id, if(state.lane > 0, do: state.lane, else: rev))
            {:error, reason} -> Packet.nack(op.op_id, reason, state.lane)
          end

        {:ok, %{op_id: op_id}} ->
          Packet.nack(op_id, {:argument, "op for the leased job"}, state.lane)

        {:error, op_id} ->
          Packet.nack(op_id, {:argument, "op"}, state.lane)

        :error ->
          nil
      end

    if answer do
      state.send.(answer)
      {:ok, state}
    else
      shut(state, :op)
    end
  end

  defp frame(_frame, state), do: shut(state, :protocol)

  defp shut(state, reason) do
    state.close.(reason)
    {:stop, :normal, state}
  end
end
