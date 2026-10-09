defmodule Hireme.OutboxTest.Provider do
  @moduledoc false
  # A mail provider the test steers: it reports every send to the test and
  # answers per address with :ok, :fail, :raise, or :barrier (held until
  # the sender is sent :release).
  use Swoosh.Adapter

  @impl true
  def deliver(%Swoosh.Email{to: [{_, address}], subject: subject}, config) do
    send(config[:test], {:delivering, address, subject, self()})

    case Map.get(config[:modes] || %{}, address, config[:mode] || :ok) do
      :ok ->
        {:ok, %{}}

      :fail ->
        {:error, :provider_down}

      :raise ->
        raise "provider exploded\n\twith é #{String.duplicate("x", 300)}"

      :barrier ->
        receive do
          :release -> {:ok, %{}}
        end
    end
  end
end

defmodule Hireme.OutboxTest do
  import ExUnit.CaptureLog
  use Hireme.DataCase, async: false

  alias Hireme.Accounts
  alias Hireme.ApiKeys
  alias Hireme.Mailer.Notice
  alias Hireme.Mailer.Outbox
  alias Hireme.OutboxTest.Provider

  setup do
    previous = Application.get_env(:hireme, Hireme.Mailer)
    on_exit(fn -> Application.put_env(:hireme, Hireme.Mailer, previous) end)
    :ok
  end

  test "a notice is queued by the change, sent by the outbox, and keeps its fields", %{
    account: account
  } do
    addresses(["a@example.com"])
    provider(mode: :ok)

    :ok = Accounts.notify(account.id, :api_key_created, %{name: "ci", key_id: "k1"})

    assert [%Notice{kind: "api_key_created", meta: %{"name" => "ci", "key_id" => "k1"}}] =
             pending()

    refute_received {:delivering, _, _, _}
    assert Outbox.drain() == 1

    assert_received {:delivering, "a@example.com", ~s(Hireme: an API key named "ci" was created),
                     _}

    assert pending() == []
  end

  test "a failed notice waits out its delay, then is tried again" do
    addresses(["a@example.com"])
    provider(mode: :fail)
    queue()

    # The mailer logs a refused send; that log is part of the contract.
    assert capture_log(fn -> assert Outbox.drain() == 0 end) =~ "provider_down"
    assert_received {:delivering, "a@example.com", _, _}
    assert [%Notice{attempts: 1, last_error: ":provider_down"} = notice] = pending()
    assert DateTime.diff(notice.next_at, DateTime.utc_now()) in 28..30

    assert Outbox.drain() == 0
    refute_received {:delivering, _, _, _}

    provider(mode: :ok)
    assert Outbox.drain(DateTime.add(DateTime.utc_now(), 31, :second)) == 1
    assert pending() == []
  end

  test "a notice that keeps failing is given up after the last delay, its error short and printable" do
    addresses(["a@example.com"])
    provider(mode: :raise)
    queue()
    later = DateTime.add(DateTime.utc_now(), 3 * 86_400, :second)

    for _ <- 1..8, do: assert(Outbox.drain(later) == 0)
    assert [%Notice{attempts: 8, last_error: error}] = pending()
    assert error =~ "provider exploded"
    assert byte_size(error) <= 200 and error =~ ~r/\A[\x20-\x7e]+\z/

    flush()
    assert Outbox.drain(later) == 0
    refute_received {:delivering, _, _, _}
  end

  test "the address an unlink removes is told too" do
    [_keep, gone] = addresses(["keep@example.com", "gone@example.com"])
    provider(mode: :ok)

    :ok = Accounts.unlink(gone.id)
    assert Outbox.drain() == 2

    assert_received {:delivering, "gone@example.com", "Hireme: email sign-in gone was unlinked",
                     _}

    assert_received {:delivering, "keep@example.com", "Hireme: email sign-in gone was unlinked",
                     _}
  end

  test "an address the provider refuses does not hold up the next one", %{account: account} do
    addresses(["bad@example.com", "good@example.com"])
    provider(modes: %{"bad@example.com" => :fail})

    :ok = Accounts.notify(account.id, :api_key_revoked, %{name: "ci"})
    assert capture_log(fn -> assert Outbox.drain() == 1 end) =~ "provider_down"
    assert_received {:delivering, "bad@example.com", _, _}
    assert_received {:delivering, "good@example.com", _, _}
    assert [%Notice{address: "bad@example.com", attempts: 1}] = pending()
  end

  test "a field no notice reads is dropped, not made an atom; an unknown kind fails without one",
       %{
         account: account
       } do
    provider(mode: :ok)
    stranger = "zz_field_#{System.unique_integer([:positive])}"
    kind = "zz_kind_#{System.unique_integer([:positive])}"
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    row = fn kind, meta ->
      %{
        account_id: account.id,
        address: "a@example.com",
        kind: kind,
        meta: meta,
        next_at: now,
        inserted_at: now
      }
    end

    Repo.insert_all(Notice, [
      row.("api_key_created", %{"name" => "ci", stranger => 1}),
      row.(kind, %{"name" => "ci"})
    ])

    assert Outbox.drain() == 1

    assert_received {:delivering, "a@example.com", ~s(Hireme: an API key named "ci" was created),
                     _}

    assert [%Notice{kind: ^kind, attempts: 1, last_error: error}] = pending()
    assert error =~ "atom"
    assert_raise ArgumentError, fn -> String.to_existing_atom(stranger) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(kind) end
  end

  test "notices pending at a restart are sent when the outbox starts" do
    addresses(["a@example.com"])
    provider(mode: :ok)
    queue()

    start_supervised!(Outbox)
    assert GenServer.call(Outbox, :ping) == :pong
    assert_received {:delivering, "a@example.com", _, _}
    assert pending() == []
  end

  test "minting a key does not wait for its notice to be sent" do
    addresses(["a@example.com"])
    provider(mode: :barrier)
    start_supervised!(Outbox)

    # The provider holds the worker until released; a request that waited
    # on the send could not return before the release below.
    assert {:ok, %{key: _}} = ApiKeys.create("ci", nil, %{})
    assert_receive {:delivering, "a@example.com", _, worker}
    assert [%Notice{sent_at: nil}] = pending()

    send(worker, :release)
    assert GenServer.call(Outbox, :ping) == :pong
    assert pending() == []
  end

  # Email ways in for the account, with the notices their linking queued cleared.
  defp addresses(list) do
    identities =
      for address <- list do
        {:ok, identity} =
          Accounts.link(:email, %{subject: address, display: hd(String.split(address, "@"))})

        identity
      end

    Repo.delete_all(Notice, skip_account: true)
    identities
  end

  defp queue, do: :ok = Accounts.notify(Repo.account_id!(), :api_key_created, %{name: "ci"})

  defp provider(opts),
    do: Application.put_env(:hireme, Hireme.Mailer, [adapter: Provider, test: self()] ++ opts)

  defp pending,
    do: Repo.all(from(n in Notice, where: is_nil(n.sent_at), order_by: n.id), skip_account: true)

  defp flush do
    receive do
      {:delivering, _, _, _} -> flush()
    after
      0 -> :ok
    end
  end
end
