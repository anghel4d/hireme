defmodule Hireme.LeaseTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hireme.Lease

  @now ~U[2026-10-18 12:00:00Z]
  @apps Enum.to_list(1..40)

  defp join(l, id, key), do: Lease.join(l, %{id: id, label: "s#{id}", key_id: key}, @now)

  defp joined(sessions),
    do: Enum.reduce(sessions, %Lease{}, fn {id, key}, l -> join(l, id, key) end)

  defp claim(l, s, params, apps \\ @apps),
    do: Lease.claim(l, s, params, apps, MapSet.new(apps), @now)

  test "a browser's session has the channel from the start, a key's once it claims; count claims the highest-ranked unclaimed, truncated when fewer exist" do
    l = joined([{1, nil}, {2, 8}, {3, 9}])
    assert :ok = Lease.check(l, 1, nil)
    assert {:refused, :lease_missing, _} = Lease.check(l, 2, nil)
    {:ok, l, %{"ids" => first}} = claim(l, 2, %{"count" => 16})
    assert first == Enum.take(@apps, 16)
    assert :ok = Lease.check(l, 2, nil)
    {:ok, l, reply} = claim(l, 3, %{"count" => 30})
    assert reply == %{"ids" => Enum.drop(@apps, 16), "truncated" => true}
    assert {:refused, :leased, %{id: 3, holder: "s2"}} = Lease.check(l, 3, 3)
  end

  test "ids are granted whole or not at all, naming the holder and since" do
    {:ok, l, _} = claim(joined([{1, 8}, {2, 9}]), 1, %{"ids" => [5]})
    since = DateTime.to_iso8601(@now)

    assert {:refused, :leased, %{id: 5, holder: "s1", since: ^since}} =
             claim(l, 2, %{"ids" => [4, 5]})

    assert {:refused, :not_found, %{ids: [99]}} = claim(l, 2, %{"ids" => [4, 99]})
    assert MapSet.size(Lease.held(l, 2)) == 0
  end

  test "an application a key's session creates is its claim; leaving releases everything" do
    {:ok, l, _} = claim(joined([{1, 8}, {2, 9}]), 1, %{})
    {:ok, l, _} = claim(l, 2, %{})
    l = Lease.adopt(l, 1, 41)
    assert {:refused, :leased, _} = Lease.check(l, 2, 41)
    {:ok, _, %{"ids" => [41]}} = claim(Lease.leave(l, 1), 2, %{"ids" => [41]}, [41 | @apps])
  end

  test "release with no ids closes a key's channel; the operator's revoke closes anyone's" do
    {:ok, l, _} = claim(joined([{1, nil}, {2, 9}]), 2, %{"count" => 2})
    {l2, [1, 2]} = Lease.free(l, 2, nil)
    assert {:refused, :lease_missing, _} = Lease.check(l2, 2, nil)
    {:ok, l3, []} = Lease.revoke(l, 1)
    assert {:refused, :lease_missing, _} = Lease.check(l3, 1, nil)
    assert Lease.revoke(l, 77) == :error
    # Nothing left to revoke: an already revoked session, or a key's that
    # holds nothing. A browser session's revoke is sticky for its life.
    assert {:unchanged, _} = Lease.revoke(l3, 1)
    assert {:refused, :lease_missing, %{reason: "the operator revoked" <> _}} = claim(l3, 1, %{})
    # A key's is held by the key instead (the sequencer's hold/3 with the revoke).
    assert {:unchanged, _} = Lease.revoke(l2, 2)
    # A held key's sessions are refused, saying so; lifted, they claim again.
    held = Lease.hold(l2, 9, @now)
    assert {:refused, :lease_missing, %{paused: true, key: 9}} = claim(held, 2, %{})
    assert {:refused, :lease_missing, %{paused: true}} = Lease.check(held, 2, nil)
    assert {:ok, _, _} = claim(Lease.lift(held, 9), 2, %{})
  end

  property "no application is ever held by two sessions, and check agrees with who holds it" do
    ids = list_of(member_of(@apps), max_length: 5)

    action =
      one_of([
        tuple({constant(:count), integer(1..4), integer(0..12)}),
        tuple({constant(:ids), integer(1..4), ids}),
        tuple({constant(:release), integer(1..4), one_of([constant(nil), ids])}),
        tuple({constant(:leave), integer(1..4), constant(nil)})
      ])

    check all(actions <- list_of(action, max_length: 40), max_runs: 100) do
      l =
        Enum.reduce(actions, joined([{1, nil}, {2, 7}, {3, 8}, {4, 9}]), fn
          {:count, s, n}, l -> ok(claim(l, s, %{"count" => n}), l)
          {:ids, s, ids}, l -> ok(claim(l, s, %{"ids" => ids}), l)
          {:release, s, ids}, l -> l |> Lease.free(s, ids) |> elem(0)
          {:leave, s, _}, l -> l |> Lease.leave(s) |> join(s, if(s > 1, do: s))
        end)

      held = Map.new(for s <- 1..4, a <- Lease.held(l, s), do: {a, s})
      assert map_size(held) == Enum.sum(for s <- 1..4, do: MapSet.size(Lease.held(l, s)))

      # Session 1 is the operator's: never refused leased.
      for a <- @apps,
          s <- 1..4,
          Lease.channel?(l, s),
          do: assert(Lease.check(l, s, a) == :ok == (s == 1 or held[a] in [nil, s]))
    end
  end

  defp ok({:ok, l, _}, _), do: l
  defp ok({:refused, _, _}, l), do: l
end
