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
end
