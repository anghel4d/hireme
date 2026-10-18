defmodule Hireme.AccountsTest do
  use Hireme.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Hireme.Accounts

  # The URL a mailed link carries is whatever the router makes of the token.
  defp url_for(token), do: "https://desk.example/sign-in/email?token=" <> token

  defp mailed_token(email) do
    :ok = Accounts.request_link(email, &url_for/1, %{ip: "10.0.0.1"})

    # The link leaves from a task; its mail arrives when that task has run.
    assert_receive {:email, mail}, 1_000
    {:ok, address} = Accounts.normalize_email(email)
    assert [{_, ^address}] = mail.to
    [_, token] = Regex.run(~r/token=([A-Za-z0-9_-]+)/, mail.text_body)
    token
  end

  describe "sign-in by mailed link" do
    test "proves the address once; a visitor becomes an account, and comes back to it" do
      token = mailed_token("Visitor@Example.com ")
      assert {:ok, "visitor@example.com"} = Accounts.peek_link(token)
      assert {:ok, "visitor@example.com"} = Accounts.peek_link(token), "peeking spends nothing"
      assert {:ok, email} = Accounts.redeem_link(token)
      assert {:error, :invalid} = Accounts.redeem_link(token)
      assert {:error, :invalid} = Accounts.peek_link(token)

      {:ok, cookie, session} = Accounts.sign_in_with(:email, %{subject: email, display: email})
      assert {%{id: id}, account} = Accounts.session(cookie)
      assert id == session.id
      assert account.id == session.account_id

      {:ok, _, again} = Accounts.sign_in_with(:email, %{subject: email, display: email})
      assert again.account_id == session.account_id
    end

    test "a link raced by many redeemers is spent by exactly one" do
      token = mailed_token("race@example.com")
      parent = self()

      results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Sandbox.allow(Hireme.Repo, parent, self())
            Accounts.redeem_link(token)
          end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    end

    test "a malformed address is refused and the answer never says whether an account exists" do
      assert {:error, :invalid} = Accounts.request_link("not an address", &url_for/1)
      assert :ok = Accounts.request_link("nobody@example.com", &url_for/1)
      %{email: known} = sign_in()
      assert :ok = Accounts.request_link(known, &url_for/1)
    end

    test "five links per address in the window, then a refusal" do
      for _ <- 1..5,
          do:
            assert(
              :ok =
                Accounts.request_link("busy@example.com", &url_for/1, %{
                  ip: "10.9.9.#{:rand.uniform(200)}"
                })
            )

      assert {:error, :rate_limited} =
               Accounts.request_link("busy@example.com", &url_for/1, %{ip: "10.8.8.8"})
    end
  end

  describe "sessions" do
    test "a revoked, expired or idle session is not a session" do
      %{session: s1, token: t1} = sign_in()
      assert {_, _} = Accounts.session(t1)
      assert :ok = Accounts.revoke_session(s1.account_id, s1.id)
      assert Accounts.session(t1) == nil

      %{session: s2, token: t2} = sign_in()
      age(s2, :last_seen_at, Hireme.Security.session_idle() + 1)
      assert Accounts.session(t2) == nil

      %{session: s3, token: t3} = sign_in()

      s3
      |> Ecto.Changeset.change(expires_at: DateTime.add(Hireme.Store.now(), -1))
      |> Repo.update!(skip_account: true)

      assert Accounts.session(t3) == nil

      assert Accounts.session("garbage") == nil
      assert Accounts.session(nil) == nil
    end

    test "revoking a session ends its wire sessions" do
      %{session: s} = sign_in()
      Phoenix.PubSub.subscribe(Hireme.PubSub, Hireme.Audit.topic(s.account_id))
      :ok = Accounts.revoke_session(s.account_id, s.id)
      assert_receive {:bye, {:session, id}, :revoked} when id == s.id
    end

    test "one account cannot revoke another's session" do
      %{session: mine} = sign_in()
      %{session: theirs} = sign_in()
      assert {:error, :not_found} = Accounts.revoke_session(mine.account_id, theirs.id)
    end

    test "suspension ends every session and refuses sign-in" do
      %{account: a, token: t, email: email} = sign_in()
      Phoenix.PubSub.subscribe(Hireme.PubSub, Hireme.Audit.topic(a.id))
      :ok = Accounts.set_status(a.id, :suspended)
      assert_receive {:bye, :account, :suspended}
      assert Accounts.session(t) == nil

      assert {:error, :suspended} =
               Accounts.sign_in_with(:email, %{subject: email, display: email})
    end
  end

  describe "wire tickets" do
    test "a ticket opens one wire session as its browser session, once" do
      %{session: s} = sign_in()
      ticket = Accounts.ticket(s)
      assert {:ok, %{account_id: a, session_id: id}} = Accounts.redeem_ticket(ticket)
      assert {a, id} == {s.account_id, s.id}
      assert :error = Accounts.redeem_ticket(ticket)
    end

    test "a ticket for a revoked session, or forged, opens nothing" do
      %{session: s} = sign_in()
      ticket = Accounts.ticket(s)
      :ok = Accounts.revoke_session(s.account_id, s.id)
      assert :error = Accounts.redeem_ticket(ticket)
      assert :error = Accounts.redeem_ticket(ticket <> "x")
      assert :error = Accounts.redeem_ticket(nil)
    end
  end

  describe "ways in" do
    test "linking binds a new identity, refuses one bound elsewhere, and the last cannot be unlinked" do
      %{account: a, email: email} = sign_in()
      %{email: other} = sign_in()
      Repo.put_account(a.id)

      assert {:ok, gh} = Accounts.link(:github, %{subject: "4242", display: "octo"})
      assert {:error, :taken} = Accounts.link(:email, %{subject: other, display: other})
      assert length(Accounts.identities()) == 2

      [mail] =
        Enum.filter(Accounts.identities(), &(&1.provider == :email and &1.subject == email))

      assert :ok = Accounts.unlink(mail.id)
      assert {:error, :last} = Accounts.unlink(gh.id)
      assert {:error, :not_found} = Accounts.unlink(mail.id)
    end
  end

  test "addresses normalize to one spelling and only address-shaped text passes" do
    assert {:ok, "a@b.co"} = Accounts.normalize_email("  A@B.co ")

    for bad <- [
          "",
          "a",
          "a@b",
          "@b.co",
          "a b@c.de",
          String.duplicate("a", 250) <> "@b.co",
          nil,
          7
        ],
        do: assert({:error, :invalid} = Accounts.normalize_email(bad))
  end

  test "the scope a browser keys its snapshot by is stable per account and differs between accounts" do
    assert Accounts.scope(1) == Accounts.scope(1)
    refute Accounts.scope(1) == Accounts.scope(2)
    assert Accounts.scope(1) =~ ~r/\A[0-9a-f]{32}\z/
  end

  test "a sign-in refused as suspended is on the trail" do
    %{account: a, email: email} = sign_in()
    :ok = Accounts.set_status(a.id, :suspended)
    assert {:error, :suspended} = Accounts.sign_in_with(:email, %{subject: email, display: email})
    Repo.put_account(a.id)

    assert Enum.any?(
             Hireme.Audit.recent(10),
             &(&1.kind == "sign_in_refused" and &1.meta["reason"] == "suspended")
           )
  end

  test "a session that now owes a second factor is not live, on a timer or as activity" do
    %{session: old, email: email} = sign_in()
    {:ok, _, owner} = Accounts.sign_in_with(:email, %{subject: email, display: email})
    Repo.put_account(owner.account_id)
    {:ok, %{secret: secret}} = Hireme.Mfa.begin_totp(owner, "me")
    code = secret |> Base.decode32!(padding: false) |> NimbleTOTP.verification_code()
    {:ok, _, _} = Hireme.Mfa.confirm_totp(owner, code, "phone")

    refute Accounts.session_live?(old.id)
    assert :error = Accounts.live_session(old.id)
    assert Accounts.session_live?(owner.id)
  end

  test "an account holds at most the declared number of ways in" do
    %{account: a} = sign_in()
    Repo.put_account(a.id)
    cap = Hireme.Schema.table(:identities).cap
    for i <- 2..cap, do: {:ok, _} = Accounts.link(:github, %{subject: "s#{i}", display: "s#{i}"})
    assert {:error, :cap} = Accounts.link(:github, %{subject: "one-more", display: "x"})
  end

  test "at the session cap the oldest ended sessions make room; only all-live sessions refuse" do
    %{account: a, session: first, email: email} = sign_in()
    cap = Hireme.Schema.table(:sessions).cap
    now = Hireme.Store.now()

    rows =
      for i <- 1..(cap - 1),
          do: %{
            account_id: a.id,
            token_hash: :crypto.hash(:sha256, "t#{i}"),
            authenticated_at: now,
            last_seen_at: now,
            expires_at: DateTime.add(now, 3600),
            rev: 1,
            inserted_at: now,
            updated_at: now
          }

    for chunk <- Enum.chunk_every(rows, 500),
        do: Repo.insert_all(Hireme.Rows.Session, chunk, skip_account: true)

    claim = %{subject: email, display: email}
    assert {:error, :cap} = Accounts.sign_in_with(:email, claim)
    :ok = Accounts.revoke_session(a.id, first.id)
    assert {:ok, _, _} = Accounts.sign_in_with(:email, claim)
    refute Repo.get(Hireme.Rows.Session, first.id, skip_account: true)
  end

  test "a sign-in refused at the session cap is recorded as refused, and a mailed link would keep" do
    %{account: a, email: email} = sign_in()
    cap = Hireme.Schema.table(:sessions).cap
    now = Hireme.Store.now()

    rows =
      for i <- 1..(cap - 1),
          do: %{
            account_id: a.id,
            token_hash: :crypto.hash(:sha256, "u#{i}"),
            authenticated_at: now,
            last_seen_at: now,
            expires_at: DateTime.add(now, 3600),
            rev: 1,
            inserted_at: now,
            updated_at: now
          }

    for chunk <- Enum.chunk_every(rows, 500),
        do: Repo.insert_all(Hireme.Rows.Session, chunk, skip_account: true)

    refute Accounts.room?(:email, email)
    assert Accounts.room?(:email, "stranger@example.com")
    assert {:error, :cap} = Accounts.sign_in_with(:email, %{subject: email, display: email})

    Repo.put_account(a.id)
    [last | _] = Hireme.Audit.recent(5)
    assert last.kind == "sign_in_refused" and last.meta["reason"] == "cap"
  end
end
