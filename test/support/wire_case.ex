defmodule Hireme.WireCase do
  @moduledoc """
  Tests of the write path: a signed-in account, ops built the way a client
  builds them (named, typed cells), and the account's sequencer stopped at
  the end so the next test's account (ids repeat across sandboxes) starts
  clean.
  """

  use ExUnit.CaseTemplate
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
    Hireme.Repo.put_account(signed.account.id)

    on_exit(fn ->
      case Registry.lookup(Hireme.Sequencer.Registry, signed.account.id) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Hireme.Sequencer.Dynamic, pid)
        [] -> :ok
      end
    end)

    {:ok, signed}
  end

  @doc """
  One decoded op. `cells` maps column (or param) names to Elixir values;
  `:as_of` (a Date) and `:source` (a URL or source id) ride the reserved cells.
  """
  def op(verb, subject, cells \\ %{}, opts \\ []) do
    {owner, cols} = owner(verb, subject)

    encoded =
      Enum.map(cells, fn
        {:as_of, %Date{} = d} -> {Codec.as_of_col(), 1, Date.diff(d, ~D[1970-01-01])}
        {:source, s} when is_integer(s) -> {Codec.source_col(), 1, s}
        {:source, s} -> {Codec.source_col(), 2, s}
        {name, nil} -> {Map.fetch!(cols, to_string(name)).id, 0, nil}
        {name, v} -> cell(Map.fetch!(cols, to_string(name)), v)
      end)

    flags = if(opts[:keyed], do: 1, else: 0) + if(opts[:create_only], do: 2, else: 0)
    op_id = opts[:op_id] || System.unique_integer([:positive])

    raw =
      Codec.encode_op({op_id, verb, flags, owner, opts[:target] || 0, opts[:expect_rev], encoded})

    {:ok, op, ""} = Codec.op(raw)
    op
  end

  defp owner(:command, name) do
    c = Schema.command(name)
    {c.id, Map.new(c.params, &{&1.name, &1})}
  end

  defp owner(_verb, table) do
    t = Schema.table(table)
    {t.id, Map.new(t.cols, &{&1.name, &1})}
  end

  defp cell(col, v) do
    ty = Codec.cell_type(col)
    v = if Map.get(col, :deferred), do: v, else: Codec.to_wire(col, v)
    v = if ty == 4, do: v * 1.0, else: v
    {col.id, ty, v}
  end

  @doc "Runs ops as the operator (or `actor`): `{acks, nacks}`, NACK codes as refusal atoms."
  def run(account_id, ops, actor \\ nil) do
    actor = actor || %{label: "test", grants: Hireme.Grants.operator(), key_id: nil}
    {:ok, _rev, acks, nacks} = Hireme.Sequencer.call(account_id, actor, List.wrap(ops))
    {acks, Enum.map(nacks, &Map.put(&1, :refusal, Schema.refusal_name(&1.code)))}
  end

  @doc "The table ids and row counts of a table-run body (BOOT, PATCH)."
  def tables(<<>>), do: []

  def tables(<<table::little-16, ncols::little-16, nrows::little-32, rest::binary>>) do
    rest =
      Enum.reduce(1..ncols//1, rest, fn _, <<_::32, len::little-32, r::binary>> ->
        skip(r, len + rem(8 - rem(len, 8), 8))
      end)

    [{Schema.table(table).name, nrows} | tables(rest)]
  end

  defp skip(bin, n), do: binary_part(bin, n, byte_size(bin) - n)

  @doc """
  A client's model of the resident tables: `%{table_name => %{id => %{col_id
  => value}}}`. A BOOT replaces the tables it names; a PATCH merges rows by
  id and the `gone` table deletes. Wire tables are left out.
  """
  def ingest(model, kind, body) do
    Enum.reduce(blocks(body), model, fn {table, rows}, model ->
      case {kind, table} do
        {_, t} when t in ~w(clock catalog leases) ->
          model

        {_, "gone"} ->
          Enum.reduce(rows, model, fn r, m ->
            name = Schema.table(r[col_id("gone", "table")]).name
            Map.update(m, name, %{}, &Map.delete(&1, r[col_id("gone", "id")]))
          end)

        {:BOOT, t} ->
          Map.put(model, t, Map.new(rows, &{&1[1], &1}))

        {:PATCH, t} ->
          Map.update(model, t, Map.new(rows, &{&1[1], &1}), fn old ->
            Enum.reduce(rows, old, fn r, acc -> Map.update(acc, r[1], r, &Map.merge(&1, r)) end)
          end)
      end
    end)
  end

  defp col_id(table, name), do: Schema.column(table, name).id

  defp blocks(<<>>), do: []

  defp blocks(<<table::little-16, ncols::little-16, nrows::little-32, rest::binary>>) do
    {cols, rest} =
      Enum.map_reduce(1..ncols//1, rest, fn _,
                                            <<id::little-16, ty, 0, len::little-32, r::binary>> ->
        <<data::binary-size(^len), r::binary>> = r
        {{id, values(ty, nrows, data)}, skip(r, rem(8 - rem(len, 8), 8))}
      end)

    rows = for i <- 0..(nrows - 1)//1, do: Map.new(cols, fn {id, vs} -> {id, Enum.at(vs, i)} end)
    [{Schema.table(table).name, rows} | blocks(rest)]
  end

  defp values(1, _n, data),
    do: for(<<v::little-32 <- data>>, do: if(v == 0xFFFFFFFF, do: nil, else: v))

  defp values(3, _n, data),
    do: for(<<v::little-signed-64 <- data>>, do: if(v == -0x8000000000000000, do: nil, else: v))

  defp values(4, _n, data), do: for(<<v::binary-8 <- data>>, do: float(v))

  defp values(5, _n, data),
    do:
      for(<<len::little-32, sha::binary-8 <- data>>,
        do: if(len == 0xFFFFFFFF, do: nil, else: {len, sha})
      )

  defp values(2, n, data) do
    size = (n + 1) * 4
    <<offsets::binary-size(^size), bytes::binary>> = data
    offs = for <<o::little-32 <- offsets>>, do: o

    for [a, b] <- Enum.chunk_every(offs, 2, 1, :discard),
        do: if(a == b, do: nil, else: binary_part(bytes, a, b - a))
  end

  defp float(<<v::little-float-64>>), do: v
  defp float(_nan), do: nil
end
