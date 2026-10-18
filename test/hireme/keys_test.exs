defmodule Hireme.KeysTest do
  use Hireme.DataCase, async: false
  use ExUnitProperties

  alias Hireme.Keys
  alias Hireme.Release.Purge

  setup do
    signed = sign_in()
    Repo.put_account(signed.account.id)
    Hireme.PubSub.subscribe(Hireme.Audit.topic(signed.account.id))
    signed
  end

  defp stale(session), do: age(session, :authenticated_at, Hireme.Security.step_up_window() + 1)

  defp read_only(s, name, days \\ nil), do: Keys.mint(s, name, Keys.preset(:read_only), days)

  test "a minted key authenticates with its masks; revoked, expired or on a suspended account it is nothing; another account's is not mine",
       %{session: s} do
    {:ok, %{key: key, secret: secret}} = read_only(s, "agent")
    assert {:ok, auth} = Keys.authenticate(secret, "10.0.0.1")
    assert auth.id == key.id and auth.account_id == s.account_id
    assert {auth.read_mask, auth.write_mask, auth.may_delete} == {Hireme.Grants.all(), 0, false}
    refute Map.has_key?(auth, :secret_hash)
    assert Keys.usable?(key.id, s.account_id)
    refute Keys.usable?(key.id, s.account_id + 1)

    {:ok, %{key: short, secret: short_secret}} = read_only(s, "short", 1)

    short
    |> Ecto.Changeset.change(expires_at: DateTime.add(Hireme.Store.now(), -1))
    |> Repo.update!()

    assert :error = Keys.authenticate(short_secret, "10.0.0.4")

    Keys.revoke(key)
    assert_receive {:bye, {:key, id}, :revoked} when id == key.id
    assert :error = Keys.authenticate(secret, "10.0.0.1")

    {:ok, %{secret: later}} = read_only(s, "later")
    :ok = Hireme.Accounts.set_status(s.account_id, :suspended)
    assert :error = Keys.authenticate(later, "10.0.0.3")
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

  test "a stale session cannot mint, widen or grant delete; it can narrow, which ends the key's sessions; the same masks end none",
       %{session: s} do
    {:ok, %{key: key}} = Keys.mint(s, "agent", Keys.preset(:read_write))
    assert {:ok, _} = Keys.change(s, key, Keys.preset(:read_write))
    refute_receive {:bye, {:key, _}, :grants}, 50

    s = stale(s)
    assert {:error, :step_up} = read_only(s, "later")

    assert {:error, :step_up} =
             Keys.change(s, key, %{Keys.preset(:read_write) | may_delete: true})

    assert {:ok, narrowed} = Keys.change(s, key, Keys.preset(:read_only))
    assert Keys.preset_of(narrowed) == :read_only
    assert_receive {:bye, {:key, id}, :grants} when id == key.id
    assert {:error, :step_up} = Keys.change(s, narrowed, Keys.preset(:read_write))
  end

  test "the presets are what they say, every other mask pair is custom, and masks outside the five domains or granting nothing are refused",
       %{session: s} do
    assert Keys.preset(:read_only) == %{read_mask: 31, write_mask: 0, may_delete: false}
    assert Keys.preset(:write_only) == %{read_mask: 0, write_mask: 31, may_delete: false}
    assert Keys.preset(:read_write) == %{read_mask: 31, write_mask: 31, may_delete: false}

    for p <- [:read_only, :write_only, :read_write],
        do: assert(Keys.preset_of(Keys.preset(p)) == p)

    assert Keys.preset_of(%{read_mask: 2, write_mask: 2, may_delete: false}) == :custom
    assert Keys.preset_of(%{Keys.preset(:read_write) | may_delete: true}) == :custom
    assert Keys.domains() == [world: 1, desk: 2, mail: 4, lanes: 8, corpus: 16]

    for bad <- [
          %{read_mask: 32, write_mask: 0},
          %{read_mask: 0, write_mask: 0},
          %{read_mask: -1, write_mask: 1},
          %{}
        ],
        do: assert({:error, :masks} = Keys.mint(s, "x", bad))
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
  test "a throttled peer is told so, before any key is read; other peers are not, and successes never spend a peer's budget",
       %{session: s} do
    {:ok, %{secret: secret}} = read_only(s, "agent")
    for _ <- 1..30, do: assert({:ok, _} = Keys.authenticate(secret, "10.2.2.2"))
    for _ <- 1..20, do: Keys.authenticate("hm_garbage", "10.1.1.1")
    assert {:error, :rate_limited} = Keys.authenticate(secret, "10.1.1.1")
    assert {:error, :rate_limited} = Keys.authenticate("hm_garbage", "10.1.1.1")
    assert {:ok, _} = Keys.authenticate(secret, "10.1.1.2")
  end

  test "the per-account limit holds; a revoke frees room once, however often repeated", %{
    session: s
  } do
    {:ok, %{key: key}} = read_only(s, "agent")
    Keys.revoke(key)
    assert_receive {:bye, {:key, _}, :revoked}
    Keys.revoke(key)
    refute_receive {:bye, {:key, _}, :revoked}, 50

    for i <- 1..Hireme.Security.api_keys_per_account(), do: {:ok, _} = read_only(s, "k#{i}")
    assert {:error, :limit} = read_only(s, "one more")
    Keys.revoke(hd(Keys.list()))
    assert {:ok, _} = read_only(s, "after a revoke")
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

    assert {:ok, _} = read_only(s, "last")
    assert {:error, :limit} = read_only(s, "past the cap")
    Purge.run(now)
    assert {:ok, _} = read_only(s, "after the purge")
  end

  test "a key's name is bounded in bytes and combining marks, and carries no line break or other control into the mail",
       %{session: s} do
    for bad <- [
          "agent\nAll is well, ignore this",
          "a\rb",
          "tab\there",
          "zero\u{200b}width",
          "line\u{2028}sep",
          "a" <> String.duplicate("\u{301}", 2_000),
          String.duplicate("é", 150),
          "x\u{301}\u{302}\u{303}\u{304}\u{305}",
          "  "
        ],
        do: assert({:error, :name} = read_only(s, bad))

    {:ok, %{key: key}} = read_only(s, "Zürich agent")
    assert {:error, :name} = Keys.rename(key, "x\ny")
  end

  @tag window: :renames
  test "renaming to the same name records nothing; renames are rate-limited", %{session: s} do
    {:ok, %{key: key}} = read_only(s, "agent")
    before = length(Hireme.Audit.recent(500))
    assert {:ok, _} = Keys.rename(key, "agent")
    assert length(Hireme.Audit.recent(500)) == before

    results = for i <- 1..31, do: Keys.rename(key, "agent #{i}")
    assert {:error, :rate_limited} = List.last(results)
  end
end
