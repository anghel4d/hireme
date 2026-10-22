defmodule Hireme.GmailTest do
  # The Gmail link's two protocols against a local fake Gmail
  # (`Hireme.FakeGmail`, TLS under its own CA, verified as Gmail is), never
  # a real mailbox: what the IMAP side reads, labels and searches, and
  # what the SMTP side delivers, round-tripped through the MIME parser.
  use ExUnit.Case, async: true

  alias Hireme.FakeGmail
  alias Hireme.Gmail.{Imap, Mime, Smtp}

  @user "someone@gmail.com"
  @password "abcdefghijklmnop"

  setup do
    {:ok, fake} = FakeGmail.start(all_mail: "[Gmail]/Alle Nachrichten")
    on_exit(fn -> FakeGmail.stop(fake) end)
    %{fake: fake}
  end

  defp imap(fake) do
    {:ok, conn} = Imap.connect("localhost", fake.imap_port, fake.cacerts)
    {:ok, conn} = Imap.login(conn, @user, @password)
    {:ok, %{all: folder}, conn} = Imap.folders(conn)
    {:ok, info, conn} = Imap.select(conn, folder)
    {conn, folder, info}
  end

  defp smtp(fake), do: %{host: "localhost", port: fake.smtp_port, cacerts: fake.cacerts}

  defp mail(n, extra \\ "") do
    "From: Recruiter #{n} <r#{n}@acme.example>\r\nTo: #{@user}\r\nSubject: Interview #{n}\r\n" <>
      "Date: Thu, 22 Oct 2026 09:0#{n}:00 +0000\r\nMessage-ID: <m#{n}@acme.example>\r\n" <>
      extra <> "\r\nHello #{n}.\r\n"
  end

  test "All Mail is found by its flag, whatever it is called, and read by UID without marking anything seen",
       %{fake: fake} do
    uids = for n <- 1..3, do: FakeGmail.deliver(fake, mail(n))
    {conn, folder, info} = imap(fake)

    assert folder == "[Gmail]/Alle Nachrichten"
    assert info.exists == 3 and is_integer(info.uidvalidity)

    assert {:ok, ^uids, conn} = Imap.since_date(conn, Date.add(Date.utc_today(), -1))
    assert {:ok, [_, _] = later, conn} = Imap.since_uid(conn, Enum.at(uids, 1))
    assert later == Enum.drop(uids, 1)
    # Past the highest UID, `n:*` still names it; the client answers none.
    assert {:ok, [], conn} = Imap.since_uid(conn, List.last(uids) + 1)

    assert {:ok, envelopes, conn} = Imap.envelopes(conn, uids)
    held = Map.new(FakeGmail.messages(fake), &{&1.uid, &1})

    for e <- envelopes do
      assert e.msgid == held[e.uid].msgid and e.thrid == held[e.uid].thrid
      assert "\\Inbox" in e.labels and e.size == byte_size(held[e.uid].raw)
      assert {:ok, %{subject: "Interview " <> _, text: ""}} = Mime.parse(e.header)
    end

    [first, second, third] = uids
    assert {:ok, %{raw: raw}, conn} = Imap.message(conn, second)
    assert raw == held[second].raw

    assert {:ok, conn} = Imap.label(conn, [first, third], "hireme")
    labelled = for m <- FakeGmail.messages(fake), "hireme" in m.labels, do: m.uid
    assert Enum.sort(labelled) == [first, third]
    refute Enum.any?(FakeGmail.messages(fake), &("\\Seen" in Map.get(&1, :flags, [])))

    assert {:ok, [^second], conn} = Imap.message_id(conn, "m2@acme.example")
    # An id Gmail's search syntax cannot carry finds nothing, asked nothing.
    assert {:ok, [], conn} = Imap.message_id(conn, ~s(a" OR "b@x))
    Imap.logout(conn)
  end

  test "a refused login says why, and the connection is closed", %{fake: fake} do
    {:ok, conn} = Imap.connect("localhost", fake.imap_port, fake.cacerts)
    assert {:error, :auth} = Imap.login(conn, @user, "wrong-password-xx")

    FakeGmail.fail(fake, :imap_disabled)
    {:ok, conn} = Imap.connect("localhost", fake.imap_port, fake.cacerts)
    assert {:error, :imap_disabled} = Imap.login(conn, @user, @password)

    FakeGmail.heal(fake)
    {:ok, conn} = Imap.connect("localhost", fake.imap_port, fake.cacerts)
    assert {:ok, _} = Imap.login(conn, @user, @password)
    # Only the fake's own CA is trusted here: the system store refuses it.
    assert {:error, {:network, _}} = Imap.connect("localhost", fake.imap_port, :system)
  end

  test "IDLE hears new mail at once, and DONE gives the connection back", %{fake: fake} do
    {conn, _folder, _info} = imap(fake)
    assert {:ok, [], conn} = Imap.idle(conn)

    uid = FakeGmail.deliver(fake, mail(4))
    socket = conn.socket
    assert_receive {:ssl, ^socket, data}, 5_000
    {:ok, pushed, conn} = Imap.idle_data(conn, data)
    assert {:exists, 1} in pushed

    assert {:ok, _, conn} = Imap.done(conn)
    assert {:ok, [^uid], _} = Imap.since_uid(conn, uid)
  end

  test "what is composed and delivered reads back the same from Gmail's Sent", %{fake: fake} do
    seed = String.to_integer(System.get_env("GMAIL_SEED") || "#{:rand.uniform(1_000_000)}")
    :rand.seed(:exsss, {seed, 7, 11})

    for i <- 1..25 do
      body =
        Enum.map_join(1..:rand.uniform(6), "\n", fn _ ->
          Enum.random([
            ".a line that starts with a dot",
            String.duplicate("long ", 40),
            "trailing space ",
            "naïve façade — “quoted” ✓",
            "",
            "=3D and =\tsoft"
          ])
        end)

      mail = %{
        from: @user,
        from_name: Enum.random([nil, "Ada Lovelace", ~s(O"Brien, Pat), "Zoë Ångström"]),
        to: ["jobs#{i}@acme.example"],
        cc: Enum.take(["hr@acme.example", "cto@acme.example"], :rand.uniform(3) - 1),
        subject:
          Enum.random(["Application: Staff Engineer", "Bewerbung – Übersetzung", "応募 #{i}"]),
        body: body,
        message_id: "hm.t#{i}x#{seed}@gmail.com",
        in_reply_to: if(rem(i, 2) == 0, do: "m1@acme.example"),
        refs: if(rem(i, 2) == 0, do: ["m0@acme.example", "m1@acme.example"], else: []),
        date: 1_792_000_000 + i,
        attachments:
          if(rem(i, 3) == 0,
            do: [
              %{
                name: "CV Ada Lovelace é.pdf",
                type: "application/pdf",
                data: :crypto.strong_rand_bytes(3000 + i)
              }
            ],
            else: []
          )
      }

      assert {:ok, _} =
               Smtp.deliver(
                 smtp(fake),
                 @user,
                 @password,
                 @user,
                 mail.to ++ mail.cc,
                 Smtp.compose(mail)
               ),
             "seed #{seed}, mail #{i}"

      sent = List.last(FakeGmail.sent(fake))
      assert sent.rcpts == mail.to ++ mail.cc
      {:ok, got} = Mime.parse(sent.raw)

      assert got.subject == mail.subject, "seed #{seed}, mail #{i}"
      assert lines(got.text) == lines(mail.body), "seed #{seed}, mail #{i}"
      assert got.message_id == mail.message_id and got.in_reply_to == mail.in_reply_to
      assert got.refs == mail.refs
      assert Enum.map(got.to ++ got.cc, & &1.addr) == mail.to ++ mail.cc
      assert got.from.addr == @user and got.from.name == mail.from_name
      assert got.date == mail.date

      assert Enum.map(got.attachments, &{&1.name, &1.type, &1.size}) ==
               Enum.map(mail.attachments, &{&1.name, &1.type, byte_size(&1.data)})
    end

    # Gmail files what it accepts in Sent: the client finds it by its id.
    {conn, _folder, _info} = imap(fake)
    assert {:ok, [_], _} = Imap.message_id(conn, "hm.t25x#{seed}@gmail.com")
  end

  defp lines(text), do: text |> String.replace("\r\n", "\n") |> String.trim()

  test "a delivery that fails says how, and one cut off after DATA may still be in Sent", %{
    fake: fake
  } do
    data =
      Smtp.compose(%{
        from: @user,
        to: ["jobs@acme.example"],
        subject: "S",
        body: "B",
        message_id: "hm.f@gmail.com",
        date: 1_792_000_000
      })

    send = fn ->
      Smtp.deliver(smtp(fake), @user, @password, @user, ["jobs@acme.example"], data)
    end

    assert {:error, :auth} =
             Smtp.deliver(
               smtp(fake),
               @user,
               "wrong-password-xx",
               @user,
               ["jobs@acme.example"],
               data
             )

    FakeGmail.fail(fake, {:smtp_reply, "421 4.7.0 Try again later, closing connection."})
    assert {:error, {:temporary, "421 " <> _}} = send.()

    FakeGmail.fail(fake, {:smtp_reply, "550 5.4.5 Daily user sending limit exceeded."})
    assert {:error, {:permanent, "550 " <> _}} = send.()

    FakeGmail.heal(fake)
    FakeGmail.fail(fake, :smtp_drop_after_data)
    assert {:error, {:network, _}} = send.()
    assert Enum.any?(FakeGmail.messages(fake), &(&1.message_id == "hm.f@gmail.com"))

    FakeGmail.heal(fake)
    FakeGmail.down(fake)
    assert {:error, {:network, _}} = send.()
    FakeGmail.up(fake)
    assert {:ok, _} = send.()

    assert {:error, {:permanent, _}} =
             Smtp.deliver(
               smtp(fake),
               @user,
               @password,
               @user,
               Enum.map(1..11, &"r#{&1}@acme.example"),
               data
             )
  end
end

defmodule Hireme.GmailSessionTest do
  # The connector end to end on a node, against the fake Gmail: linking
  # (one login, the password sealed), the session's first sync, and a shot
  # fired under the operator's key going out once, with crash safety: a
  # send cut off after Gmail took it is found in All Mail, never resent.
  use Hireme.WireCase, async: false

  alias Hireme.{FakeGmail, Gmail}
  alias Hireme.Gmail.{Mime, Session}
  alias Hireme.Rows.Application, as: AppRow
  alias Hireme.Rows.{Mailbox, Mission, Outreach}

  @user "someone@gmail.com"
  @password "abcd efgh ijkl mnop"

  setup %{account: a, session: session} do
    {:ok, fake} = FakeGmail.start(password: String.replace(@password, " ", ""))
    before = Application.get_env(:hireme, Gmail)

    Application.put_env(:hireme, Gmail,
      imap: {"localhost", fake.imap_port},
      smtp: {"localhost", fake.smtp_port},
      cacerts: fake.cacerts
    )

    on_exit(fn ->
      Session.stop(a.id)
      FakeGmail.stop(fake)

      if before,
        do: Application.put_env(:hireme, Gmail, before),
        else: Application.delete_env(:hireme, Gmail)
    end)

    # The operator's browser session, stepped up as the key's creation asks.
    operator = %{label: "page", grants: Grants.operator(), key_id: nil, session_id: session.id}
    %{fake: fake, operator: operator}
  end

  defp read(fun), do: Repo.with_account(Process.get(:account), fun)

  # An application at fire_ready with one email follow-up mission (a reply
  # in a thread goes without a CV file), and a key covering it.
  defp armed(a, operator) do
    Process.put(:account, a.id)
    {[%{id: batch}], []} = run(a.id, op(:put, :batches, %{code: "b1", ordinal: 1}))

    {[%{id: app}], []} =
      run(a.id, app(%{company: "Acme", role: "Staff Engineer", batch_id: batch}))

    {[_], []} = run(a.id, op(:command, :stage, %{stage: :fire_ready}, target: app))

    {[%{id: mission}], []} =
      run(
        a.id,
        op(:put, :missions, %{
          application_id: app,
          kind: :email,
          target: "jobs@acme.example",
          subject: "Re: Staff Engineer",
          draft: "Thank you, Thursday works.\n.\nBest",
          in_reply_to: "m0@acme.example",
          state: :fire_ready
        })
      )

    {:ok, review} = Gmail.query(a.id, "fire_review", %{"missions" => "#{mission}"})
    assert review["scope"] == "#{mission}", inspect(review)

    {[%{id: key}], []} =
      run(
        a.id,
        op(:command, :create_fire_key, %{missions: review["scope"], digest: review["digest"]}),
        operator
      )

    {app, mission, key}
  end

  test "linking checks the password with one login, seals it, and the first sync makes the mailbox live",
       %{account: a, fake: fake} do
    assert {:error, :address} = Gmail.link(a.id, "someone@example.com", @password)
    assert {:error, :auth} = Gmail.link(a.id, @user, "wrong password here")
    assert read_box(a) == nil

    # Mail older than the backfill's window is never read; the session idles past it.
    old = DateTime.add(DateTime.utc_now(), -200 * 86_400)

    FakeGmail.deliver(
      fake,
      "From: x@acme.example\r\nSubject: Old\r\nMessage-ID: <old@acme.example>\r\n\r\nOld.\r\n",
      ["\\Inbox"],
      date: old
    )

    assert {:ok, %{status: "linking"}} = Gmail.link(a.id, @user, @password)
    box = read_box(a)
    assert box.address == @user and is_binary(box.secret)
    refute box.secret =~ "abcdefghijklmnop"
    assert eventually(fn -> read_box(a).status == :live end)
    assert [%{ok: false}, %{ok: true}, %{ok: true} | _] = FakeGmail.logins(fake)

    [{pid, _}] = Registry.lookup(Hireme.Gmail.Registry, a.id)

    assert eventually(fn ->
             match?(%{imap: %{idle: tag}} when tag != nil, :sys.get_state(pid))
           end)

    assert %{last_uid: 1} = :sys.get_state(pid)
    assert Repo.with_account(a.id, fn -> Repo.all(Outreach) end) == []
  end

  defp read_box(a), do: Repo.with_account(a.id, fn -> Repo.one(Mailbox) end)

  test "a shot under a key goes out once from the linked address and lands", %{
    account: a,
    fake: fake,
    operator: operator
  } do
    {:ok, _} = Gmail.link(a.id, @user, @password)
    assert eventually(fn -> read_box(a).status == :live end)
    {app, mission, key} = armed(a, operator)

    {[_], []} = run(a.id, op(:command, :fire, %{key: key}, target: mission), operator)

    assert eventually(fn -> read(fn -> Repo.get(Mission, mission) end).state == :fired end)
    landed = read(fn -> Repo.get(Mission, mission) end)

    assert landed.message_id =~ ~r/\Ahm\.[a-z2-7]+@gmail\.com\z/
    assert is_integer(landed.gmail_msgid) and is_integer(landed.gmail_thrid)
    assert read(fn -> Repo.get(AppRow, app) end).stage == :submitted

    assert [sent] = FakeGmail.sent(fake)
    assert sent.from == @user and sent.rcpts == ["jobs@acme.example"]
    {:ok, mail} = Mime.parse(sent.raw)
    assert mail.message_id == landed.message_id and mail.in_reply_to == "m0@acme.example"
    assert mail.text =~ "Thursday works" and mail.attachments == []
  end

  test "a send cut off after Gmail took it is found in All Mail and never sent twice",
       %{account: a, fake: fake, operator: operator} do
    {:ok, _} = Gmail.link(a.id, @user, @password)
    assert eventually(fn -> read_box(a).status == :live end)
    {_app, mission, key} = armed(a, operator)

    FakeGmail.fail(fake, :smtp_drop_after_data)
    {[_], []} = run(a.id, op(:command, :fire, %{key: key}, target: mission), operator)
    assert eventually(fn -> FakeGmail.messages(fake) |> Enum.any?(&("\\Sent" in &1.labels)) end)

    FakeGmail.heal(fake)
    [{pid, _}] = Registry.lookup(Hireme.Gmail.Registry, a.id)
    send(pid, :retry)

    assert eventually(fn -> read(fn -> Repo.get(Mission, mission) end).state == :fired end)
    landed = read(fn -> Repo.get(Mission, mission) end)

    assert landed.gmail_msgid
    assert length(FakeGmail.sent(fake)) == 1
  end

  defp fired(a, fake, operator) do
    {:ok, _} = Gmail.link(a.id, @user, @password)
    assert eventually(fn -> read_box(a).status == :live end)
    {_app, mission, key} = armed(a, operator)
    {[_], []} = run(a.id, op(:command, :fire, %{key: key}, target: mission), operator)
    assert eventually(fn -> read(fn -> Repo.get(Mission, mission) end).state == :fired end)
    {read(fn -> Repo.get(Mission, mission) end), fake}
  end

  defp reply(to_id, n) do
    "From: Dana Reyes <dana@acme.example>\r\nTo: #{@user}\r\nSubject: Re: Staff Engineer\r\n" <>
      "Date: Thu, 22 Oct 2026 10:0#{n}:00 +0000\r\nMessage-ID: <r#{n}@acme.example>\r\n" <>
      "In-Reply-To: <#{to_id}>\r\nReferences: <m0@acme.example> <#{to_id}>\r\n\r\nThursday at ten, then.\r\n"
  end

  defp items(_a), do: read(fn -> Repo.all(Outreach) end)

  # The judge keeps a Message-ID as written, brackets and all.
  defp id?(%{message_id: m}, id), do: m != nil and String.trim(m, "<") |> String.trim(">") == id

  test "a reply to a sent shot is filed to its mission and labelled; other mail is read and dropped",
       %{account: a, fake: fake, operator: operator} do
    {mission, fake} = fired(a, fake, operator)

    news =
      "From: Deals <news@shop.example>\r\nTo: #{@user}\r\nSubject: 50% off\r\n" <>
        "Message-ID: <n1@shop.example>\r\n\r\nBuy now.\r\n"

    FakeGmail.deliver(fake, news)
    FakeGmail.deliver(fake, reply(mission.message_id, 1))

    assert eventually(fn -> Enum.any?(items(a), &id?(&1, "r1@acme.example")) end)
    got = Enum.find(items(a), &id?(&1, "r1@acme.example"))
    assert got.direction == :inbound and got.mission_id == mission.id and got.filing == :filed
    assert got.from_addr == "dana@acme.example" and got.body =~ "Thursday at ten"

    # The sent mail's record is landed's; Gmail's copy of it only adds what it lacked.
    sent = Enum.filter(items(a), &id?(&1, mission.message_id))
    assert [%{direction: :outbound}] = sent

    labelled = fn id ->
      Enum.any?(FakeGmail.messages(fake), &(&1.message_id == id and "hireme" in &1.labels))
    end

    assert eventually(fn -> labelled.("r1@acme.example") and labelled.(mission.message_id) end)
    refute labelled.("n1@shop.example")
    refute Enum.any?(items(a), &id?(&1, "n1@shop.example"))
  end

  test "the domain pipe's copy and Gmail's are one row, Gmail's adding its ids",
       %{account: a, fake: fake, operator: operator} do
    {mission, fake} = fired(a, fake, operator)
    raw = reply(mission.message_id, 2)

    assert {:ok, :stored} = Gmail.ingest(a.id, raw, :domain)
    assert {:ok, :duplicate} = Gmail.ingest(a.id, raw, :domain)
    FakeGmail.deliver(fake, raw)

    assert eventually(fn ->
             match?(
               [%{gmail_msgid: id}] when is_integer(id),
               Enum.filter(items(a), &id?(&1, "r2@acme.example"))
             )
           end)

    assert [%{pipe: :domain, mission_id: m}] =
             Enum.filter(items(a), &id?(&1, "r2@acme.example"))

    assert m == mission.id
  end

  defp labels(%{labels: nil}), do: []
  defp labels(%{labels: l}), do: String.split(l, <<0x1F>>)

  test "a reply Gmail filed as spam is kept, marked and labelled, never moved; rescued, the mark goes",
       %{account: a, fake: fake, operator: operator} do
    {mission, fake} = fired(a, fake, operator)
    raw = reply(mission.message_id, 3)

    FakeGmail.deliver(fake, raw, ["\\Spam"])
    # Gmail pushes nothing for Spam to an IDLE on All Mail; the next cycle reads it.
    [{pid, _}] = Registry.lookup(Hireme.Gmail.Registry, a.id)
    send(pid, :wake)

    assert eventually(fn -> Enum.any?(items(a), &id?(&1, "r3@acme.example")) end)
    row = Enum.find(items(a), &id?(&1, "r3@acme.example"))
    assert "\\Spam" in labels(row) and row.mission_id == mission.id

    in_gmail = fn ->
      Enum.find(FakeGmail.messages(fake), &(&1.message_id == "r3@acme.example"))
    end

    assert eventually(fn -> "hireme" in in_gmail.().labels end)
    assert "\\Spam" in in_gmail.().labels

    # The operator rescues it in Gmail: it reaches All Mail, and the mark goes.
    FakeGmail.deliver(fake, raw)

    assert eventually(fn ->
             row = Enum.find(items(a), &id?(&1, "r3@acme.example"))
             "\\Spam" not in labels(row)
           end)

    assert [_] = Enum.filter(items(a), &id?(&1, "r3@acme.example"))
  end
end
