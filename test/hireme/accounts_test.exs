defmodule Hireme.AccountsTest do
  use Hireme.DataCase, async: false

  alias Hireme.Accounts
  alias Hireme.Accounts.MagicLink
  alias Hireme.Repo
  alias Hireme.Security

  test "a session lives until revoked, expired, or idle", %{account: account} do
    {token, session} = Accounts.start_session(account, %{ip: "127.0.0.1", user_agent: "test"})
    assert {%{id: id}, %{id: account_id}} = Accounts.session(token)
    assert id == session.id and account_id == account.id
    assert Accounts.session("not a token") == nil
    assert Accounts.session(nil) == nil

    # Seen at most once a minute: a second look within it leaves the stamp.
    assert {%{last_seen_at: seen}, _} = Accounts.session(token)
    assert seen == session.last_seen_at
    aged = DateTime.add(session.last_seen_at, -61, :second)
    session |> Ecto.Changeset.change(last_seen_at: aged) |> Repo.update!(skip_account: true)
    assert {%{last_seen_at: touched}, _} = Accounts.session(token)
    assert DateTime.compare(touched, aged) == :gt

    past =
      DateTime.utc_now()
      |> DateTime.add(-(Security.session_idle() + 1), :second)
      |> DateTime.truncate(:second)

    session |> Ecto.Changeset.change(last_seen_at: past) |> Repo.update!(skip_account: true)
    assert Accounts.session(token) == nil

    {token2, s2} = Accounts.start_session(account)

    s2
    |> Ecto.Changeset.change(expires_at: DateTime.truncate(DateTime.utc_now(), :second))
    |> Repo.update!(skip_account: true)

    assert Accounts.session(token2) == nil

    {token3, s3} = Accounts.start_session(account)
    Accounts.revoke_session(s3)
    assert Accounts.session(token3) == nil
  end

  test "revoking the other sessions keeps the one asking", %{account: account} do
    {keep_token, keep} = Accounts.start_session(account)
    {other_token, _} = Accounts.start_session(account)
    assert 1 = Accounts.revoke_other_sessions(keep)
    assert Accounts.session(other_token) == nil
    assert {%{id: id}, _} = Accounts.session(keep_token)
    assert id == keep.id
    assert [%{id: ^id}] = Accounts.list_sessions(account.id)
  end

  test "a suspended account's sessions stop working", %{account: account} do
    {token, _} = Accounts.start_session(account)
    account |> Ecto.Changeset.change(status: :suspended) |> Repo.update!(skip_account: true)
    assert Accounts.session(token) == nil
  end

  test "session authentication finds its owner before an account is selected", %{account: account} do
    {token, session} = Accounts.start_session(account)
    Repo.put_account(nil)
    assert {%{id: id}, %{id: account_id}} = Accounts.session(token)
    assert id == session.id and account_id == account.id
    assert Repo.account_id() == nil

    other = Hireme.DataCase.open_account("Other desk")
    assert {%{id: ^id}, %{id: ^account_id}} = Accounts.session(token)
    assert Repo.account_id() == other.id
  end

  describe "sign-in links" do
    defp link_url(token), do: "https://desk.test/sign-in/email?token=" <> token

    defp mailed_token,
      do:
        receive(
          do: ({:email, %Swoosh.Email{text_body: body}} ->
                 Regex.run(~r{token=([A-Za-z0-9_-]+)}, body) |> Enum.at(1)),
          after: (1_000 -> nil)
        )

    test "a link is mailed to the address as given, is peeked freely, and is spent once" do
      assert :ok = Accounts.request_link("  Someone@Example.COM ", &link_url/1, %{ip: "10.0.0.1"})
      assert_receive {:email, %Swoosh.Email{to: [{_, "someone@example.com"}], text_body: body}}

      assert [_, token] =
               Regex.run(~r{https://desk.test/sign-in/email\?token=([A-Za-z0-9_-]+)}, body)

      assert byte_size(token) >= 40

      assert {:ok, "someone@example.com"} = Accounts.peek_link(token)
      assert {:ok, "someone@example.com"} = Accounts.peek_link(token)

      # Only a hash is stored, and twenty hands reaching at once sign in once.
      raw = Base.url_decode64!(token, padding: false)

      hashes =
        Repo.all(Hireme.Accounts.MagicLink, skip_account: true) |> Enum.map(& &1.token_hash)

      assert Security.hash(raw) in hashes
      refute Enum.any?(hashes, &(&1 == raw or Base.encode64(&1) == token))

      redeemed =
        1..20
        |> Task.async_stream(fn _ -> Accounts.redeem_link(token, %{ip: "203.0.113.9"}) end)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(redeemed, &match?({:ok, "someone@example.com"}, &1)) == 1
      assert {:error, :invalid} = Accounts.peek_link(token)
      assert {:error, :invalid} = Accounts.redeem_link(token)
      assert {:error, :invalid} = Accounts.redeem_link("not-a-token")
      assert {:error, :invalid} = Accounts.request_link("nobody", &link_url/1)
      assert {:ok, "a@b.co"} = Accounts.normalize_email(" A@B.co ")
      refute_received {:email, _}
    end

    test "a link dies with its clock and a mailbox is not hammered" do
      assert :ok = Accounts.request_link("late@example.com", &link_url/1)
      token = mailed_token()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      expire = fn at ->
        Repo.update_all(MagicLink, [set: [expires_at: at]], skip_account: true)
      end

      expire.(DateTime.add(now, 1, :second))
      assert {:ok, "late@example.com"} = Accounts.peek_link(token)
      expire.(now)
      assert {:error, :invalid} = Accounts.redeem_link(token)

      # Five asks for one address from anywhere, twenty from one peer for any
      # address; the two limits keep separate counts.
      from = fn n -> %{ip: "198.51.100.#{n}"} end

      for n <- 1..4,
          do: assert(:ok = Accounts.request_link("late@example.com", &link_url/1, from.(n)))

      assert {:error, :rate_limited} =
               Accounts.request_link("late@example.com", &link_url/1, from.(5))

      for n <- 1..20,
          do: assert(:ok = Accounts.request_link("peer#{n}@example.com", &link_url/1, from.(99)))

      assert {:error, :rate_limited} =
               Accounts.request_link("peer21@example.com", &link_url/1, from.(99))
    end
  end

  describe "sign-in methods" do
    test "a proven identity signs in to its own account, new or known", %{account: mine} do
      claim = %{subject: "new@example.com", display: "new@example.com"}
      assert {:ok, token, session} = Accounts.sign_in_with(:email, claim)
      assert {%{id: sid}, %{id: theirs}} = Accounts.session(token)
      assert sid == session.id and theirs != mine.id
      assert Repo.account_id!() == theirs
      assert [%{provider: :email, subject: "new@example.com"}] = Accounts.identities()

      assert {:ok, _, _} = Accounts.sign_in_with(:email, %{claim | display: "New"})
      assert Repo.account_id!() == theirs
      assert [%{display: "New"}] = Accounts.identities()

      assert {:ok, _, _} = Accounts.sign_in_with(:github, %{subject: "4242", display: "octo"})
      assert Repo.account_id!() != theirs
      assert [%{provider: :github}] = Accounts.identities()
    end

    test "a suspended account is not signed in to" do
      {:ok, _, _} = Accounts.sign_in_with(:x, %{subject: "77", display: "x"})

      Repo.get!(Hireme.Accounts.Account, Repo.account_id!(), skip_account: true)
      |> Ecto.Changeset.change(status: :suspended)
      |> Repo.update!(skip_account: true)

      assert {:error, :suspended} = Accounts.sign_in_with(:x, %{subject: "77", display: "x"})
    end

    test "an account links any number of ways in, keeps the last, and hears about each", %{
      account: mine
    } do
      assert {:ok, mail} =
               Accounts.link(:email, %{subject: "me@example.com", display: "me@example.com"})

      assert {:ok, gh} = Accounts.link(:github, %{subject: "9", display: "me"})

      Hireme.Mailer.Outbox.drain()

      assert_received {:email,
                       %Swoosh.Email{
                         to: [{_, "me@example.com"}],
                         subject: "Hireme: github sign-in me was linked"
                       }}

      assert {:ok, %{id: same}} = Accounts.link(:github, %{subject: "9", display: "me again"})
      assert same == gh.id
      assert Enum.map(Accounts.identities(), & &1.id) == [mail.id, gh.id]

      other = Hireme.DataCase.open_account("Other desk")
      assert {:error, :taken} = Accounts.link(:github, %{subject: "9", display: "thief"})
      assert {:error, :not_found} = Accounts.unlink(gh.id)
      assert Accounts.identities() == []

      Repo.put_account(mine.id)
      assert :ok = Accounts.unlink(gh.id)

      Hireme.Mailer.Outbox.drain()

      assert_received {:email,
                       %Swoosh.Email{
                         to: [{_, "me@example.com"}],
                         subject: "Hireme: github sign-in me again was unlinked"
                       }}

      assert {:error, :last} = Accounts.unlink(mail.id)
      assert [%{id: kept}] = Accounts.identities()
      assert kept == mail.id and other.id != mine.id
    end

    test "a notice reaches every address on the account and the trail" do
      {:ok, _} = Accounts.link(:email, %{subject: "a@example.com", display: "a"})
      {:ok, _} = Accounts.link(:email, %{subject: "b@example.com", display: "b"})
      assert :ok = Accounts.notify(Repo.account_id!(), :api_key_created, %{name: "ci"})
      Hireme.Mailer.Outbox.drain()

      for addr <- ["a@example.com", "b@example.com"] do
        subject = ~s(Hireme: an API key named "ci" was created)

        assert_received {:email,
                         %Swoosh.Email{to: [{_, ^addr}], subject: ^subject, text_body: body}}

        assert body =~ "revoke your keys"
      end

      assert Enum.any?(
               Hireme.Audit.recent(),
               &(&1.kind == "notified" and &1.meta["about"] == "api_key_created")
             )
    end
  end
end
