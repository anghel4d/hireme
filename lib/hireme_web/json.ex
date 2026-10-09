defmodule HiremeWeb.JSON do
  @moduledoc """
  The JSON shape of the account page's keys and ways in, and of an HTTP
  refusal. Every field is named here on purpose; nothing is serialised
  by reflection.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

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
