defmodule HiremeWeb.AccountController do
  @moduledoc """
  The signed-in account over JSON: its API keys, its sessions, and its
  ways in. Every action runs as that account; a key, session, or
  identity id from another account is simply not found. Adding or
  removing a way in sits behind a fresh second factor (`:step_up`).
  """

  use Phoenix.Controller, formats: [:json]
  import Plug.Conn

  alias Hireme.Accounts
  alias Hireme.ApiKeys
  alias HiremeWeb.Auth
  alias HiremeWeb.JSON
  alias HiremeWeb.SignIn

  @expiries [nil, 30, 90, 365]

  def index(conn, _params), do: json(conn, settings(conn))

  def create_key(conn, params) do
    days = params["expires_in_days"]

    with true <- days in @expiries or days in Enum.map(@expiries, &to_string/1),
         {:ok, %{key: key, secret: secret}} <-
           ApiKeys.create(
             params["name"],
             days && String.to_integer(to_string(days)),
             Auth.meta(conn)
           ) do
      json(conn, settings(conn) |> Map.merge(%{ok: true, created: JSON.key(key), secret: secret}))
    else
      false ->
        JSON.refuse(conn, {:argument, "expires_in_days"})

      {:error, :name} ->
        JSON.refuse(conn, {:argument, "name"})

      {:error, :limit} ->
        JSON.refuse(conn, {409, "This account has as many keys as it may hold."})

      {:error, changeset} ->
        JSON.refuse(conn, changeset)
    end
  end

  def rename_key(conn, %{"id" => id, "name" => name}) do
    with {:ok, key} <- key(id),
         {:ok, _} <- ApiKeys.rename(key, name) do
      json(conn, Map.put(settings(conn), :ok, true))
    else
      {:error, reason} -> JSON.refuse(conn, reason)
    end
  end

  def revoke_key(conn, %{"id" => id}) do
    case key(id) do
      {:ok, key} ->
        if is_nil(key.revoked_at), do: ApiKeys.revoke(key, Auth.meta(conn))
        json(conn, Map.put(settings(conn), :ok, true))

      {:error, reason} ->
        JSON.refuse(conn, reason)
    end
  end

  def revoke_session(conn, %{"id" => id}) do
    me = conn.assigns.session

    case Integer.parse(to_string(id)) do
      {n, ""} when n == me.id ->
        conn |> Auth.sign_out() |> json(%{ok: true, signed_out: true})

      {n, ""} ->
        case Enum.find(Accounts.list_sessions(me.account_id), &(&1.id == n)) do
          nil ->
            JSON.refuse(conn, :not_found)

          session ->
            Accounts.revoke_session(session)
            json(conn, Map.put(settings(conn), :ok, true))
        end

      _ ->
        JSON.refuse(conn, :not_found)
    end
  end

  @doc """
  Add a way in. An address gets a mailed link that adds it only when
  opened in this browser; GitHub or X answer with the URL to send the
  browser to, and their callback adds the account the person returns as.
  """
  def link(conn, %{"provider" => "email"} = params) do
    with {:ok, address} <- Accounts.normalize_email(params["email"]),
         :ok <- Accounts.request_link(address, &SignIn.link_url/1, Auth.meta(conn)) do
      reply = Map.merge(settings(conn), %{ok: true, sent_to: address})
      conn |> SignIn.expect_email(address, conn.assigns.account.id) |> json(reply)
    else
      {:error, :invalid} ->
        JSON.refuse(conn, {:argument, "email"})

      {:error, :rate_limited} ->
        JSON.refuse(conn, {429, "Too many links were asked for. Wait a few minutes."})

      {:error, :mail} ->
        JSON.refuse(conn, {503, "The link could not be sent just now."})
    end
  end

  def link(conn, %{"provider" => name}) do
    with {:ok, provider} <- SignIn.parse(name),
         {:ok, conn, url} <- SignIn.begin(conn, provider, :link) do
      json(conn, %{ok: true, url: url})
    else
      :error -> JSON.refuse(conn, {:argument, "provider"})
      {:error, _} -> JSON.refuse(conn, {502, "That provider could not be reached."})
    end
  end

  def link(conn, _params), do: JSON.refuse(conn, {:argument, "provider"})

  def unlink(conn, %{"id" => id}) do
    with {n, ""} <- Integer.parse(to_string(id)),
         :ok <- Accounts.unlink(n, Auth.meta(conn)) do
      json(conn, Map.put(settings(conn), :ok, true))
    else
      {:error, :last} ->
        JSON.refuse(conn, {409, "This is the only way into the account. Add another first."})

      _ ->
        JSON.refuse(conn, :not_found)
    end
  end

  def revoke_other_sessions(conn, _params) do
    Accounts.revoke_other_sessions(conn.assigns.session)
    json(conn, Map.put(settings(conn), :ok, true))
  end

  defp settings(conn) do
    account = conn.assigns.account

    %{
      account: %{id: account.id, name: account.name},
      keys: Enum.map(ApiKeys.list(), &JSON.key/1),
      sessions:
        Enum.map(Accounts.list_sessions(account.id), &JSON.session(&1, conn.assigns.session.id)),
      security: HiremeWeb.MfaController.security(conn),
      identities: Enum.map(Accounts.identities(), &JSON.identity/1),
      sign_in_methods: [:email | SignIn.providers()]
    }
  end

  defp key(id) do
    with {n, ""} <- Integer.parse(to_string(id)),
         %{} = key <- ApiKeys.get(n) do
      {:ok, key}
    else
      _ -> {:error, :not_found}
    end
  end
end
