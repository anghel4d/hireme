defmodule HiremeWeb.AccountTest do
  # The account RPCs a browser session calls over the wire: who may call,
  # what a call costs, and what the trail shows of it.
  use Hireme.DataCase, async: false
  use ExUnitProperties

  alias Ecto.Adapters.SQL.Sandbox
  alias Hireme.Rows.ApiKey
  alias HiremeWeb.Account

  # The account's trail rows, their meta as the trail view shows it.
  defp rows(account_id) do
    Repo.all(from(e in Hireme.Rows.Audit, where: e.account_id == ^account_id, order_by: e.id),
      skip_account: true
    )
    |> Enum.map(&%{&1 | meta: Hireme.Audit.visible(&1.meta || %{}, &1.kind)})
  end

  setup do
    %{session: s} = signed = sign_in()

    Map.put(signed, :ctx, %{
      account_id: s.account_id,
      session_id: s.id,
      ip: "127.0.0.1",
      user_agent: "test"
    })
  end

  defp mint(ctx, p \\ %{}) do
    Account.call("account.key.mint", Map.merge(%{"name" => "k", "preset" => "read_only"}, p), ctx)
  end

  defp pause(key_id) do
    ApiKey
    |> Repo.get(key_id, skip_account: true)
    |> Ecto.Changeset.change(paused_at: Hireme.Store.now())
    |> Repo.update!(skip_account: true)
  end

  defp paused?(key_id), do: Repo.get(ApiKey, key_id, skip_account: true).paused_at != nil

  test "a key's session, another account's session and a lapsed session are refused; a stale one must step up to unlink a way in or resume a key; a secret is shown once",
       %{session: s, ctx: ctx} do
    key_ctx = %{ctx | session_id: nil} |> Map.put(:key, %{id: 1})

    for m <- ~w(account.overview account.watch account.key.mint account.session.revoke_others),
        do: assert({:error, %{error: "scope"}} = Account.call(m, %{}, key_ctx))

    %{session: other} = sign_in()

    assert {:error, %{error: "scope"}} =
             Account.call("account.rename", %{"name" => "x"}, %{ctx | session_id: other.id})

    assert {:error, %{error: "unknown_method"}} = Account.call("account.nope", %{}, ctx)

    assert {:ok, %{key: key, secret: "hm_" <> _}} = mint(ctx, %{"preset" => "write_only"})
    assert key.preset == :write_only
    refute inspect(key) =~ ~r/secret_hash|token_hash|totp_secret|public_key|code_hash|salt/

    pause(key.id)
    [identity] = Repo.with_account(s.account_id, fn -> Repo.all(Hireme.Rows.Identity) end)
    age(s, :authenticated_at, Hireme.Security.step_up_window() + 1)

    assert {:error, %{error: "step_up"}} =
             Account.call("account.identity.unlink", %{"id" => identity.id}, ctx)

    assert {:error, %{error: "step_up"}} =
             Account.call("account.key.resume", %{"id" => key.id}, ctx)

    assert paused?(key.id)

    age(s, :last_seen_at, Hireme.Security.session_idle() + 1)
    assert {:error, %{error: "session"}} = Account.call("account.rename", %{"name" => "x"}, ctx)
  end

  property "no call on junk params raises; a malformed one answers an error; an expiry outside 1..3650 days or an id past 64 bits is refused, and refusals cost nothing",
           %{ctx: ctx} do
    methods =
      ~w(account.rename account.key.mint account.key.change account.key.rename account.key.resume
         account.key.revoke account.session.revoke account.identity.unlink account.totp.confirm
         account.step_up.totp account.step_up.mail_code account.trusted_host.add account.trusted_host.remove
         account.lease.revoke account.factor.remove)

    junk =
      one_of([
        integer(),
        float(),
        boolean(),
        constant(nil),
        list_of(integer(), max_length: 3),
        map_of(string(:alphanumeric), integer(), max_length: 2)
      ])

    names = ~w(id name code host note preset expires_in_days read_mask write_mask may_delete)

    check all(
            method <- member_of(methods),
            params <- map_of(member_of(names), junk, max_length: 4),
            max_runs: 60
          ) do
      # A well-typed id that names nothing may be an idempotent ok (a remove).
      case Account.call(method, params, ctx) do
        {:error, %{error: code}} -> assert is_binary(code)
        other -> assert {:ok, _} = other
      end
    end

    for {m, p} <- [
          {"account.key.mint", %{"name" => %{"x" => 1}, "preset" => "read_only"}},
          {"account.key.rename", %{"id" => 1, "name" => [1]}},
          {"account.step_up.totp", %{"code" => %{}}},
          {"account.totp.confirm", %{"code" => 5}},
          {"account.session.revoke", %{"id" => "x"}}
        ] do
      assert {:error, %{error: code}} = Account.call(m, p, ctx)
      assert is_binary(code)
    end

    for bad <- [0, -1, 3651, "30", 1.5, %{}],
        do: assert({:error, %{error: "invalid"}} = mint(ctx, %{"expires_in_days" => bad}))

    assert {:ok, %{key: %{expires_at: %DateTime{}}}} = mint(ctx, %{"expires_in_days" => 30})
    huge = %{"id" => 1_000_000_000_000_000_000_000_000_000, "preset" => "read_only"}

    for _ <- 1..100,
        do: assert({:error, %{error: "invalid"}} = Account.call("account.key.change", huge, ctx))

    assert {:ok, _} = mint(ctx)
  end

  test "a write that changes nothing records nothing: a rename to the same name, a host already trusted however it is spelled; a name or note is bounded",
       %{session: s, ctx: ctx} do
    add = &Account.call("account.trusted_host.add", %{"host" => &1, "note" => &2}, ctx)
    {:ok, _} = Account.call("account.rename", %{"name" => "First"}, ctx)
    {:ok, %{trusted_host: %{id: id}}} = add.("levels.fyi", "n")
    cursor = length(rows(s.account_id))
    {:ok, _} = Account.call("account.rename", %{"name" => "First"}, ctx)

    for host <- ["levels.fyi", "LEVELS.FYI", "levels.fyi.", "https://levels.fyi/x"],
        do: assert({:ok, %{trusted_host: %{id: ^id}}} = add.(host, "n"))

    assert length(rows(s.account_id)) == cursor

    assert {:error, %{error: "invalid"}} =
             Account.call("account.rename", %{"name" => String.duplicate("é", 250)}, ctx)

    assert {:error, %{error: "invalid"}} = add.("example.org", String.duplicate("n", 501))
  end

  @tag window: [:account_writes, :ceremony_session]
  test "account writes share one budget, charged only when they write, even in parallel; revoking is always possible; ceremonies are bounded per session",
       %{ctx: ctx} do
    # Refused calls cost nothing; one trusted host is written, the 29 repeats given back.
    bad = %{"name" => "k", "read_mask" => 99, "write_mask" => 0}
    for _ <- 1..70, do: {:error, _} = Account.call("account.key.mint", bad, ctx)

    for _ <- 1..30,
        do:
          {:ok, _} =
            Account.call("account.trusted_host.add", %{"host" => "levels.fyi", "note" => ""}, ctx)

    parent = self()

    results =
      1..90
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          mint(ctx)
        end)
      end)
      |> Enum.map(&Task.await(&1, 30_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 59
    assert {:error, %{error: "rate_limited"}} = mint(ctx)

    # The budget spent, the owner still revokes.
    {:ok, %{key: %{id: id}}} = Enum.find(results, &match?({:ok, _}, &1))
    assert {:ok, %{key: %{live: false}}} = Account.call("account.key.revoke", %{"id" => id}, ctx)
    assert {:ok, _} = Account.call("account.session.revoke_others", %{}, ctx)

    begun = for _ <- 1..31, do: Account.call("account.totp.begin", %{}, ctx)
    assert Enum.count(begun, &match?({:ok, _}, &1)) == 30
    assert {:error, %{error: "rate_limited"}} = List.last(begun)
  end

  test "no trail row reaches the lens with a hash, secret, token or code in its meta at any depth; a coalesced row's counts pass by shape; every field the lens shows survives",
       %{session: s} do
    record = &Hireme.Audit.record(&1, &2, %{account_id: s.account_id})

    record.(:link_redeemed, %{
      email_hash: "0123456789abcdef",
      password: "p",
      api_key: "k",
      token: ["abc"],
      recovery_code: "c",
      secret: "s",
      domain: "example.com",
      nested: %{api_secret: "s", ok: 1},
      list: [%{token: "t", n: 2}],
      credential: %{value: "v"}
    })

    record.(:revokes_coalesced, %{"counts" => %{"link_token" => %{"none" => 4}}, "token" => "t"})
    # An ordinary row's counts are data like any other, even in a counts shape.
    record.(:host_trusted, %{counts: %{token: 1, link_token: %{a: 1}}, host: "h"})

    record.(:activity_coalesced, %{
      "counts" => %{"agent_ops" => %{"7" => 3, "x" => "secret", "y" => %{"z" => 1}}, "k" => 5}
    })

    # The lens's own list (assets/js/lenses/trail.ts, SHOWN), so a field the
    # strip would hide cannot vanish from the lens unnoticed. Every [field,
    # label] pair literal, however it is spaced or cased; the names read must
    # be one per pair, so a format the regex misses fails.
    trail = File.read!(Path.expand("../../assets/js/lenses/trail.ts", __DIR__))
    [shown] = Regex.run(~r/const SHOWN(.*?)\n\]\)/s, trail, capture: :all_but_first)
    pairs = Regex.scan(~r/\[\s*"[^"]*"\s*,\s*"[^"]*"\s*\]/, shown)
    named = Regex.scan(~r/\[\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*,\s*"[^"]*"\s*\]/, shown)
    assert length(named) == length(pairs) and pairs != []
    fields = named |> Enum.map(fn [_, f] -> f end) |> Enum.uniq()
    assert "left" in fields
    record.(:host_distrusted, Map.new(fields, &{&1, 1}))

    meta = for e <- rows(s.account_id), into: %{}, do: {e.kind, e.meta}

    assert meta["link_redeemed"] == %{
             "domain" => "example.com",
             "nested" => %{"ok" => 1},
             "list" => [%{"n" => 2}]
           }

    assert meta["revokes_coalesced"] == %{"counts" => %{"link_token" => %{"none" => 4}}}
    assert meta["host_trusted"] == %{"counts" => %{}, "host" => "h"}
    assert meta["activity_coalesced"] == %{"counts" => %{"agent_ops" => %{"7" => 3}}}
    assert Enum.sort(Map.keys(meta["host_distrusted"])) == Enum.sort(fields)

    for {kind, m} <- meta,
        k <- Map.keys(m),
        do: refute(to_string(k) =~ ~r/hash|secret|token|code/i, "#{kind} meta #{k}")
  end

  test "a key's lifecycle rows name the key; a pause outlives a mask change, lifts once on resume (recorded, the account told), and a revoked key cannot be resumed",
       %{session: s, ctx: ctx} do
    {:ok, %{key: key}} = mint(ctx)
    {:ok, _} = Account.call("account.key.rename", %{"id" => key.id, "name" => "k2"}, ctx)
    pause(key.id)

    {:ok, _} =
      Account.call("account.key.change", %{"id" => key.id, "preset" => "read_write"}, ctx)

    assert paused?(key.id)
    Hireme.PubSub.subscribe(Hireme.Audit.topic(s.account_id))

    assert {:ok, %{key: %{paused: false, paused_at: nil}}} =
             Account.call("account.key.resume", %{"id" => key.id}, ctx)

    assert_receive {:resume, {:key, id}} when id == key.id
    # Resuming a key that is not paused records nothing.
    before = length(rows(ctx.account_id))

    assert {:ok, %{key: %{paused: false}}} =
             Account.call("account.key.resume", %{"id" => key.id}, ctx)

    assert length(rows(ctx.account_id)) == before
    # A revoke clears the pause, and a revoked key cannot be resumed.
    pause(key.id)
    {:ok, _} = Account.call("account.key.revoke", %{"id" => key.id}, ctx)
    refute paused?(key.id)

    assert {:error, %{error: "not_found"}} =
             Account.call("account.key.resume", %{"id" => key.id}, ctx)

    lifecycle = ~w(api_key_created api_key_renamed api_key_changed key_resumed api_key_revoked)
    named = for e <- rows(ctx.account_id), e.kind in lifecycle, do: {e.kind, e.key_id}
    assert Enum.sort(named) == Enum.sort(Enum.map(lifecycle, &{&1, key.id}))
  end
end
