defmodule HiremeWeb.AccountTest do
  use Hireme.DataCase, async: false

  alias HiremeWeb.Account

  setup do
    %{session: s} = signed = sign_in()

    Map.put(signed, :ctx, %{
      account_id: s.account_id,
      session_id: s.id,
      ip: "127.0.0.1",
      user_agent: "test"
    })
  end

  test "a key's session is refused every account method", %{ctx: ctx} do
    key_ctx = %{ctx | session_id: nil} |> Map.put(:key, %{id: 1})

    for m <- ~w(account.overview account.watch account.key.mint account.session.revoke_others),
        do: assert({:error, %{error: "scope"}} = Account.call(m, %{}, key_ctx))
  end

  test "another account's session id in the context is refused", %{ctx: ctx} do
    %{session: other} = sign_in()

    assert {:error, %{error: "scope"}} =
             Account.call("account.overview", %{}, %{ctx | session_id: other.id})
  end

  test "a minted key's secret is shown once, and no projection carries a hash or sealed secret",
       %{ctx: ctx} do
    assert {:ok, %{key: key, secret: "hm_" <> _}} =
             Account.call("account.key.mint", %{"name" => "agent", "preset" => "write_only"}, ctx)

    assert key.preset == :write_only
    assert {:ok, overview} = Account.call("account.overview", %{}, ctx)
    assert [%{name: "agent"}] = overview.keys
    refute inspect(overview) =~ ~r/secret_hash|token_hash|totp_secret|public_key|code_hash|salt/
  end

  test "watch parks; unknown methods are named as such", %{ctx: ctx} do
    assert {:park, :account} = Account.call("account.watch", %{}, ctx)
    assert {:error, %{error: "unknown_method"}} = Account.call("account.nope", %{}, ctx)
  end

  test "a stale session is told to step up before unlinking a way in", %{session: s, ctx: ctx} do
    age(s, :authenticated_at, Hireme.Security.step_up_window() + 1)
    [identity] = Repo.with_account(s.account_id, &Hireme.Accounts.identities/0)

    assert {:error, %{error: "step_up"}} =
             Account.call("account.identity.unlink", %{"id" => identity.id}, ctx)
  end
end
