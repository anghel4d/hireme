defmodule HiremeWeb.AccountTest do
  use Hireme.DataCase, async: false

  alias Hireme.Accounts
  alias Hireme.ApiKeys
  alias Hireme.Audit
  alias HiremeWeb.Account

  defp session(account, opts \\ []) do
    {_token, s} = Accounts.start_session(account, %{ip: "198.51.100.9", user_agent: "test"})

    if opts[:stale] do
      old = DateTime.utc_now() |> DateTime.add(-(Hireme.Security.step_up_window() + 1))

      s
      |> Ecto.Changeset.change(authenticated_at: DateTime.truncate(old, :second))
      |> Repo.update!()
    else
      s
    end
  end

  defp ctx(account, s), do: %{account_id: account.id, session_id: s.id, ip: "198.51.100.9"}

  # The tables as rows of named values, read straight off the wire layout
  # (`u16 id | u16 ncols | u32 nrows | col*`), u32 and str columns only.
  defp read(account, s) do
    names = %{60 => :acct, 61 => :keys, 62 => :sessions, 63 => :identities, 64 => :factors}
    bin = IO.iodata_to_binary(Account.tables(account.id, s.id))
    for {id, rows} <- tables(bin), into: %{}, do: {names[id], rows}
  end

  defp tables(<<>>), do: []

  defp tables(<<id::little-16, ncols::little-16, nrows::little-32, rest::binary>>) do
    {cols, rest} =
      Enum.map_reduce(1..ncols//1, rest, fn _,
                                            <<cid::little-16, ty, 0, len::little-32, r::binary>> ->
        <<data::binary-size(len), r::binary>> = r
        pad = rem(8 - rem(len, 8), 8)
        <<_::binary-size(pad), r::binary>> = r
        {{cid, column(ty, data, nrows)}, r}
      end)

    rows =
      for i <- 0..(nrows - 1)//1, do: Map.new(cols, fn {cid, vs} -> {cid, Enum.at(vs, i)} end)

    [{id, rows} | tables(rest)]
  end

  defp column(1, data, _n), do: for(<<v::little-32 <- data>>, do: v)

  defp column(2, data, n) do
    <<offs::binary-size((n + 1) * 4), text::binary>> = data
    offs = for <<o::little-32 <- offs>>, do: o

    offs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> binary_part(text, a, b - a) end)
  end

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
    assert_receive :other_tab_heard
    # The caller pushes its own tables before the reply; it is not told again.
    refute_receive {Audit, :changed}, 50
  end

  test "a stale session is refused every step-up command, and still renames", %{account: account} do
    s = session(account, stale: true)
    {:ok, %{key: key}} = ApiKeys.create("old")

    for {method, params} <- [
          {"create_key", %{"name" => "x"}},
          {"revoke_key", %{"id" => key.id}},
          {"revoke_other_sessions", %{}},
          {"remove_factor", %{"id" => 1}},
          {"recovery_codes", %{}},
          {"unlink", %{"id" => 1}}
        ] do
      assert Account.call("account/" <> method, params, ctx(account, s)) ==
               {:error, 403, "step_up"}
    end

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
    assert [%{3 => me, 5 => 0}] = before.acct
    assert me == s.id
    assert Enum.map(before.keys, & &1[3]) == ["visible"]
    assert before.factors == []
    assert Enum.any?(before.sessions, &(&1[1] == s.id))

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
    assert [%{2 => "totp", 3 => "phone"}] = after_enrol.factors
    assert [%{4 => left, 5 => 1}] = after_enrol.acct
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
