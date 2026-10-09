defmodule HiremeWeb.JSON do
  @moduledoc """
  The JSON shape of what an MCP agent's tool calls answer (a score
  chart, the heat chart's rows, gym and net progress, a heat verdict),
  of the account page's keys and ways in, and of an HTTP refusal. The
  browser derives its views itself from raw rows. Every field is named
  here on purpose; nothing is serialised by reflection.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  alias Hireme.Gym
  alias Hireme.Heat
  alias Hireme.LifeEv
  alias Hireme.Net

  @doc "A key as the settings page lists it. The secret is never here; `display` is its visible prefix."
  @spec key(Hireme.ApiKeys.Key.t()) :: map()
  def key(%Hireme.ApiKeys.Key{} = k) do
    %{
      id: k.id,
      key_id: "key_" <> k.key_id,
      name: k.name,
      display: Hireme.ApiKeys.display(k),
      scope: k.scope,
      created_at: k.inserted_at,
      last_used_at: k.last_used_at,
      expires_at: k.expires_at,
      revoked_at: k.revoked_at,
      live: Hireme.ApiKeys.live?(k)
    }
  end

  @doc "One way into the account. A provider's user id stays on the server; the handle shows."
  @spec identity(Hireme.Accounts.Identity.t()) :: map()
  def identity(%Hireme.Accounts.Identity{} = i),
    do: %{id: i.id, provider: i.provider, display: i.display, created_at: i.verified_at}

  @spec chart(LifeEv.Chart.t()) :: map()
  def chart(%LifeEv.Chart{} = c) do
    c
    |> Map.take([:n, :mean, :max, :min])
    |> Map.merge(%{
      bands: Enum.map(c.bands, &Map.take(&1, [:key, :label, :min, :max, :count, :share])),
      bins: Enum.map(c.bins, &Map.take(&1, [:lo, :hi, :count]))
    })
  end

  @spec gym(Gym.Progress.t()) :: map()
  def gym(%Gym.Progress{} = g) do
    g
    |> Map.take([:today, :target, :streak, :solved_today, :solved_week, :score])
    |> Map.merge(%{
      topics: Enum.map(g.topics, &Map.take(&1, [:key, :label, :count])),
      recent: Enum.map(g.recent, &rep/1)
    })
  end

  @spec rep(Gym.Rep.t()) :: map()
  def rep(%Gym.Rep{problem: problem} = rep) do
    rep
    |> Map.take([:id, :done_on, :outcome, :minutes, :note])
    |> Map.merge(Map.take(problem, [:platform, :slug, :title, :topic, :difficulty, :url]))
  end

  @spec net(Net.Progress.t()) :: map()
  def net(%Net.Progress{} = n) do
    n
    |> Map.take([:lane, :shipped_week, :drafts, :observer_runs])
    |> Map.put(:recent, Enum.map(n.recent, &entry/1))
  end

  @spec entry(Net.Entry.t()) :: map()
  def entry(%Net.Entry{} = e),
    do: Map.take(e, [:id, :kind, :channel, :title, :url, :body, :shipped_on])

  @spec heat_row(Heat.Chart.row()) :: map()
  def heat_row(row),
    do: Map.take(row, [:key, :label, :load, :cap, :ratio, :n, :cooldown_days, :size])

  @spec verdict(Heat.Verdict.t()) :: map()
  def verdict(%Heat.Verdict{} = v) do
    Map.take(v, ~w(decision reason company company_load company_cap company_increment size
                   ats_vendor ats_tenant vendor_load vendor_cap tenant_load tenant_cap
                   cooldown_days note)a)
  end

  @doc """
  Answer a refusal. A reason atom or changeset maps to the status and
  message the shell expects; `{status, message}` says both outright.
  """
  @spec refuse(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def refuse(conn, reason) do
    {status, message} =
      case reason do
        {status, message} when is_integer(status) -> {status, message}
        :not_found -> {404, "not found"}
        :batch -> {404, "batch"}
        :leased -> {423, "leased"}
        {:argument, name} -> {400, "bad argument #{name}"}
        %Ecto.Changeset{} -> {422, "invalid"}
        other when is_atom(other) -> {409, Atom.to_string(other)}
        other -> {400, inspect(other)}
      end

    conn |> put_status(status) |> json(%{error: message})
  end
end
