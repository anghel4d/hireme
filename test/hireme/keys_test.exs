defmodule Hireme.KeysTest do
  use Hireme.DataCase, async: false
  use ExUnitProperties

  alias Hireme.Keys

  setup do
    signed = sign_in()
    Repo.put_account(signed.account.id)
    Phoenix.PubSub.subscribe(Hireme.PubSub, Hireme.Audit.topic(signed.account.id))
    signed
  end

  defp stale(session), do: age(session, :authenticated_at, Hireme.Security.step_up_window() + 1)

  test "a minted key authenticates with its masks, once revoked it is nothing", %{session: s} do
    {:ok, %{key: key, secret: secret}} = Keys.mint(s, "agent", Keys.preset(:read_only))
    assert {:ok, auth} = Keys.authenticate(secret, "10.0.0.1")
    assert auth.id == key.id and auth.account_id == s.account_id
    assert {auth.read_mask, auth.write_mask, auth.may_delete} == {Keys.all(), 0, false}
    refute Map.has_key?(auth, :secret_hash)

    Keys.revoke(key)
    assert_receive {:bye, {:key, id}, :revoked} when id == key.id
    assert :error = Keys.authenticate(secret, "10.0.0.1")
  end

  property "any altered character of a key fails, the same way as a wrong key", %{session: s} do
    {:ok, %{secret: secret}} = Keys.mint(s, "agent", Keys.preset(:read_write))

    check all(
            at <- integer(0..(byte_size(secret) - 1)),
            char <-
              member_of(
                String.graphemes(
                  "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_"
                )
              ),
            max_runs: 60
          ) do
      :ets.delete_all_objects(Hireme.RateLimit)

      altered =
        binary_part(secret, 0, at) <>
          char <> binary_part(secret, at + 1, byte_size(secret) - at - 1)

      if altered != secret, do: assert(:error = Keys.authenticate(altered, "10.0.0.2"))
    end
  end

  test "a stale session cannot mint, widen or grant delete; it can narrow", %{session: s} do
    {:ok, %{key: key}} = Keys.mint(s, "agent", Keys.preset(:read_write))
    s = stale(s)

    assert {:error, :step_up} = Keys.mint(s, "later", Keys.preset(:read_only))

    assert {:error, :step_up} =
             Keys.change(s, key, %{Keys.preset(:read_write) | may_delete: true})

    assert {:ok, narrowed} = Keys.change(s, key, Keys.preset(:read_only))
    assert Keys.preset_of(narrowed) == :read_only
    assert_receive {:bye, {:key, id}, :grants} when id == key.id

    assert {:error, :step_up} = Keys.change(s, narrowed, Keys.preset(:read_write))
  end

  test "masks outside the five domains, or granting nothing, are refused", %{session: s} do
    for bad <- [
          %{read_mask: 32, write_mask: 0},
          %{read_mask: 0, write_mask: 0},
          %{read_mask: -1, write_mask: 1},
          %{}
        ],
        do: assert({:error, :masks} = Keys.mint(s, "x", bad))

    assert {:error, :name} = Keys.mint(s, "  ", Keys.preset(:read_only))
  end

  test "the presets are what they say, and every other mask pair is custom" do
    assert Keys.preset(:read_only) == %{read_mask: 31, write_mask: 0, may_delete: false}
    assert Keys.preset(:write_only) == %{read_mask: 0, write_mask: 31, may_delete: false}
    assert Keys.preset(:read_write) == %{read_mask: 31, write_mask: 31, may_delete: false}

    for p <- [:read_only, :write_only, :read_write],
        do: assert(Keys.preset_of(Keys.preset(p)) == p)

    assert Keys.preset_of(%{read_mask: 2, write_mask: 2, may_delete: false}) == :custom
    assert Keys.preset_of(%{Keys.preset(:read_write) | may_delete: true}) == :custom
    assert Keys.domains() == [world: 1, desk: 2, mail: 4, lanes: 8, corpus: 16]
  end

  property "widening is exactly granting a bit or delete that was not held" do
    check all(
            r1 <- integer(0..31),
            w1 <- integer(0..31),
            d1 <- boolean(),
            r2 <- integer(0..31),
            w2 <- integer(0..31),
            d2 <- boolean()
          ) do
      old = %{read_mask: r1, write_mask: w1, may_delete: d1}
      new = %{read_mask: r2, write_mask: w2, may_delete: d2}

      grants? =
        Bitwise.band(r2, Bitwise.bnot(r1)) > 0 or Bitwise.band(w2, Bitwise.bnot(w1)) > 0 or
          (d2 and not d1)

      assert Keys.widens?(old, new) == grants?
    end
  end

  test "a throttled peer is told so, before any key is read; other peers are not", %{session: s} do
    {:ok, %{secret: secret}} = Keys.mint(s, "agent", Keys.preset(:read_only))
    for _ <- 1..20, do: Keys.authenticate("hm_garbage", "10.1.1.1")
    assert {:error, :rate_limited} = Keys.authenticate(secret, "10.1.1.1")
    assert {:error, :rate_limited} = Keys.authenticate("hm_garbage", "10.1.1.1")
    assert {:ok, _} = Keys.authenticate(secret, "10.1.1.2")
  end

  test "a key on a suspended account does not authenticate", %{session: s} do
    {:ok, %{secret: secret}} = Keys.mint(s, "agent", Keys.preset(:read_only))
    :ok = Hireme.Accounts.set_status(s.account_id, :suspended)
    assert :error = Keys.authenticate(secret, "10.0.0.3")
  end

  test "an expired key does not authenticate", %{session: s} do
    {:ok, %{key: key, secret: secret}} = Keys.mint(s, "agent", Keys.preset(:read_only), 1)

    key
    |> Ecto.Changeset.change(expires_at: DateTime.add(Hireme.Store.now(), -1))
    |> Repo.update!()

    assert :error = Keys.authenticate(secret, "10.0.0.4")
  end

  test "the per-account cap holds", %{session: s} do
    for i <- 1..Hireme.Security.api_keys_per_account(),
        do: {:ok, _} = Keys.mint(s, "k#{i}", Keys.preset(:read_only))

    assert {:error, :limit} = Keys.mint(s, "one more", Keys.preset(:read_only))
    Keys.revoke(hd(Keys.list()))
    assert {:ok, _} = Keys.mint(s, "after a revoke", Keys.preset(:read_only))
  end

  test "another account's key is not usable as mine", %{session: s} do
    {:ok, %{key: key}} = Keys.mint(s, "agent", Keys.preset(:read_only))
    assert Keys.usable?(key.id, s.account_id)
    refute Keys.usable?(key.id, s.account_id + 1)
  end

  test "a second revoke, even from a stale struct, frees no extra room under the cap", %{
    session: s
  } do
    {:ok, %{key: key}} = Keys.mint(s, "agent", Keys.preset(:read_only))
    Keys.revoke(key)
    assert_receive {:bye, {:key, _}, :revoked}
    Keys.revoke(key)
    refute_receive {:bye, {:key, _}, :revoked}, 50

    for i <- 1..Hireme.Security.api_keys_per_account(),
        do: {:ok, _} = Keys.mint(s, "k#{i}", Keys.preset(:read_only))

    assert {:error, :limit} = Keys.mint(s, "one more", Keys.preset(:read_only))
  end

  test "successful authentications never spend a peer's budget", %{session: s} do
    {:ok, %{secret: secret}} = Keys.mint(s, "agent", Keys.preset(:read_only))
    for _ <- 1..30, do: assert({:ok, _} = Keys.authenticate(secret, "10.2.2.2"))
  end
end
