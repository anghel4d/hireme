defmodule Hireme.OutreachTest do
  # The OutreachItem on the node: a struct per kind, decoded from a row and
  # lowered to the put the sequencer takes; the kernel judges the put
  # (docs/mail/outreach_type.md).
  use Hireme.WireCase, async: false

  import Hireme.Outreach, only: [is_email: 1, is_inbound: 1, is_kind: 2, is_email_mission: 1]
  alias Hireme.Outreach
  alias Hireme.Outreach.{Email, LinkedIn, Note}
  alias Hireme.Rows

  # The node's connector and the domain pipe: a writer with the mail bit and no key.
  defp mail_actor do
    bit = Schema.domain_bit(:mail)

    %{
      label: "gmail",
      grants: %Grants{actor: :key, key_id: nil, read_mask: bit, write_mask: bit},
      key_id: nil
    }
  end

  # A key writes under a lease: a subscribed agent session holding the channel.
  defp agent(account_id, session) do
    {:ok, %{key: key}} = Hireme.Keys.mint(session, "agent", Hireme.Keys.preset(:read_write))
    {pid, _} = key_session(account_id, key, 940)
    pid
  end

  defp parsed(message_id, extra) do
    Map.merge(
      %{
        message_id: message_id,
        from: "Dana Reyes <dana@acme.example>",
        to: ["matei3d@gmail.com"],
        subject: "Re: Staff Engineer",
        text: "Thanks for applying, when can you talk?",
        date: ~U[2026-10-22 09:40:12Z],
        gmail_msgid: 1234,
        gmail_thrid: 1200,
        labels: ["hireme"],
        pipe: :gmail,
        headers: %{"list-id" => nil}
      },
      extra
    )
  end

  test "an inbound mail from the mail actor lands received and unfiled, keyed by its Message-ID, and reads back as an Email",
       %{account: a} do
    item =
      Email.inbound(
        parsed("<a1@acme.example>", %{in_reply_to: "<hm.1@gmail.com>", refs: "<hm.1@gmail.com>"})
      )

    assert %Email{direction: :inbound, to: ["matei3d@gmail.com"], refs: ["<hm.1@gmail.com>"]} =
             item

    assert Outreach.cells(item)["from_addr"] == "Dana Reyes <dana@acme.example>"
    refute Map.has_key?(Outreach.cells(item), "actor")

    {[ack], []} = run(a.id, Outreach.op(item), mail_actor())
    row = Repo.get!(Rows.Outreach, ack.id)
    assert %Email{} = e = Outreach.from_row(row)
    assert is_email(e) and is_inbound(e) and is_kind(e, :email)
    assert {e.actor, e.filing, e.seen, Outreach.status(e)} == {:mail, :unfiled, false, :received}

    assert {e.from, e.thread_key, e.pipe, e.gmail_thrid} ==
             {"dana@acme.example", "<hm.1@gmail.com>", :gmail, 1200}

    assert e.at == ~U[2026-10-22 09:40:12Z]
    assert Email.recipients(e) == ["matei3d@gmail.com"]

    # The second pipe's copy of the same mail, however it spells the id, updates the row.
    copy = Email.inbound(parsed("  a1@acme.example ", %{pipe: :domain, labels: nil}))
    {[ack2], []} = run(a.id, Outreach.op(copy), mail_actor())
    assert ack2.id == ack.id and ack2.rev == 2
    assert Repo.aggregate(Rows.Outreach, :count) == 1
    assert Repo.get!(Rows.Outreach, ack.id).pipe == :domain

    # The row as a find answers it decodes the same way.
    assert %Email{from: "dana@acme.example"} =
             Outreach.from_row(%{
               "kind" => "email",
               "from_addr" => "dana@acme.example",
               "direction" => "inbound"
             })
  end

  test "a note is the operator's; an agent's LinkedIn act needs its report and files to its mission with the refs it implies",
       %{account: a, session: s} do
    {[app], []} = run(a.id, app(%{company: "Acme", role: "Staff Engineer"}))

    {[mission], []} =
      run(
        a.id,
        op(:put, :missions, %{
          application_id: app.id,
          kind: :linkedin,
          target: "https://www.linkedin.com/in/danareyes"
        })
      )

    corp = Process.get({Hireme.WireCase, :corp})
    note = %Note{body: "Saw the CTO post about hiring", corporation_id: corp}
    {[n], []} = run(a.id, Outreach.op(note))

    assert %Note{actor: :operator, filing: :filed, filed_by: :operator, direction: nil} =
             Outreach.from_row(Repo.get!(Rows.Outreach, n.id))

    assert Outreach.status(note) == nil

    act = %LinkedIn{
      direction: :outbound,
      handle: "danareyes",
      body: "Hi Dana, about the Staff role",
      mission_id: mission.id,
      link: "https://www.linkedin.com/messaging/thread/1"
    }

    agent = agent(a.id, s)
    assert {[], [%{refusal: :type} = nack]} = key_session_ops(agent, Outreach.op(act))
    assert JSON.decode!(nack.data)["column"] == "report"
    {[l], []} = key_session_ops(agent, Outreach.op(%{act | report: "Sent at 10:42."}))
    got = Outreach.from_row(Repo.get!(Rows.Outreach, l.id))
    assert %LinkedIn{actor: :agent, filing: :filed, filed_by: :agent} = got

    assert Outreach.refs(got) == %{
             corporation_id: corp,
             application_id: app.id,
             contact_id: nil,
             mission_id: mission.id
           }

    assert Outreach.status(got) == :sent
    # Marking it seen is a put on the row; the kind is fixed.
    {[_], []} = run(a.id, Outreach.op(%{got | seen: true}, target: l.id))
    as_note = struct(Note, Map.from_struct(%{got | kind: :note}))
    assert {[], [%{refusal: :column}]} = run(a.id, Outreach.op(as_note, target: l.id))
  end

  test "what the sender reads off an email mission in flight, and the hand-off guard" do
    mission = %{
      id: 33,
      kind: :email,
      application_id: 120,
      contact_id: 9,
      target: "jobs@acme.example, Dana <dana@acme.example>",
      cc: nil,
      subject: "Staff Engineer application",
      draft: "Hello ...",
      in_reply_to: nil,
      refs: nil,
      message_id: "<hm.7f3a@gmail.com>",
      in_flight_at: ~U[2026-10-22 14:20:00Z]
    }

    assert is_email_mission(mission)
    refute is_email_mission(%{mission | kind: :linkedin})
    shot = Email.shot(mission, "matei3d@gmail.com")

    assert %Email{
             direction: :outbound,
             from: "matei3d@gmail.com",
             mission_id: 33,
             application_id: 120,
             contact_id: 9,
             pipe: :hireme
           } = shot

    assert Email.recipients(shot) == ["jobs@acme.example", "dana@acme.example"]
    assert Email.copies(shot) == []

    assert {shot.subject, shot.body, shot.message_id, shot.at} ==
             {"Staff Engineer application", "Hello ...", "<hm.7f3a@gmail.com>",
              ~U[2026-10-22 14:20:00Z]}

    assert Outreach.status(shot) == :sent
    assert Outreach.kinds() == Schema.enum(:outreach_kind)
    assert Outreach.module(:x_dm) == Hireme.Outreach.XDm
  end
end
