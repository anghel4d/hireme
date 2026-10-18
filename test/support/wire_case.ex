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
    raw = Codec.encode_op({op_id, verb, flags, owner, opts[:target] || 0, opts[:expect_rev], encoded})
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
    rest = Enum.reduce(1..ncols//1, rest, fn _, <<_::32, len::little-32, r::binary>> -> skip(r, len + rem(8 - rem(len, 8), 8)) end)
    [{Schema.table(table).name, nrows} | tables(rest)]
  end

  defp skip(bin, n), do: binary_part(bin, n, byte_size(bin) - n)
end
