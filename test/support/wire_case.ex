defmodule Hireme.WireCase do
  @moduledoc """
  Tests of the write path: a signed-in account holding a world corporation
  (every application links one, and `app/2` links this one), and ops built
  the way a client builds them (named, typed cells).
  """

  use ExUnit.CaseTemplate
  import Ecto.Query
  alias Hireme.Kernel.Nif
  alias Hireme.Schema
  alias HiremeWeb.Wire.Codec

  using do
    quote do
      import Hireme.WireCase
      import Hireme.DataCase, only: [sign_in: 0, sign_in: 1]
      alias Hireme.{Grants, Repo, Schema, Sequencer}
      alias HiremeWeb.Wire.Codec
    end
  end

  setup tags do
    Hireme.DataCase.setup_sandbox(tags)
    signed = Hireme.DataCase.sign_in()
    a = signed.account.id
    Hireme.Repo.put_account(a)
    # As the database holds one before the sequencer starts, its text
    # counted in the account's as the sequencer counts it.
    now = Hireme.Store.now()
    corp = %Hireme.Rows.Corporation{account_id: a, domain: "test-corp.example", name: "Test Corp"}

    corp =
      Hireme.Repo.insert!(%{corp | rev: 1, inserted_at: now, updated_at: now}, skip_account: true)

    bytes = byte_size(corp.domain <> corp.name)
    where = from(x in Hireme.Rows.Account, where: x.id == ^a)
    Hireme.Repo.update_all(where, [inc: [text_bytes: bytes]], skip_account: true)
    Process.put({__MODULE__, :corp}, corp.id)
    {:ok, Map.put(signed, :corp, corp.id)}
  end

  @doc "A new application, linked to the test account's corporation and remote, so it needs no place; `cells` add to or override that."
  def app(cells \\ %{}, opts \\ []) do
    linked = %{corporation_id: Process.get({__MODULE__, :corp}), work_mode: :remote}
    op(:put, :applications, Map.merge(linked, Map.new(cells)), opts)
  end

  @doc """
  One decoded op. `cells` maps column (or param) names to Elixir values;
  `:as_of` (a Date) and `:source` (a URL or source id) ride the reserved cells.
  """
  def op(verb, subject, cells \\ %{}, opts \\ []) do
    owner = if verb == :command, do: Schema.command(subject), else: Schema.table(subject)
    cols = Map.new(owner[:params] || owner.cols, &{&1.name, &1})

    encoded =
      Enum.map(cells, fn
        {:as_of, %Date{} = d} -> {Codec.as_of_col(), 1, Codec.day_to_wire(d)}
        {:source, s} when is_integer(s) -> {Codec.source_col(), 1, s}
        {:source, s} -> {Codec.source_col(), 2, s}
        {name, nil} -> {Map.fetch!(cols, to_string(name)).id, 0, nil}
        {name, v} -> cell(Map.fetch!(cols, to_string(name)), v)
      end)

    flags = if(opts[:keyed], do: 1, else: 0) + if(opts[:create_only], do: 2, else: 0)
    op_id = opts[:op_id] || System.unique_integer([:positive])
    op = {op_id, verb, flags, owner.id, opts[:target] || 0, opts[:expect_rev], encoded}
    {:ok, op, ""} = Codec.op(Codec.encode_op(op))
    op
  end

  defp cell(col, v) do
    ty = Codec.cell_type(col)
    v = Codec.to_wire(col, v)
    {col.id, ty, if(ty == 4, do: v * 1.0, else: v)}
  end

  @doc "Runs ops as the operator (or `actor`): `{acks, nacks}`, NACK codes as refusal atoms."
  def run(account_id, ops, actor \\ nil) do
    {:ok, _rev, acks, nacks} =
      Hireme.Sequencer.call(account_id, actor || operator(), List.wrap(ops))

    {acks, refusals(nacks)}
  end

  @doc "Runs one op that must land: its ACK."
  def ack!(account_id, op, actor \\ nil) do
    {[ack], []} = run(account_id, op, actor)
    ack
  end

  @doc "Runs one op that must be refused: its refusal atom."
  def nack!(account_id, op, actor \\ nil) do
    {[], [nack]} = run(account_id, op, actor)
    nack.refusal
  end

  defp refusals(nacks), do: Enum.map(nacks, &Map.put(&1, :refusal, Schema.refusal_name(&1.code)))

  defp operator, do: %{label: "test", grants: Hireme.Grants.operator(), key_id: nil}

  @doc "The account's committed rev, through a batch of no ops (which also starts the sequencer, or waits for it)."
  def rev(account_id), do: elem(Hireme.Sequencer.call(account_id, operator(), []), 1)

  @doc """
  Stops the account's sequencer between messages (a stop mid-query costs the
  sandbox its connection); the next call starts a fresh one that reads the
  database again.
  """
  def stop_sequencer(account_id) do
    for {pid, _} <- Registry.lookup(Hireme.Sequencer.Registry, account_id) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end

    # The registry forgets the pid after its exit; a start before that fails.
    true = eventually(fn -> not Hireme.Sequencer.running?(account_id) end)
    :ok
  end

  @doc "Polls `f` every 50 ms, up to `tries` times; true once it answers truthy."
  def eventually(f, tries \\ 100) do
    cond do
      f.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(f, tries - 1)
    end
  end

  @doc """
  A key's wire session in its own process, holding the lease (and `claims`):
  `key_session_ops(agent, ops)` submits through it and answers `{acks, nacks}`.
  """
  def key_session(account_id, key, sid, claims \\ %{}) do
    me = self()
    info = %{id: sid, label: "agent#{sid}", grants: Hireme.Grants.key(key), key_id: key.id}

    pid =
      spawn_link(fn ->
        {:ok, _} = Hireme.Sequencer.subscribe(account_id, Map.put(info, :session_id, nil), 0)
        {:ok, reply} = Hireme.Lease.claim(account_id, sid, claims)
        send(me, {:agent_ready, self(), reply})
        agent_loop(account_id)
      end)

    receive do
      {:agent_ready, ^pid, reply} -> {pid, reply}
    end
  end

  defp agent_loop(account_id) do
    receive do
      {:ops, from, ops} ->
        Hireme.Sequencer.submit(account_id, ops)

        receive do
          {:sequencer, :verdicts, _, acks, nacks} ->
            send(from, {:verdicts, self(), {acks, refusals(nacks)}})
        end

        agent_loop(account_id)

      _ ->
        agent_loop(account_id)
    end
  end

  def key_session_ops(agent, ops) do
    send(agent, {:ops, self(), List.wrap(ops)})

    receive do
      {:verdicts, ^agent, v} -> v
    after
      3_000 -> raise "no verdicts from the agent"
    end
  end

  @doc "The table names and row counts of a table-run body (BOOT, PATCH)."
  def tables(body), do: for({t, rows} <- blocks(body), do: {t, length(rows)})

  @doc """
  A client's model of the resident tables: `%{table_name => %{id => %{col_id
  => value}}}`. A BOOT replaces the tables it names; a PATCH merges rows by
  id, and a gone block (its one column 0xFFFE) deletes. Wire tables are left out.
  """
  def ingest(model, kind, body) do
    Enum.reduce(blocks(body), model, fn {table, rows}, model ->
      case {kind, table, rows} do
        {_, t, _} when t in ~w(clock catalog leases) ->
          model

        {_, t, [%{0xFFFE => _} | _]} ->
          Map.update(model, t, %{}, &Map.drop(&1, Enum.map(rows, fn r -> r[0xFFFE] end)))

        {:BOOT, t, _} ->
          Map.put(model, t, Map.new(rows, &{&1[1], &1}))

        {:PATCH, t, _} ->
          Map.update(model, t, Map.new(rows, &{&1[1], &1}), fn old ->
            Enum.reduce(rows, old, fn r, acc -> Map.update(acc, r[1], r, &Map.merge(&1, r)) end)
          end)
      end
    end)
  end

  defp blocks(<<>>), do: []

  defp blocks(<<table::little-16, ncols::little-16, nrows::little-32, rest::binary>>) do
    {cols, rest} =
      Enum.map_reduce(1..ncols//1, rest, fn _,
                                            <<id::little-16, ty, 0, len::little-32, r::binary>> ->
        <<data::binary-size(^len), r::binary>> = r
        pad = rem(8 - rem(len, 8), 8)
        {{id, values(ty, nrows, data)}, binary_part(r, pad, byte_size(r) - pad)}
      end)

    rows = for i <- 0..(nrows - 1)//1, do: Map.new(cols, fn {id, vs} -> {id, Enum.at(vs, i)} end)
    [{Schema.table(table).name, rows} | blocks(rest)]
  end

  defp values(1, _n, data),
    do: for(<<v::little-32 <- data>>, do: if(v == 0xFFFFFFFF, do: nil, else: v))

  defp values(3, _n, data),
    do: for(<<v::little-signed-64 <- data>>, do: if(v == -0x8000000000000000, do: nil, else: v))

  defp values(4, _n, data), do: for(<<v::binary-8 <- data>>, do: float(v))

  defp values(2, n, data) do
    size = (n + 1) * 4
    <<offsets::binary-size(^size), bytes::binary>> = data
    offs = for <<o::little-32 <- offsets>>, do: o

    for [a, b] <- Enum.chunk_every(offs, 2, 1, :discard),
        do: if(a == b, do: nil, else: binary_part(bytes, a, b - a))
  end

  defp values(5, n, data) do
    # native/wire reads a packed cell, as every client does.
    for cell <- values(2, n, data), do: cell && Nif.text(cell)
  end

  defp float(<<v::little-float-64>>), do: v
  defp float(_nan), do: nil
end
