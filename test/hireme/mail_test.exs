defmodule Hireme.MailTest do
  use Hireme.DataCase, async: false
  import Swoosh.TestAssertions

  alias Hireme.Mail

  test "a queued notice is sent once by a drain, one per linked address" do
    %{account: a, email: email} = sign_in()
    :ok = Mail.enqueue(a.id, [email, "second@example.com"], :api_key_created, %{name: "ci"})

    assert Mail.Outbox.drain() == 2
    assert_email_sent(to: [{"", email}], subject: ~s(Hireme: an API key named "ci" was created))
    assert Mail.Outbox.drain() == 0
  end

  test "a notice subject is one header line whatever a name holds" do
    %{account: a, email: email} = sign_in()
    :ok = Mail.enqueue(a.id, [email], :api_key_revoked, %{name: "x\r\nBcc: victim@example.com ü"})
    assert Mail.Outbox.drain() == 1

    assert_email_sent(fn mail ->
      refute mail.subject =~ ~r/[\r\n]/
      assert mail.subject =~ "=?utf-8?B?"
    end)
  end

  test "a notice whose meta names fields no line reads still sends, without minting atoms" do
    %{account: a, email: email} = sign_in()
    field = "never_an_atom_#{System.unique_integer([:positive])}"
    :ok = Mail.enqueue(a.id, [email], :recovery_code_used, %{field => 1, "left" => 3})
    assert Mail.Outbox.drain() == 1
    assert_email_sent(subject: "Hireme: a recovery code was used; 3 left")
    assert_raise ArgumentError, fn -> String.to_existing_atom(field) end
  end

  test "an account is told about changes on its linked addresses" do
    %{account: a, email: email} = sign_in()
    :ok = Hireme.Accounts.notify(a.id, :authenticator_added, %{kind: :totp})
    assert Mail.Outbox.drain() == 1
    assert_email_sent(to: [{"", email}], subject: "Hireme: a second factor (totp) was added")
  end

  test "the outbox sends round-robin: one account's backlog does not hold back another's" do
    %{account: busy, email: busy_email} = sign_in()
    %{account: other, email: other_email} = sign_in()
    # A backlog from earlier windows, as rows: the budget bounds each window.
    now = Hireme.Store.now()

    rows =
      for _ <- 1..120,
          do: %{
            account_id: busy.id,
            address: busy_email,
            kind: "api_key_created",
            meta: %{name: "x"},
            attempts: 0,
            next_at: now,
            rev: 1,
            inserted_at: now,
            updated_at: now
          }

    Repo.insert_all(Hireme.Rows.Outbox, rows, skip_account: true)
    :ok = Mail.enqueue(other.id, [other_email], :api_key_created, %{name: "y"})

    assert Mail.Outbox.drain() == 121

    order =
      for _ <- 1..121 do
        assert_receive {:email, mail}
        [{_, to}] = mail.to
        to
      end

    assert Enum.find_index(order, &(&1 == other_email)) < 2
  end

  @tag window: [:notices, :notice_rows]
  test "past the notice budget, changes coalesce into one pending digest per address" do
    %{account: a, email: email} = sign_in()
    for i <- 1..35, do: :ok = Mail.enqueue(a.id, [email], :api_key_renamed, %{name: "k#{i}"})

    rows =
      Repo.all(from(n in Hireme.Rows.Outbox, where: n.account_id == ^a.id), skip_account: true)

    assert Enum.count(rows, &(&1.kind == "api_key_renamed")) == 30
    assert [digest] = Enum.filter(rows, &(&1.kind == "digest"))
    assert digest.meta["count"] == 5
    assert DateTime.compare(digest.next_at, Hireme.Store.now()) == :gt
  end

  @tag window: [:notices, :critical_notices, :notice_rows]
  test "one event is one charge however many addresses hear of it; critical kinds keep their own budget" do
    %{account: a, email: email} = sign_in()
    many = for i <- 1..40, do: "addr#{i}@example.com"
    :ok = Mail.enqueue(a.id, many, :api_key_renamed, %{name: "k"})

    rows = fn kind ->
      Repo.aggregate(
        from(n in Hireme.Rows.Outbox, where: n.account_id == ^a.id and n.kind == ^kind),
        :count,
        skip_account: true
      )
    end

    assert rows.("api_key_renamed") == 40
    for i <- 1..29, do: :ok = Mail.enqueue(a.id, [email], :api_key_renamed, %{name: "k#{i}"})
    :ok = Mail.enqueue(a.id, [email], :api_key_renamed, %{name: "past"})
    assert rows.("digest") == 1

    :ok = Mail.enqueue(a.id, [email], :authenticator_removed, %{kind: :totp})
    assert rows.("authenticator_removed") == 1
  end

  @tag window: [:notices, :notice_rows]
  test "a digest the drain has taken up or given up on is never added to" do
    %{account: a, email: email} = sign_in()
    for i <- 1..31, do: :ok = Mail.enqueue(a.id, [email], :api_key_renamed, %{name: "k#{i}"})
    [d] = Repo.all(from(n in Hireme.Rows.Outbox, where: n.kind == "digest"), skip_account: true)
    d |> Ecto.Changeset.change(attempts: 8) |> Repo.update!(skip_account: true)
    :ok = Mail.enqueue(a.id, [email], :api_key_renamed, %{name: "later"})

    assert Repo.aggregate(from(n in Hireme.Rows.Outbox, where: n.kind == "digest"), :count,
             skip_account: true
           ) == 2

    assert Mail.line(:digest, %{count: 1, since: "2026-10-18T10:00:00Z"}) =~
             "1 security change since 2026-10-18 10:00:00 UTC"
  end

  @tag window: [:notices, :critical_notices]
  test "a key's revoke notice and the critical kinds reach the owner as themselves past the general budget" do
    %{account: a, email: email} = sign_in()
    for i <- 1..30, do: :ok = Mail.enqueue(a.id, [email], :api_key_renamed, %{name: "k#{i}"})
    :ok = Mail.enqueue(a.id, [email], :api_key_revoked, %{name: "leaked"})
    :ok = Mail.enqueue(a.id, [email], :authenticator_added, %{kind: :totp})

    kinds =
      Repo.all(from(n in Hireme.Rows.Outbox, where: n.account_id == ^a.id, select: n.kind),
        skip_account: true
      )

    assert "api_key_revoked" in kinds and "authenticator_added" in kinds
  end

  @tag window: [:notices, :notice_rows]
  test "notice rows are bounded per account however many addresses an account links" do
    %{account: a} = sign_in()
    many = for i <- 1..100, do: "a#{i}@example.com"
    for _ <- 1..4, do: :ok = Mail.enqueue(a.id, many, :api_key_renamed, %{name: "k"})

    count = fn kind ->
      Repo.aggregate(
        from(n in Hireme.Rows.Outbox, where: n.account_id == ^a.id and n.kind == ^kind),
        :count,
        skip_account: true
      )
    end

    assert count.("api_key_renamed") == 300
    assert count.("digest") == 100
  end
end
