defmodule Hireme.KeysTest do
  use Hireme.DataCase, async: false
  use ExUnitProperties

  alias Hireme.Keys
  alias Hireme.Release.Purge

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

  test "asking for the masks a key already has ends none of its sessions", %{session: s} do
    {:ok, %{key: key}} = Keys.mint(s, "agent", Keys.preset(:read_write))
    assert {:ok, _} = Keys.change(s, key, Keys.preset(:read_write))
    refute_receive {:bye, {:key, _}, :grants}, 50
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

  property "widening is exactly granting some domain or delete that was not held" do
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
      has? = fn mask, bit -> rem(div(mask, bit), 2) == 1 end

      gained =
        for {_domain, bit} <- Keys.domains(),
            {a, b} <- [{r1, r2}, {w1, w2}],
            has?.(b, bit) and not has?.(a, bit),
            do: bit

      assert Keys.widens?(old, new) == (gained != [] or (d2 and not d1))
    end
  end

  @tag window: :api_key_peer
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

  test "a key's name carries no line break or other control into the mail", %{session: s} do
    for bad <- [
          "agent\nAll is well, ignore this",
          "a\rb",
          "tab\there",
          "zero\u{200b}width",
          "line\u{2028}sep"
        ],
        do: assert({:error, :name} = Keys.mint(s, bad, Keys.preset(:read_only)))

    {:ok, %{key: key}} = Keys.mint(s, "agent", Keys.preset(:read_only))
    assert {:error, :name} = Keys.rename(key, "x\ny")
  end

  test "revoked keys count toward the key table's cap until the purge removes them", %{session: s} do
    cap = Hireme.Schema.table(:api_keys).cap
    now = Hireme.Store.now()
    old = DateTime.add(now, -31 * 86_400)

    rows =
      for i <- 1..(cap - 1),
          do: %{
            account_id: s.account_id,
            key_id: "k#{String.pad_leading("#{i}", 11, "0")}",
            name: "old #{i}",
            secret_hash: :crypto.hash(:sha256, "#{i}"),
            prefix: "abcd",
            read_mask: 31,
            write_mask: 0,
            may_delete: false,
            revoked_at: old,
            rev: 1,
            inserted_at: old,
            updated_at: old
          }

    for chunk <- Enum.chunk_every(rows, 500),
        do: Repo.insert_all(Hireme.Rows.ApiKey, chunk, skip_account: true)

    assert {:ok, _} = Keys.mint(s, "last", Keys.preset(:read_only))
    assert {:error, :limit} = Keys.mint(s, "past the cap", Keys.preset(:read_only))
    Purge.run(now)
    assert {:ok, _} = Keys.mint(s, "after the purge", Keys.preset(:read_only))
  end

  @tag window: :renames
  test "renaming to the same name records nothing; renames are rate-limited", %{session: s} do
    {:ok, %{key: key}} = Keys.mint(s, "agent", Keys.preset(:read_only))
    before = length(Hireme.Audit.recent(500))
    assert {:ok, _} = Keys.rename(key, "agent")
    assert length(Hireme.Audit.recent(500)) == before

    results = for i <- 1..31, do: Keys.rename(key, "agent #{i}")
    assert {:error, :rate_limited} = List.last(results)
  end

  test "a name is bounded in bytes and in combining marks, not only characters", %{session: s} do
    for bad <- [
          "a" <> String.duplicate("\u{301}", 2_000),
          String.duplicate("é", 150),
          "x\u{301}\u{302}\u{303}\u{304}\u{305}"
        ],
        do: assert({:error, :name} = Keys.mint(s, bad, Keys.preset(:read_only)))

    assert {:ok, _} = Keys.mint(s, "Zürich agent", Keys.preset(:read_only))
  end
end
