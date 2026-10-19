defmodule Hireme.GrantsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hireme.{Grants, Schema}

  @domains ~w(world desk mail lanes corpus)
  @outside ~w(trusted_hosts)
  @stored for t <- Schema.tables(), t.residency in [:resident, :server], do: t

  defp key(r, w, d \\ false), do: Grants.key(%{id: 7, read_mask: r, write_mask: w, may_delete: d})

  property "a mask reads and writes exactly the tables of its domains, never system or trusted hosts" do
    check all(r <- integer(0..31), w <- integer(0..31), max_runs: 64) do
      g = key(r, w)

      for t <- @stored do
        bit =
          if t.domain in @domains,
            do: Bitwise.bsl(1, Enum.find_index(@domains, &(&1 == t.domain))),
            else: 0

        bit = if t.name in @outside, do: 0, else: bit
        assert Grants.read?(g, t) == (Bitwise.band(r, bit) != 0), "read #{t.name} with #{r}"
        assert Grants.write?(g, t) == (Bitwise.band(w, bit) != 0), "write #{t.name} with #{w}"
      end
    end
  end

  test "the presets are what their names say" do
    assert Grants.preset(:read_only) == {31, 0}
    assert Grants.preset(:write_only) == {0, 31}
    assert Grants.preset(:read_write) == {31, 31}
    op = Grants.operator()

    assert Enum.all?(
             @stored,
             &(Grants.read?(op, &1) == (&1.domain != "system" and &1.name not in @outside))
           )
  end

  test "a key never sees a server_only or private column; the operator sees private ones" do
    k = key(31, 31)
    op = Grants.operator()

    for t <- Schema.tables() do
      refute Enum.any?(Grants.columns(k, t), &(&1.server_only or &1.private))
      refute Enum.any?(Grants.columns(op, t), & &1.server_only)
    end

    profiles = Schema.table(:profiles)
    assert Enum.any?(Grants.columns(op, profiles), &(&1.name == "narrative_private"))
  end

  test "the grant check: scope by domain, may_delete for a drop, human_only for a key" do
    apps = Schema.table(:applications)
    batches = Schema.table(:batches)
    fire = Schema.column(:batches, "fire")
    open_fire = Schema.command(:open_fire)
    stage = Schema.command(:stage)

    assert {:refused, :scope, _} = Grants.check(key(31, 0), :put, nil, apps, [])
    assert :ok = Grants.check(key(0, 2), :put, nil, apps, [])
    assert {:refused, :scope, _} = Grants.check(key(0, 2), :drop, nil, apps, [])
    assert :ok = Grants.check(key(0, 2, true), :drop, nil, apps, [])
    assert {:refused, :human_only, _} = Grants.check(key(0, 31), :put, nil, batches, [fire])
    assert :ok = Grants.check(Grants.operator(), :put, nil, batches, [fire])
    assert {:refused, :human_only, _} = Grants.check(key(0, 31), :command, open_fire, apps, [])
    assert :ok = Grants.check(Grants.operator(), :command, open_fire, apps, [])
    assert :ok = Grants.check(key(0, 2), :command, stage, apps, [])
    assert {:refused, :scope, _} = Grants.check(key(0, 1), :command, stage, apps, [])
  end
end
