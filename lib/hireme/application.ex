defmodule Hireme.Application do
  @moduledoc """
  The node's supervision tree, in boot order: the database and its
  writer, the account processes, the database's own upkeep, mail, the
  front doors, and last the drain, so on SIGTERM it stops first and tells
  every wire session to resume elsewhere before anything under it goes.
  """

  use Application
  alias Hireme.Audit.Coalescer

  @impl true
  def start(_type, _args) do
    # The trail's coalesced counts outlive the process that flushes them.
    Coalescer.table()

    children =
      [
        Hireme.Repo,
        Hireme.Store,
        {Phoenix.PubSub, name: Hireme.PubSub},
        Hireme.RateLimit,
        Hireme.Accounts.Tickets,
        Hireme.Audit.Coalescer,
        Hireme.Sequencer.Supervisor,
        # Applies the baseline and pending additive files before any request,
        # then keeps the daily backup.
        Hireme.Release,
        Hireme.Mail,
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

  # Counts held past the trail's budgets are written before the node goes.
  @impl true
  def prep_stop(state) do
    unless Hireme.Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox,
      do: Coalescer.flush(:all)

    state
  end

  @impl true
  def config_change(changed, _new, removed) do
    HiremeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
