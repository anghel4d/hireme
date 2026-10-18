defmodule Hireme.Lease do
  @moduledoc """
  The write channel and application claims of an account's wire sessions.

  One lease per session. A browser session holds the channel from the
  start; a key's session opens it with its first `lease.claim`, and it is
  closed by `lease.release` with no ids, by the session ending (exit, key
  revoked or its masks changed, account suspended) or by the operator's
  revoke. There is no TTL: the carrier and PING/PONG are the liveness.

  Claims are explicit application ids. `%{"count" => n}` claims the `n`
  highest-ranked unclaimed applications in board order (`"stage"` filters
  first) and answers fewer with `truncated` when fewer exist; `%{"ids" =>
  [...]}` claims exactly those or nothing, refusing `leased` with the
  holder's label and `since` when another session holds one. An
  application a session creates is claimed by it.

  This module is the state machine; the state lives in the account's
  sequencer, which runs check 2 (`lease`) against it inside each op, so a
  claim and a write can never interleave. The functions taking an
  account id go through the sequencer.
  """

  alias Hireme.Sequencer

  defstruct sessions: %{}, holder: %{}

  @max_count 1_000

  @type session :: %{
          id: pos_integer,
          label: String.t(),
          key_id: pos_integer | nil,
          session_id: pos_integer | nil,
          channel: boolean,
          since: DateTime.t() | nil,
          held: MapSet.t()
        }
  @type t :: %__MODULE__{
          sessions: %{pos_integer => session},
          holder: %{pos_integer => pos_integer}
        }

  # ------------------------------------------------------------- API

  @doc "Claims applications for `session_id` (opening its channel); see the moduledoc."
  def claim(account_id, session_id, params),
    do: Sequencer.lease(account_id, {:claim, session_id, params})

  @doc "Releases `ids` (or everything, closing the channel, for `nil`)."
  def release(account_id, session_id, ids),
    do: Sequencer.lease(account_id, {:release, session_id, ids})

  @doc """
  The operator ends a session's lease: its claims go and its channel
  closes; the session stays connected, read-only. `meta` is the audit
  context of the operator's request. `:ok` or `{:error, :not_found}`.
  """
  def revoke(account_id, lease_id, meta) do
    with true <- Sequencer.running?(account_id) || {:error, :not_found},
         :ok <- Sequencer.lease(account_id, {:revoke, lease_id}) do
      Hireme.Audit.record(
        :lease_revoked,
        %{lease_id: lease_id},
        Map.put(meta, :account_id, account_id)
      )

      :ok
    end
  end

  @doc "The account's live leases, for the account lens."
  def leases(account_id) do
    if Sequencer.running?(account_id), do: list_running(account_id), else: []
  end

  defp list_running(account_id) do
    case Sequencer.lease(account_id, :list) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  # ---------------------------------------------------- state machine

  @doc "A session joins; `operator` sessions hold the channel from the start."
  @spec join(t, map, DateTime.t()) :: t
  def join(%__MODULE__{} = l, %{id: id, label: label, key_id: key_id} = info, now) do
    operator = key_id == nil

    s = %{
      id: id,
      label: label,
      key_id: key_id,
      session_id: info[:session_id],
      ip: info[:ip],
      user_agent: info[:user_agent],
      channel: operator,
      since: if(operator, do: now),
      held: MapSet.new()
    }

    %{l | sessions: Map.put(l.sessions, id, s)}
  end

  @doc "A session ends; its claims are released."
  @spec leave(t, pos_integer) :: t
  def leave(%__MODULE__{} = l, id) do
    {l, _} = drop_claims(l, id, :all)
    %{l | sessions: Map.delete(l.sessions, id)}
  end

  def channel?(%__MODULE__{sessions: s}, id), do: match?(%{channel: true}, s[id])

  def held(%__MODULE__{sessions: s}, id), do: (s[id] && s[id].held) || MapSet.new()

  @doc """
  Check 2 of the sequencer for a session writing, optionally on one
  application: `:ok` or `{:refused, refusal, data}`.
  """
  def check(%__MODULE__{} = l, id, app_id) do
    cond do
      not channel?(l, id) -> {:refused, :lease_missing, %{}}
      app_id && Map.get(l.holder, app_id, id) != id -> {:refused, :leased, holder(l, app_id)}
      true -> :ok
    end
  end

  @doc "Claims an application the session just created."
  def adopt(%__MODULE__{} = l, id, app_id) do
    case l.sessions[id] do
      %{key_id: nil} -> l
      nil -> l
      s -> put_claims(l, s, [app_id])
    end
  end

  @doc """
  `claim` against `ranked`, every application id in board order (filtered
  to the requested stage when one was named) and `all`, the set of ids that
  exist. `{:ok, lease, %{"ids" => granted}}` (plus `"truncated" => true`)
  or `{:refused, refusal, data}`.
  """
  def claim(%__MODULE__{} = l, id, params, ranked, all, now) do
    case l.sessions[id] do
      nil -> {:refused, :lease_missing, %{}}
      s -> claim_as(l, s, params, ranked, all, now)
    end
  end

  defp claim_as(l, s, params, ranked, all, now) do
    id = s.id
    s = if s.channel, do: s, else: %{s | channel: true, since: now}
    l = %{l | sessions: Map.put(l.sessions, id, s)}

    case params do
      %{"ids" => ids} when is_list(ids) ->
        cond do
          not Enum.all?(ids, &(is_integer(&1) and MapSet.member?(all, &1))) ->
            {:refused, :not_found,
             %{ids: Enum.reject(ids, &(is_integer(&1) and MapSet.member?(all, &1)))}}

          taken = Enum.find(ids, &(Map.get(l.holder, &1, id) != id)) ->
            {:refused, :leased, holder(l, taken)}

          true ->
            {:ok, put_claims(l, s, ids), %{"ids" => Enum.uniq(ids)}}
        end

      %{"count" => n} when is_integer(n) and n >= 0 ->
        free =
          ranked |> Stream.reject(&Map.has_key?(l.holder, &1)) |> Enum.take(min(n, @max_count))

        reply = %{"ids" => free}
        reply = if length(free) < n, do: Map.put(reply, "truncated", true), else: reply
        {:ok, put_claims(l, s, free), reply}

      %{} = p when map_size(p) == 0 or (map_size(p) == 1 and is_map_key(p, "stage")) ->
        {:ok, l, %{"ids" => []}}

      _ ->
        {:refused, :column, %{expected: "{count, stage?} | {ids} | {}"}}
    end
  end

  @doc "Releases `ids`, or everything and the channel for `nil`. Returns `{lease, released_ids}`."
  def free(%__MODULE__{} = l, id, nil) do
    {l, released} = drop_claims(l, id, :all)

    l =
      update_in(
        l.sessions[id],
        &(&1 && %{&1 | channel: &1.key_id == nil, since: if(&1.key_id == nil, do: &1.since)})
      )

    {l, released}
  end

  def free(%__MODULE__{} = l, id, ids) when is_list(ids), do: drop_claims(l, id, ids)

  @doc "The rows of the `leases` wire table: key sessions holding the channel, and any session with claims."
  def rows(%__MODULE__{sessions: sessions}) do
    for {_, s} <- sessions, (s.channel and s.key_id != nil) or MapSet.size(s.held) > 0 do
      %{
        id: s.id,
        label: s.label,
        key_id: s.key_id,
        held: s.held |> Enum.sort() |> Enum.join(<<0x1F>>),
        since: s.since
      }
    end
    |> Enum.sort_by(& &1.id)
  end

  @doc "Applications that no longer exist leave every claim."
  def forget(%__MODULE__{} = l, app_ids) do
    Enum.reduce(app_ids, l, fn app, l ->
      case l.holder[app] do
        nil -> l
        sid -> l |> drop_claims(sid, [app]) |> elem(0)
      end
    end)
  end

  @doc "The account lens's view of every lease (`leases/1`)."
  def list(%__MODULE__{sessions: sessions}) do
    for {_, s} <- sessions, s.channel or MapSet.size(s.held) > 0 do
      %{
        id: s.id,
        label: s.label,
        key_id: s.key_id,
        session_id: s.session_id,
        ids: Enum.sort(s.held),
        since: s.since
      }
    end
    |> Enum.sort_by(& &1.id)
  end

  @doc "The operator's revoke: claims released, channel closed, even a browser's."
  def revoke(%__MODULE__{} = l, id) do
    case l.sessions[id] do
      nil ->
        :error

      _ ->
        {l, released} = drop_claims(l, id, :all)
        {:ok, update_in(l.sessions[id], &%{&1 | channel: false, since: nil}), released}
    end
  end

  defp holder(l, app_id) do
    s = l.sessions[l.holder[app_id]]
    %{id: app_id, holder: s.label, since: s.since && DateTime.to_iso8601(s.since)}
  end

  defp put_claims(l, s, ids) do
    s = %{s | held: MapSet.union(s.held, MapSet.new(ids))}

    %{
      l
      | sessions: Map.put(l.sessions, s.id, s),
        holder: Enum.reduce(ids, l.holder, &Map.put(&2, &1, s.id))
    }
  end

  defp drop_claims(l, id, which) do
    case l.sessions[id] do
      nil ->
        {l, []}

      s ->
        drop = if which == :all, do: s.held, else: MapSet.intersection(s.held, MapSet.new(which))
        s = %{s | held: MapSet.difference(s.held, drop)}
        holder = Map.drop(l.holder, MapSet.to_list(drop))

        {%{l | sessions: Map.put(l.sessions, id, s), holder: holder},
         drop |> MapSet.to_list() |> Enum.sort()}
    end
  end
end
