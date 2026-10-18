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
    :ok = Mail.enqueue(busy.id, List.duplicate(busy_email, 120), :api_key_created, %{name: "x"})
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
end
