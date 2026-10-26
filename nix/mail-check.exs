# The operator's half of the dev check's mail scenario, run inside the release
# by `bin/hireme rpc` (the agent's half is mail-check.py, over /mcp). Each
# step prints one JSON line; the check's state (ids, the agent's key) is kept
# in /var/lib/hireme/mail-check.json between steps.
defmodule MailCheck do
  import Ecto.Query, only: [from: 2]
  alias Hireme.{Gmail, Grants, Repo, Schema, Sequencer}
  alias HiremeWeb.Wire.Codec

  @state "/var/lib/hireme/mail-check.json"
  @user "check@gmail.com"
  @password "abcdefghijklmnop"

  # A browser session (fresh: signed in now, no factor enrolled), an agent key,
  # a company, two applications at fire_ready and their missions:
  #   reply, changed: email follow-ups in a thread (no CV file needed);
  #   first: a first-contact email with no CV file, which may not reach fire_ready;
  #   unsettled: on an application whose earlier send the ledger records but
  #   the operator has not settled.
  def seed do
    {:ok, _, s} = Hireme.Accounts.sign_in_with(:email, %{subject: "check@localhost", display: "check@localhost"}, %{ip: "127.0.0.1"})
    a = s.account_id
    {:ok, %{secret: agent_key}} = Hireme.Keys.mint(s, "mail-check agent", Hireme.Keys.preset(:read_write))
    op = operator(s)

    corp = id!(a, put(:corporations, %{domain: "acme.example", name: "Acme"}), op)
    batch = id!(a, put(:batches, %{code: "mail-check", ordinal: 1}), op)
    app = application(a, corp, batch, "Staff Engineer", op)
    other = application(a, corp, batch, "Principal Engineer", op)

    {[_], []} = run(a, put(:applications, %{stage_notes: %{"sync" => %{"applied_on" => "2026-10-12"}}}, target: other), op)

    # The threads the follow-ups answer: mail from the company, taken in as
    # the domain pipe takes it. A reply counts as one only when its
    # in_reply_to names a message the account holds (5adc7ce7).
    for id <- ~w(m0 m1 m2), do: {:ok, :stored} = Gmail.ingest(a, inbound(id), :domain)

    reply = mission(a, app, "jobs@acme.example", "Re: Staff Engineer", "Thank you, Thursday works.\n\nBest", "m0@acme.example", op)
    changed = mission(a, app, "hiring@acme.example", "Re: Staff Engineer", "Following up on Thursday.", "m1@acme.example", op)
    unsettled = mission(a, other, "jobs@acme.example", "Re: Principal Engineer", "Thank you.", "m2@acme.example", op)

    first =
      run(a, put(:missions, %{application_id: app, kind: :email, target: "jobs@acme.example", subject: "Staff Engineer", draft: "Hello.", state: :fire_ready}), op)

    first_refusal = with {[], [nack]} <- first, do: Schema.refusal_name(nack.code) |> to_string(), else: (_ -> "accepted")

    save(%{account: a, session: s.id, agent_key: agent_key, app: app, other: other, reply: reply, changed: changed, unsettled: unsettled})
    out(%{account: a, agent_key: agent_key, app: app, other: other, reply: reply, changed: changed, unsettled: unsettled, first_without_cv: first_refusal})
  end

  # Links the fake Gmail by its app password (one IMAP login), then waits for live.
  def link do
    %{"account" => a} = load()
    {:ok, _} = Gmail.link(a, @user, @password)
    live = wait(fn -> (Gmail.mailbox(a) || %{status: nil}).status == :live end)
    out(%{linked: live, status: to_string(Gmail.mailbox(a).status)})
  end

  # The review the predialed page shows, then the key, created by the fresh
  # session; and the same from a session signed in an hour ago, accepted: its
  # sign-in covers the session's life (the operator, 2026-10-26).
  def create_key(scope) do
    %{"account" => a, "session" => sid} = load()
    {:ok, review} = Gmail.query(a, "fire_review", %{"missions" => scope})
    {acks, nacks} = run(a, command(:create_fire_key, %{missions: review["scope"], digest: review["digest"]}), operator(sid))
    key = with [%{id: id}] <- acks, do: id, else: (_ -> nil)

    {:ok, _, stale} = Hireme.Accounts.sign_in_with(:email, %{subject: "check@localhost", display: "check@localhost"}, %{ip: "127.0.0.1"})
    Repo.update_all(from(x in Hireme.Rows.Session, where: x.id == ^stale.id), [set: [authenticated_at: DateTime.add(DateTime.utc_now(), -3600)]], skip_account: true)
    {_, stale_nacks} = run(a, command(:create_fire_key, %{missions: review["scope"], digest: review["digest"]}), operator(stale.id))

    out(%{
      key: key,
      refused: Enum.map(nacks, &to_string(Schema.refusal_name(&1.code))),
      eligible: Enum.map(review["missions"], &{&1["id"], &1["eligible"]}) |> Map.new(),
      stale_session: Enum.map(stale_nacks, &to_string(Schema.refusal_name(&1.code)))
    })
  end

  # Turns the domain pipe on: its public id and the secret the Worker would hold.
  def pipe do
    %{"account" => a} = load()
    {:ok, p} = Gmail.enable_pipe(a)
    out(p)
  end

  # What the desk holds now: each mission's state, the applications' stages,
  # the keys, and the outreach rows by direction and filing.
  def state do
    %{"account" => a, "app" => app, "other" => other} = load()

    Repo.with_account(a, fn ->
      missions = Repo.all(Hireme.Rows.Mission) |> Map.new(&{&1.id, %{state: to_string(&1.state), message_id: &1.message_id}})
      stage = fn id -> to_string(Repo.get!(Hireme.Rows.Application, id).stage) end

      rows =
        Repo.all(from(o in "outreach", select: %{direction: o.direction, filing: o.filing, application_id: o.application_id, message_id: o.message_id, pipe: o.pipe}))

      out(%{missions: missions, app_stage: stage.(app), other_stage: stage.(other), keys: Repo.aggregate(Hireme.Rows.FireKey, :count), outreach: rows})
    end)
  end

  # ------------------------------------------------------------------ helpers

  defp application(a, corp, batch, role, op) do
    app = id!(a, put(:applications, %{company: "Acme", role: role, corporation_id: corp, work_mode: :remote, batch_id: batch}), op)
    {[_], []} = run(a, command(:stage, %{stage: :fire_ready}, target: app), op)
    app
  end

  defp mission(a, app, to, subject, body, in_reply_to, op) do
    id!(a, put(:missions, %{application_id: app, kind: :email, target: to, subject: subject, draft: body, in_reply_to: in_reply_to, state: :fire_ready}), op)
  end

  defp inbound(id) do
    "From: Acme Jobs <jobs@acme.example>\r\nTo: check@gmail.com\r\nSubject: Staff Engineer at Acme\r\n" <>
      "Message-ID: <#{id}@acme.example>\r\nDate: Thu, 22 Oct 2026 09:00:00 +0000\r\n\r\nCould you do Thursday?\r\n"
  end

  defp operator(%{id: id}), do: operator(id)
  defp operator(sid), do: %{label: "page", grants: Grants.operator(), key_id: nil, session_id: sid}

  defp id!(a, op, actor) do
    {[%{id: id}], []} = run(a, op, actor)
    id
  end

  defp run(a, ops, actor) do
    {:ok, _rev, acks, nacks} = Sequencer.call(a, actor, List.wrap(ops))
    {acks, nacks}
  end

  defp put(table, cells, opts \\ []), do: op(:put, table, cells, opts)
  defp command(name, cells, opts \\ []), do: op(:command, name, cells, opts)

  # One op, encoded and decoded as the wire carries it.
  defp op(verb, subject, cells, opts) do
    {owner, cols} =
      case verb do
        :command ->
          c = Schema.command(subject)
          {c.id, Map.new(c.params, &{&1.name, &1})}

        _ ->
          t = Schema.table(subject)
          {t.id, Map.new(t.cols, &{&1.name, &1})}
      end

    encoded =
      Enum.map(cells, fn
        {name, nil} ->
          {Map.fetch!(cols, to_string(name)).id, 0, nil}

        {name, v} ->
          col = Map.fetch!(cols, to_string(name))
          ty = Codec.cell_type(col)
          v = Codec.to_wire(col, v)
          {col.id, ty, if(ty == 4, do: v * 1.0, else: v)}
      end)

    raw = Codec.encode_op({System.unique_integer([:positive]), verb, 0, owner, opts[:target] || 0, nil, encoded})
    {:ok, op, ""} = Codec.op(raw)
    op
  end

  defp wait(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(200) && wait(fun, tries - 1)
    end
  end

  defp save(m), do: File.write!(@state, JSON.encode!(Map.merge(load(), m)))
  defp load, do: if(File.exists?(@state), do: JSON.decode!(File.read!(@state)), else: %{})
  defp out(m), do: IO.puts(JSON.encode!(m))
end
