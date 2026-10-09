defmodule Hireme.ApiKeysTest do
  use Hireme.DataCase, async: false

  alias Hireme.Accounts
  alias Hireme.ApiKeys
  alias Hireme.Repo

  @shape ~r/\Ahm_[0-9A-Za-z]{12}_[0-9A-Za-z]{49}\z/

  test "a key is shown once, authenticates, and reads back as its prefix" do
    assert {:ok, %{key: key, secret: secret}} = ApiKeys.create("agent on the mac")
    assert secret =~ @shape
    assert "key_" <> key.key_id == "key_" <> String.slice(secret, 3, 12)
    assert ApiKeys.display(key) == "hm_" <> String.slice(secret, 16, 4) <> "…"
    refute Map.has_key?(key, :secret)

    assert {:ok, found} = ApiKeys.authenticate(secret, "10.0.0.1")
    assert found.id == key.id
    assert [%{id: id}] = ApiKeys.list()
    assert id == key.id

    Repo.with_account(nil, fn ->
      assert {:ok, %{id: ^id}} = ApiKeys.authenticate(secret, "no-account")
      assert Repo.account_id() == nil
    end)
  end

  test "anything but the exact live secret of an active account is refused alike" do
    {:ok, %{key: key, secret: secret}} = ApiKeys.create("probe")

    tampered = String.slice(secret, 0, byte_size(secret) - 1) <> "0"
    assert :error = ApiKeys.authenticate(tampered, "a")
    assert :error = ApiKeys.authenticate(String.replace(secret, "_", "-"), "a")
    assert :error = ApiKeys.authenticate("hm_" <> String.duplicate("x", 62), "a")
    assert :error = ApiKeys.authenticate(nil, "a")
    assert :error = ApiKeys.authenticate("", "a")

    # A valid checksum does not make a different secret authentic.
    first = if String.at(secret, 16) == "0", do: "1", else: "0"
    body = String.slice(secret, 0, 16) <> first <> String.slice(secret, 17, 42)
    assert :error = ApiKeys.authenticate(body <> Hireme.Security.checksum(body), "a")

    revoked = ApiKeys.revoke(key)
    refute ApiKeys.live?(revoked)
    assert :error = ApiKeys.authenticate(secret, "a")

    {:ok, %{key: expiring, secret: secret2}} = ApiKeys.create("short", 30)
    assert DateTime.diff(expiring.expires_at, DateTime.utc_now(), :day) in 29..30

    expiring
    |> Ecto.Changeset.change(
      expires_at: DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    assert :error = ApiKeys.authenticate(secret2, "a")

    {:ok, %{secret: secret3}} = ApiKeys.create("suspended")

    Accounts.get(Repo.account_id!())
    |> Ecto.Changeset.change(status: :suspended)
    |> Repo.update!(skip_account: true)

    assert :error = ApiKeys.authenticate(secret3, "a")
  end

  test "a key belongs to its account alone" do
    {:ok, %{key: key, secret: secret}} = ApiKeys.create("mine")
    other = Hireme.DataCase.open_account("Other desk")
    assert ApiKeys.list() == []
    assert ApiKeys.get(key.id) == nil
    assert {:ok, found} = ApiKeys.authenticate(secret, "a")
    refute found.account_id == other.id
  end

  test "a key stays usable only while it, its account and its clock allow", %{account: account} do
    {:ok, %{key: key}} = ApiKeys.create("socket")
    other = Hireme.DataCase.open_account("Other desk")
    assert ApiKeys.usable?(key.key_id, account.id)
    refute ApiKeys.usable?(key.key_id, other.id)
    refute ApiKeys.usable?("unknown", account.id)
    Repo.put_account(account.id)

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expired = key |> Ecto.Changeset.change(expires_at: now) |> Repo.update!()
    refute ApiKeys.usable?(key.key_id, account.id)
    expired |> Ecto.Changeset.change(expires_at: nil) |> Repo.update!()
    assert ApiKeys.usable?(key.key_id, account.id)

    suspended =
      account |> Ecto.Changeset.change(status: :suspended) |> Repo.update!(skip_account: true)

    refute ApiKeys.usable?(key.key_id, account.id)
    suspended |> Ecto.Changeset.change(status: :active) |> Repo.update!(skip_account: true)
    assert ApiKeys.usable?(key.key_id, account.id)
    ApiKeys.revoke(key)
    refute ApiKeys.usable?(key.key_id, account.id)
  end

  test "a peer that keeps failing is throttled, valid key or not" do
    {:ok, %{secret: secret}} = ApiKeys.create("throttled")
    peer = "198.51.100.#{System.unique_integer([:positive])}"
    for _ <- 1..20, do: assert(:error = ApiKeys.authenticate("hm_bad", peer))
    assert :error = ApiKeys.authenticate(secret, peer)
    assert {:ok, _} = ApiKeys.authenticate(secret, "another")
  end

  test "a key needs a name" do
    assert {:error, :name} = ApiKeys.create("   ")
  end
end
