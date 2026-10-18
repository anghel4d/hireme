defmodule HiremeWeb.AccountTest do
  use Hireme.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
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

  test "a session past its life is refused on the wire as on a page", %{session: s, ctx: ctx} do
    age(s, :last_seen_at, Hireme.Security.session_idle() + 1)
    assert {:error, %{error: "session"}} = Account.call("account.overview", %{}, ctx)
  end

  test "malformed params answer invalid and never raise", %{ctx: ctx} do
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
  end

  test "a change between a REPLY and the next park is never lost", %{session: s, ctx: ctx} do
    {:ok, %{cursor: cursor}} = Account.call("account.overview", %{}, ctx)
    assert {:park, :account} = Account.call("account.watch", %{"since" => cursor}, ctx)

    # Another page mints a key while this one is between parks.
    {:ok, _} = Hireme.Keys.mint(s, "from elsewhere", Hireme.Keys.preset(:read_only))
    assert {:ok, %{changed: true}} = Account.call("account.watch", %{"since" => cursor}, ctx)

    {:ok, %{cursor: newer, keys: [_]}} = Account.call("account.overview", %{}, ctx)
    assert newer > cursor
    assert {:park, :account} = Account.call("account.watch", %{"since" => newer}, ctx)
  end

  test "renaming a key moves the cursor like every other change", %{session: s, ctx: ctx} do
    {:ok, %{key: key}} = Hireme.Keys.mint(s, "agent", Hireme.Keys.preset(:read_only))
    {:ok, %{cursor: cursor}} = Account.call("account.overview", %{}, ctx)
    {:ok, _} = Account.call("account.key.rename", %{"id" => key.id, "name" => "renamed"}, ctx)
    assert {:ok, %{changed: true}} = Account.call("account.watch", %{"since" => cursor}, ctx)
  end

  test "a key taking the channel while the lens is parked moves the cursor", %{
    session: s,
    ctx: ctx
  } do
    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Hireme.Sequencer.Registry, s.account_id),
          do: DynamicSupervisor.terminate_child(Hireme.Sequencer.Dynamic, pid)
    end)

    {:ok, %{secret: secret}} = Hireme.Keys.mint(s, "agent", Hireme.Keys.preset(:read_write))
    {:ok, %{cursor: cursor, leases: []}} = Account.call("account.overview", %{}, ctx)
    assert {:park, :account} = Account.call("account.watch", %{"since" => cursor}, ctx)
    Phoenix.PubSub.subscribe(Hireme.PubSub, Hireme.Audit.topic(s.account_id))

    alias HiremeWeb.Wire.Codec
    {:ok, wire} = HiremeWeb.Session.open(%{peer_ip: "127.0.0.1", origin: nil, carrier: :ws})
    {:push, _, wire} = HiremeWeb.Session.frame(Codec.encode_hello(:key, secret, "agent"), wire)
    {:push, _, _} = HiremeWeb.Session.frame(Codec.encode_rpc(1, "lease.claim", "{}"), wire)

    # The sequencer records the lease in its own turn; once that announces
    # itself, a watch from the old cursor answers at once.
    assert_receive {Hireme.Audit, :changed}, 2_000
    assert {:ok, %{changed: true}} = Account.call("account.watch", %{"since" => cursor}, ctx)
    assert {:ok, %{leases: [_]}} = Account.call("account.overview", %{}, ctx)
  end

  test "what the lens does by itself never keeps an abandoned tab alive", %{
    session: s,
    ctx: ctx
  } do
    stale = age(s, :last_seen_at, Hireme.Security.session_idle() - 120)
    cursor = Hireme.Audit.rev(s.account_id)
    {:park, :account} = Account.call("account.watch", %{"since" => cursor}, ctx)
    {:ok, _} = Account.call("account.overview", %{"passive" => true}, ctx)

    assert Repo.get(Hireme.Rows.Session, s.id, skip_account: true).last_seen_at ==
             stale.last_seen_at

    {:ok, _} = Account.call("account.overview", %{}, ctx)

    refute Repo.get(Hireme.Rows.Session, s.id, skip_account: true).last_seen_at ==
             stale.last_seen_at
  end

  test "an expiry that is present but not 1..3650 days is refused, never read as never", %{
    ctx: ctx
  } do
    for bad <- [0, -1, 3651, "30", 1.5, %{}] do
      assert {:error, %{error: "invalid"}} =
               Account.call(
                 "account.key.mint",
                 %{"name" => "a", "preset" => "read_only", "expires_in_days" => bad},
                 ctx
               )
    end

    assert {:ok, %{key: %{expires_at: %DateTime{}}}} =
             Account.call(
               "account.key.mint",
               %{"name" => "a", "preset" => "read_only", "expires_in_days" => 30},
               ctx
             )
  end

  test "an account renamed to its own name records nothing", %{session: s, ctx: ctx} do
    {:ok, _} = Account.call("account.rename", %{"name" => "First"}, ctx)
    before = Hireme.Audit.rev(s.account_id)
    {:ok, _} = Account.call("account.rename", %{"name" => "First"}, ctx)
    assert Hireme.Audit.rev(s.account_id) == before

    assert {:error, %{error: "invalid"}} =
             Account.call("account.rename", %{"name" => String.duplicate("é", 250)}, ctx)
  end

  @tag window: :account_writes
  test "account writes are charged only when they write, and revoking is always possible", %{
    ctx: ctx
  } do
    mint = fn p -> Account.call("account.key.mint", Map.merge(%{"name" => "k"}, p), ctx) end

    # Refused calls cost nothing.
    for _ <- 1..70, do: {:error, _} = mint.(%{"read_mask" => 99, "write_mask" => 0})

    keys = for _ <- 1..60, do: mint.(%{"preset" => "read_only"})
    assert Enum.all?(keys, &match?({:ok, _}, &1))
    assert {:error, %{error: "rate_limited"}} = mint.(%{"preset" => "read_only"})

    # The budget spent, the owner still revokes.
    {:ok, %{key: %{id: id}}} = hd(keys)
    assert {:ok, %{key: %{live: false}}} = Account.call("account.key.revoke", %{"id" => id}, ctx)
    assert {:ok, _} = Account.call("account.session.revoke_others", %{}, ctx)
  end

  test "trusting a host already trusted with the same note records nothing", %{ctx: ctx} do
    args = %{"host" => "levels.fyi", "note" => "pay data"}
    assert {:ok, %{trusted_host: %{id: id}}} = Account.call("account.trusted_host.add", args, ctx)
    cursor = Hireme.Audit.rev(ctx.account_id)

    assert {:ok, %{trusted_host: %{id: ^id}}} =
             Account.call("account.trusted_host.add", args, ctx)

    assert Hireme.Audit.rev(ctx.account_id) == cursor

    long = %{"host" => "example.org", "note" => String.duplicate("n", 501)}
    assert {:error, %{error: "invalid"}} = Account.call("account.trusted_host.add", long, ctx)
  end

  test "a host is the same host however it is written", %{ctx: ctx} do
    {:ok, %{trusted_host: %{id: id}}} =
      Account.call("account.trusted_host.add", %{"host" => "levels.fyi", "note" => "n"}, ctx)

    cursor = Hireme.Audit.rev(ctx.account_id)

    for host <- ["LEVELS.FYI", "levels.fyi.", "https://levels.fyi/x"] do
      assert {:ok, %{trusted_host: %{id: ^id}}} =
               Account.call("account.trusted_host.add", %{"host" => host, "note" => "n"}, ctx)
    end

    assert Hireme.Audit.rev(ctx.account_id) == cursor
  end

  @tag window: :ceremony_session
  test "beginning ceremonies is bounded per session", %{ctx: ctx} do
    results = for _ <- 1..31, do: Account.call("account.totp.begin", %{}, ctx)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 30
    assert {:error, %{error: "rate_limited"}} = List.last(results)
  end

  @tag window: :account_writes
  test "parallel writes cannot all pass the budget, and calls that wrote nothing cost nothing", %{
    ctx: ctx
  } do
    parent = self()
    args = %{"name" => "k", "preset" => "read_only"}

    for _ <- 1..30,
        do:
          {:ok, _} =
            Account.call("account.trusted_host.add", %{"host" => "levels.fyi", "note" => ""}, ctx)

    results =
      1..90
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          Account.call("account.key.mint", args, ctx)
        end)
      end)
      |> Enum.map(&Task.await(&1, 30_000))

    # One trusted host was written; the 29 repeats were given back.
    assert Enum.count(results, &match?({:ok, _}, &1)) == 59
  end

  test "the trail pages by view and cursor, security events by default", %{session: s, ctx: ctx} do
    for _ <- 1..3, do: Hireme.Audit.record(:agent_ops, %{}, %{account_id: s.account_id})

    {:ok, %{key: _}} =
      Account.call("account.key.mint", %{"name" => "k", "preset" => "read_only"}, ctx)

    {:ok, %{events: sec}} = Account.call("account.audit", %{}, ctx)
    assert Enum.any?(sec, &(&1.kind == "api_key_created"))
    refute Enum.any?(sec, &(&1.kind == "agent_ops"))

    {:ok, %{events: [_, _], next: next}} =
      Account.call("account.audit", %{"view" => "activity", "limit" => 2}, ctx)

    {:ok, %{events: [last], next: nil}} =
      Account.call("account.audit", %{"view" => "activity", "limit" => 2, "before" => next}, ctx)

    assert last.kind == "agent_ops"
  end

  test "an id past a 64-bit row id is refused at the boundary, before anything is charged", %{
    ctx: ctx
  } do
    for _ <- 1..100 do
      assert {:error, %{error: "invalid"}} =
               Account.call(
                 "account.key.change",
                 %{"id" => 1_000_000_000_000_000_000_000_000_000, "preset" => "read_only"},
                 ctx
               )
    end

    assert {:ok, _} =
             Account.call("account.key.mint", %{"name" => "k", "preset" => "read_only"}, ctx)
  end
end
