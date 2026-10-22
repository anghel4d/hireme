defmodule Hireme.Application do
  @moduledoc """
  The node's supervision tree, in boot order: the database and its
  writer, the account processes, the database's own upkeep, mail, the
  front doors, and last the drain, so on SIGTERM it stops first and tells
  every wire session to resume elsewhere before anything under it goes.
  """

  use Application
  alias Hireme.Audit.Coalescer
  alias HiremeWeb.Mcp.Session, as: McpSession

  @impl true
  def start(_type, _args) do
    # The trail's coalesced counts outlive the process that flushes them.
    Coalescer.table()

    children =
      [
        Hireme.Repo,
        Hireme.Store,
        Hireme.PubSub,
        Hireme.RateLimit,
        Hireme.Accounts.Tickets,
        Coalescer,
        Hireme.Sequencer.Supervisor,
        # Applies the baseline and pending additive files before any request,
        # then keeps the daily backup.
        Hireme.Release,
        Hireme.Mail,
        # The linked mailboxes' sessions, once the schema is applied; they
        # write through the sequencers.
        Hireme.Gmail
      ] ++
        McpSession.children() ++
        [
          HiremeWeb.Endpoint
        ] ++
        gate() ++
        [HiremeWeb.Session.Drain]

    Supervisor.start_link(children, strategy: :one_for_one, name: Hireme.Supervisor)
  end

  defp gate do
    if Application.get_env(:hireme, :gate, true),
      do: [{HiremeWeb.Gate, Application.get_env(:hireme, HiremeWeb.Gate, [])}],
      else: []
  end
end

defmodule Hireme.PubSub do
  @moduledoc """
  Topics on this node: a Registry of subscribers, and a message sent
  straight to each pid on its topic. A subscription ends with its process.
  """

  def child_spec(_),
    do:
      Registry.child_spec(
        keys: :duplicate,
        name: __MODULE__,
        partitions: System.schedulers_online()
      )

  def subscribe(topic) do
    {:ok, _} = Registry.register(__MODULE__, topic, nil)
    :ok
  end

  def broadcast(topic, message),
    do:
      Registry.dispatch(__MODULE__, topic, fn subs ->
        for {pid, _} <- subs, do: send(pid, message)
      end)
end
