defmodule Hireme.LeaseTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hireme.Lease

  @now ~U[2026-10-18 12:00:00Z]
  @apps Enum.to_list(1..40)
  @all MapSet.new(@apps)

  defp joined(sessions) do
    Enum.reduce(sessions, %Lease{}, fn {id, key}, l ->
      Lease.join(l, %{id: id, label: "s#{id}", key_id: key}, @now)
    end)
  end

  test "a key's session has no channel until it claims; a browser's has one from the start" do
    l = joined([{1, nil}, {2, 9}])
    assert :ok = Lease.check(l, 1, nil)
    assert {:refused, :lease_missing, _} = Lease.check(l, 2, nil)
    {:ok, l, %{"ids" => []}} = Lease.claim(l, 2, %{}, @apps, @all, @now)
    assert :ok = Lease.check(l, 2, nil)
  end

  test "count claims the highest-ranked unclaimed, truncated when fewer exist" do
    l = joined([{1, 8}, {2, 9}])
    {:ok, l, %{"ids" => first}} = Lease.claim(l, 1, %{"count" => 16}, @apps, @all, @now)
    assert first == Enum.take(@apps, 16)
    {:ok, l, reply} = Lease.claim(l, 2, %{"count" => 30}, @apps, @all, @now)
    assert reply == %{"ids" => Enum.drop(@apps, 16), "truncated" => true}
    assert {:refused, :leased, %{id: 3, holder: "s1"}} = Lease.check(l, 2, 3)
  end

  test "ids are granted whole or not at all, naming the holder and since" do
    l = joined([{1, 8}, {2, 9}])
    {:ok, l, _} = Lease.claim(l, 1, %{"ids" => [5]}, @apps, @all, @now)

    assert {:refused, :leased, %{id: 5, holder: "s1", since: since}} =
             Lease.claim(l, 2, %{"ids" => [4, 5]}, @apps, @all, @now)

    assert since == DateTime.to_iso8601(@now)

    assert {:refused, :not_found, %{ids: [99]}} =
             Lease.claim(l, 2, %{"ids" => [4, 99]}, @apps, @all, @now)

    assert MapSet.size(Lease.held(l, 2)) == 0
  end

  test "an application a key's session creates is its claim; leaving releases everything" do
    l = joined([{1, 8}, {2, 9}])
    {:ok, l, _} = Lease.claim(l, 1, %{}, @apps, @all, @now)
    {:ok, l, _} = Lease.claim(l, 2, %{}, @apps, @all, @now)
    l = Lease.adopt(l, 1, 41)
    assert {:refused, :leased, _} = Lease.check(l, 2, 41)
    l = Lease.leave(l, 1)

    {:ok, _, %{"ids" => [41]}} =
      Lease.claim(l, 2, %{"ids" => [41]}, [41 | @apps], MapSet.put(@all, 41), @now)
  end

  test "release with no ids closes a key's channel; the operator's revoke closes anyone's" do
    l = joined([{1, nil}, {2, 9}])
    {:ok, l, _} = Lease.claim(l, 2, %{"count" => 2}, @apps, @all, @now)
    {l2, [1, 2]} = Lease.free(l, 2, nil)
    assert {:refused, :lease_missing, _} = Lease.check(l2, 2, nil)
    {:ok, l3, []} = Lease.revoke(l, 1)
    assert {:refused, :lease_missing, _} = Lease.check(l3, 1, nil)
    assert Lease.revoke(l, 77) == :error
    # Nothing left to revoke: an already revoked session, or a key's that
    # holds nothing. Still sticky: the idle key cannot claim afterwards.
    assert {:unchanged, _} = Lease.revoke(l3, 1)
    assert {:unchanged, l4} = Lease.revoke(l2, 2)
    assert {:refused, _, _} = Lease.claim(l4, 2, %{}, @apps, @all, @now)
  end

  property "no application is ever held by two sessions, and check agrees with who holds it" do
    action =
      one_of([
        tuple({constant(:count), integer(1..4), integer(0..12)}),
        tuple({constant(:ids), integer(1..4), list_of(member_of(@apps), max_length: 5)}),
        tuple(
          {constant(:release), integer(1..4),
           one_of([constant(nil), list_of(member_of(@apps), max_length: 5)])}
        ),
        tuple({constant(:leave), integer(1..4), constant(nil)})
      ])

    check all(actions <- list_of(action, max_length: 40), max_runs: 100) do
      l =
        Enum.reduce(actions, joined([{1, nil}, {2, 7}, {3, 8}, {4, 9}]), fn
          {:count, s, n}, l ->
            ok(Lease.claim(l, s, %{"count" => n}, @apps, @all, @now), l)

          {:ids, s, ids}, l ->
            ok(Lease.claim(l, s, %{"ids" => ids}, @apps, @all, @now), l)

          {:release, s, ids}, l ->
            l |> Lease.free(s, ids) |> elem(0)

          {:leave, s, _}, l ->
            l
            |> Lease.leave(s)
            |> Lease.join(%{id: s, label: "s#{s}", key_id: if(s > 1, do: s)}, @now)
        end)

      held = for s <- 1..4, a <- Lease.held(l, s), do: {a, s}
      assert length(held) == length(Enum.uniq_by(held, &elem(&1, 0)))

      for a <- @apps, s <- 1..4, Lease.channel?(l, s) do
        holder =
          Enum.find_value(held, fn
            {^a, h} -> h
            _ -> nil
          end)

        # Session 1 is the operator's: never refused leased.
        assert Lease.check(l, s, a) == :ok == (s == 1 or holder in [nil, s])
      end
    end
  end

  defp ok({:ok, l, _}, _), do: l
  defp ok({:refused, _, _}, l), do: l
end
