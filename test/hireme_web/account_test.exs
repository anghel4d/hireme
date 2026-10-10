defmodule HiremeWeb.AccountTest do
  use Hireme.DataCase, async: false

  import Hireme.Fixtures
  alias Hireme.Accounts
  alias Hireme.ApiKeys
  alias Hireme.Audit
  alias HiremeWeb.Account

  defp session(account, opts \\ []) do
    {_token, s} = Accounts.start_session(account, %{ip: "198.51.100.9", user_agent: "test"})
    if opts[:stale], do: age!(s), else: s
  end

  defp ctx(account, s), do: %{account_id: account.id, session_id: s.id, ip: "198.51.100.9"}

  # The account's tables as the session pushes them.
  defp read(account, s), do: tables(IO.iodata_to_binary(Account.tables(account.id, s.id)))

  # Another tab of the same account, listening the way a wire session does.
  defp other_tab(account) do
    me = self()

    spawn_link(fn ->
      Phoenix.PubSub.subscribe(Hireme.PubSub, Audit.topic(account.id))
      send(me, :listening)

      receive do
        {Audit, :changed} -> send(me, :other_tab_heard)
      end
    end)

    assert_receive :listening
  end

  test "a fresh session creates a key, sees its secret once, and other tabs hear of it", %{
    account: account
  } do
    s = session(account)
    other_tab(account)
    Phoenix.PubSub.subscribe(Hireme.PubSub, Audit.topic(account.id))

    assert {:ok, %{ok: true, secret: secret, created: created}, :changed} =
             Account.call(
               "account/create_key",
               %{"name" => "agent", "expires_in_days" => 30},
               ctx(account, s)
             )

    assert is_binary(secret) and created.name == "agent"
    assert Enum.any?(ApiKeys.list(), &(&1.id == created.id))
    encoded = IO.iodata_to_binary(Account.tables(account.id, s.id))
    refute encoded =~ secret or encoded =~ ~r/hm_[0-9A-Za-z]{12}_[0-9A-Za-z]{43}/
    assert_receive :other_tab_heard
    # The caller pushes its own tables before the reply; it is not told again.
    refute_receive {Audit, :changed}, 50
  end

  test "a stale session is refused every step-up command, and still renames", %{account: account} do
    s = session(account, stale: true)
    {:ok, %{key: key}} = ApiKeys.create("old")
    {:ok, identity} = Accounts.link(:github, %{subject: "sub-1", display: "octo"})

    for {method, params} <- [
          {"create_key", %{"name" => "x"}},
          {"revoke_key", %{"id" => key.id}},
          {"revoke_other_sessions", %{}},
          {"begin_totp", %{}},
          {"confirm_totp", %{"code" => "000000"}},
          {"begin_webauthn", %{}},
          {"confirm_webauthn", %{}},
          {"remove_factor", %{"id" => 1}},
          {"recovery_codes", %{}},
          {"unlink", %{"id" => identity.id}}
        ] do
      assert Account.call("account/" <> method, params, ctx(account, s)) ==
               {:error, 403, "step_up"}
    end

    # Refused before anything is written.
    assert length(ApiKeys.list()) == 1 and Hireme.Mfa.methods() == []
    assert Enum.any?(Accounts.identities(), &(&1.id == identity.id))

    assert {:ok, _, :changed} =
             Account.call(
               "account/rename_key",
               %{"id" => key.id, "name" => "new"},
               ctx(account, s)
             )

    assert ApiKeys.get(key.id).name == "new"
    assert is_nil(ApiKeys.get(key.id).revoked_at)
  end

  test "the session row is read per call: a step-up proved elsewhere counts at once", %{
    account: account
  } do
    s = session(account, stale: true)

    assert {:error, 403, "step_up"} =
             Account.call("account/revoke_other_sessions", %{}, ctx(account, s))

    Accounts.mark_mfa(s)
    # No factor enrolled: freshness is the sign-in time, so prove by signing in again.
    s
    |> Ecto.Changeset.change(authenticated_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    other = session(account)

    assert {:ok, _, :changed} =
             Account.call("account/revoke_other_sessions", %{}, ctx(account, s))

    assert Account.call("account/rename_key", %{"id" => 1, "name" => "x"}, ctx(account, other)) ==
             {:signed_out, %{signed_out: true}}
  end

  test "revoking this session signs it out; another account's rows are not found", %{
    account: account
  } do
    s = session(account)
    {:ok, %{key: key}} = ApiKeys.create("mine")

    stranger = open_account("Stranger")
    t = session(stranger)

    assert Account.call("account/revoke_key", %{"id" => key.id}, ctx(stranger, t)) ==
             {:error, 404, "not found"}

    assert Account.call("account/revoke_session", %{"id" => s.id}, ctx(stranger, t)) ==
             {:error, 404, "not found"}

    Repo.put_account(account.id)
    assert is_nil(ApiKeys.get(key.id).revoked_at)

    assert {:signed_out, %{signed_out: true}} =
             Account.call("account/revoke_session", %{"id" => s.id}, ctx(account, s))

    assert {:signed_out, _} =
             Account.call("account/revoke_key", %{"id" => key.id}, ctx(account, s))

    assert Account.call("nope", %{}, ctx(account, s)) == {:error, 404, "unknown method"}
  end

  test "an app is enrolled and proved over the session, and the tables follow", %{
    account: account
  } do
    s = session(account)
    {:ok, _} = ApiKeys.create("visible")
    before = read(account, s)
    me = s.id
    assert [%{me: ^me, enrolled: 0}] = named(before, :acct)
    assert Enum.map(named(before, :acct_keys), & &1.name) == ["visible"]
    assert named(before, :acct_factors) == []
    assert Enum.any?(named(before, :acct_sessions), &(&1.id == s.id))

    assert {:ok, %{secret: b32}, :same} = Account.call("account/begin_totp", %{}, ctx(account, s))
    secret = Base.decode32!(b32, padding: false)

    code = NimbleTOTP.verification_code(secret)

    assert {:ok, %{recovery_codes: [_ | _] = codes}, :changed} =
             Account.call(
               "account/confirm_totp",
               %{"code" => code, "name" => "phone"},
               ctx(account, s)
             )

    after_enrol = read(account, s)
    assert [%{kind: "totp", name: "phone"}] = named(after_enrol, :acct_factors)
    assert [%{recovery_left: left, enrolled: 1}] = named(after_enrol, :acct)
    assert left == length(codes)

    # Enrolment proved the factor: this session is fresh. A stale one must step up.
    stale = session(account, stale: true)
    Repo.update!(Ecto.Changeset.change(stale, mfa_at: nil))

    assert {:error, 403, "step_up"} =
             Account.call("account/recovery_codes", %{}, ctx(account, stale))

    assert {:error, 401, _} =
             Account.call("account/step_up_recovery", %{"code" => "nope"}, ctx(account, stale))

    assert {:ok, %{fresh: true}, :changed} =
             Account.call("account/step_up_recovery", %{"code" => hd(codes)}, ctx(account, stale))

    assert {:ok, %{recovery_codes: [_ | _]}, :changed} =
             Account.call("account/recovery_codes", %{}, ctx(account, stale))
  end
end
