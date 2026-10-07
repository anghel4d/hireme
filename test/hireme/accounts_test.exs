defmodule Hireme.AccountsTest do
  use Hireme.DataCase, async: false

  alias Hireme.Accounts
  alias Hireme.Repo
  alias Hireme.Security

  test "a session lives until revoked, expired, or idle", %{account: account} do
    {token, session} = Accounts.start_session(account, %{ip: "127.0.0.1", user_agent: "test"})
    assert {%{id: id}, %{id: account_id}} = Accounts.session(token)
    assert id == session.id and account_id == account.id
    assert Accounts.session("not a token") == nil
    assert Accounts.session(nil) == nil

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

  describe "sign-in links" do
    defp link_url(token), do: "https://desk.test/sign-in/email?token=" <> token

    defp mailed_token,
      do:
        receive(
          do: ({:email, %Swoosh.Email{text_body: body}} ->
                 Regex.run(~r{token=([A-Za-z0-9_-]+)}, body) |> Enum.at(1)),
          after: (0 -> nil)
        )

    test "a link is mailed to the address as given, is peeked freely, and is spent once" do
      assert :ok = Accounts.request_link("  Someone@Example.COM ", &link_url/1, %{ip: "10.0.0.1"})
      assert_received {:email, %Swoosh.Email{to: [{_, "someone@example.com"}], text_body: body}}

      assert [_, token] =
               Regex.run(~r{https://desk.test/sign-in/email\?token=([A-Za-z0-9_-]+)}, body)

      assert byte_size(token) >= 40

      assert {:ok, "someone@example.com"} = Accounts.peek_link(token)
      assert {:ok, "someone@example.com"} = Accounts.peek_link(token)
      assert {:ok, "someone@example.com"} = Accounts.redeem_link(token)
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

      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      Repo.update_all(Hireme.Accounts.MagicLink, [set: [expires_at: past]], skip_account: true)
      assert {:error, :invalid} = Accounts.redeem_link(token)

      for _ <- 1..4, do: assert(:ok = Accounts.request_link("late@example.com", &link_url/1))
      assert {:error, :rate_limited} = Accounts.request_link("late@example.com", &link_url/1)
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
