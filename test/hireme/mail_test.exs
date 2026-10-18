defmodule Hireme.MailTest do
  use Hireme.DataCase, async: false
  import Swoosh.TestAssertions

  alias Hireme.Mail
  alias Hireme.Rows.Outbox

  defp count(account_id, kind) do
    Repo.aggregate(
      from(n in Outbox, where: n.account_id == ^account_id and n.kind == ^kind),
      :count,
      skip_account: true
    )
  end

  test "a queued notice is sent once by a drain, one per linked address; an account is told about changes on its linked addresses" do
    %{account: a, email: email} = sign_in()
    :ok = Mail.enqueue(a.id, [email, "second@example.com"], :api_key_created, %{name: "ci"})
    assert Mail.Outbox.drain() == 2
    assert_email_sent(to: [{"", email}], subject: ~s(Hireme: an API key named "ci" was created))
    assert Mail.Outbox.drain() == 0

    :ok = Hireme.Accounts.notify(a.id, :authenticator_added, %{kind: :totp})
    assert Mail.Outbox.drain() == 1
    assert_email_sent(to: [{"", email}], subject: "Hireme: a second factor (totp) was added")
  end

  test "a notice subject is one header line whatever a name holds, and a meta naming fields no line reads still sends, without minting atoms" do
    %{account: a, email: email} = sign_in()
    :ok = Mail.enqueue(a.id, [email], :api_key_revoked, %{name: "x\r\nBcc: victim@example.com ü"})
    field = "never_an_atom_#{System.unique_integer([:positive])}"
    :ok = Mail.enqueue(a.id, [email], :recovery_code_used, %{field => 1, "left" => 3})
    assert Mail.Outbox.drain() == 2

    assert_email_sent(fn mail ->
      refute mail.subject =~ ~r/[\r\n]/
      mail.subject =~ "=?utf-8?B?" or mail.subject == "Hireme: a recovery code was used; 3 left"
    end)

    assert_email_sent(subject: "Hireme: a recovery code was used; 3 left")
    assert_raise ArgumentError, fn -> String.to_existing_atom(field) end
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

    Repo.insert_all(Outbox, rows, skip_account: true)
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
  test "past the notice budget, changes coalesce into one pending digest per address; a digest the drain has taken up or given up on is never added to" do
    %{account: a, email: email} = sign_in()
    for i <- 1..35, do: :ok = Mail.enqueue(a.id, [email], :api_key_renamed, %{name: "k#{i}"})
    assert count(a.id, "api_key_renamed") == 30

    [digest] =
      Repo.all(from(n in Outbox, where: n.account_id == ^a.id and n.kind == "digest"),
        skip_account: true
      )

    assert digest.meta["count"] == 5
    assert DateTime.compare(digest.next_at, Hireme.Store.now()) == :gt

    digest |> Ecto.Changeset.change(attempts: 8) |> Repo.update!(skip_account: true)
    :ok = Mail.enqueue(a.id, [email], :api_key_renamed, %{name: "later"})
    assert count(a.id, "digest") == 2

    assert Mail.line(:digest, %{count: 1, since: "2026-10-18T10:00:00Z"}) =~
             "1 security change since 2026-10-18 10:00:00 UTC"
  end

  @tag window: [:notices, :factor_notices, :key_notices, :notice_rows]
  test "one event is one charge however many addresses hear of it; a key's revoke and a factor's notices reach the owner as themselves past the general budget" do
    %{account: a, email: email} = sign_in()
    many = for i <- 1..40, do: "addr#{i}@example.com"
    :ok = Mail.enqueue(a.id, many, :api_key_renamed, %{name: "k"})
    assert count(a.id, "api_key_renamed") == 40
    for i <- 1..29, do: :ok = Mail.enqueue(a.id, [email], :api_key_renamed, %{name: "k#{i}"})
    :ok = Mail.enqueue(a.id, [email], :api_key_renamed, %{name: "past"})
    assert count(a.id, "digest") == 1

    :ok = Mail.enqueue(a.id, [email], :api_key_revoked, %{name: "leaked"})
    :ok = Mail.enqueue(a.id, [email], :authenticator_added, %{kind: :totp})
    :ok = Mail.enqueue(a.id, [email], :authenticator_removed, %{kind: :totp})

    for kind <- ~w(api_key_revoked authenticator_added authenticator_removed),
        do: assert(count(a.id, kind) == 1, kind)
  end

  @tag window: [:notices, :factor_notices, :key_notices, :notice_rows]
  test "a flood of key notices never turns a factor's notice into a digest" do
    %{account: a, email: email} = sign_in()
    for i <- 1..30, do: :ok = Mail.enqueue(a.id, [email], :api_key_renamed, %{name: "k#{i}"})
    for i <- 1..15, do: :ok = Mail.enqueue(a.id, [email], :api_key_created, %{name: "n#{i}"})
    :ok = Mail.enqueue(a.id, [email], :authenticator_added, %{kind: :totp})
    assert count(a.id, "api_key_created") == 10
    assert count(a.id, "authenticator_added") == 1
  end

  @tag window: [:notices, :notice_rows]
  test "an account's outbox holds no more than its declared cap" do
    %{account: a} = sign_in()
    cap = Hireme.Schema.table("outbox").cap
    now = Hireme.Store.now()

    sent = fn _ ->
      %{
        account_id: a.id,
        address: "old@example.com",
        kind: "api_key_renamed",
        meta: %{},
        attempts: 1,
        next_at: now,
        sent_at: now,
        rev: 1,
        inserted_at: now,
        updated_at: now
      }
    end

    for chunk <- Enum.chunk_every(1..(cap - 2), 3_000),
        do: Repo.insert_all(Outbox, Enum.map(chunk, sent), skip_account: true)

    # One digest already pending for a@, which leaves room for one row.
    :ok = Mail.enqueue(a.id, ["a@example.com"], :api_key_renamed, %{name: "k"})

    Repo.update_all(
      from(n in Outbox, where: n.address == "a@example.com"),
      [set: [kind: "digest", meta: %{count: 1}, next_at: DateTime.add(now, 600)]],
      skip_account: true
    )

    held = fn ->
      Repo.aggregate(from(n in Outbox, where: n.account_id == ^a.id), :count, skip_account: true)
    end

    assert held.() == cap - 1

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok =
          Mail.enqueue(a.id, ~w(a@example.com b@example.com c@example.com), :api_key_renamed, %{
            name: "k2"
          })
      end)

    assert log =~ "the outbox is at its cap"
    assert held.() == cap - 1
    [digest] = Repo.all(from(n in Outbox, where: n.address == "a@example.com"), skip_account: true)
    assert digest.meta["count"] == 2
  end

  @tag window: [:notices, :notice_rows]
  test "notice rows are bounded per account however many addresses an account links" do
    %{account: a} = sign_in()
    many = for i <- 1..100, do: "a#{i}@example.com"
    for _ <- 1..4, do: :ok = Mail.enqueue(a.id, many, :api_key_renamed, %{name: "k"})
    assert count(a.id, "api_key_renamed") == 300
    assert count(a.id, "digest") == 100
  end
end
