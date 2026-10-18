defmodule Hireme.KernelTest do
  @moduledoc """
  The NIF's contract (native/nif): it judges under exactly the ctx the
  sequencer builds and refuses anything else as badarg, so a missing or
  impossible day is never judged as day 0 and persisted as a date.
  """

  use ExUnit.Case, async: true

  alias Hireme.{Kernel, Schema}
  alias HiremeWeb.Wire.Codec

  setup do
    apps = Schema.table(:applications)
    col = &Schema.column(:applications, &1).id

    boot =
      IO.iodata_to_binary(
        Codec.block(apps.id, 2, [
          {1, 1, [1, 2]},
          {col.("no"), 1, [1, 2]},
          {col.("stage"), 1, [2, 8]},
          {col.("company"), 2, ["Acme", "Zed"]},
          {col.("role"), 2, ["Engineer", "Engineer"]}
        ])
      )

    op = Hireme.WireCase.op(:command, :stage, %{stage: :closed}, target: 1).raw

    # As Hireme.Sequencer's domain check builds it.
    ctx = %{
      actor: :key,
      key_id: 7,
      now_day: 20_000,
      now_s: 20_000 * 86_400,
      session_label: "agent",
      held_ids: [1, 2],
      target: 1
    }

    {:ok, k: Kernel.new(boot), op: op, ctx: ctx}
  end

  defp judged(k, op, ctx), do: elem(Kernel.judge(k, op, ctx), 0)

  test "the sequencer's ctx judges, as the agent for a key and as the operator for a human",
       %{k: k, op: op, ctx: ctx} do
    events = Schema.table(:events).id
    actor = Schema.column(:events, "actor").id

    actor_of = fn c ->
      {:ok, effects} = judged(k, op, c)
      for {^events, 0, cells} <- effects, {^actor, v} <- cells, do: v
    end

    assert actor_of.(ctx) == [Codec.enum_code("actor", :agent)]
    assert actor_of.(%{ctx | actor: :human, key_id: nil}) == [Codec.enum_code("actor", :operator)]
    # The last day a date holds, 9999-12-31.
    assert {:ok, _} = judged(k, op, %{ctx | now_day: 2_932_896})
  end

  test "any other ctx is badarg", %{k: k, op: op, ctx: ctx} do
    bad =
      Enum.map(~w(actor key_id now_day now_s held_ids)a, &Map.delete(ctx, &1)) ++
        [
          %{ctx | actor: :agent},
          %{ctx | now_day: -1},
          %{ctx | now_day: 2_932_897},
          %{ctx | now_day: nil},
          %{ctx | key_id: -1},
          %{ctx | held_ids: [1, :a]},
          Map.to_list(ctx)
        ]

    for c <- bad, do: assert_raise(ArgumentError, fn -> judged(k, op, c) end)
  end

  test "board_ids of a code that is no stage is empty", %{k: k} do
    assert Kernel.board_ids(k, nil) |> Enum.sort() == [1, 2]
    assert Kernel.board_ids(k, 2) == [1]
    assert Kernel.board_ids(k, 10) == []
    assert Kernel.board_ids(k, 258) == []
  end
end
