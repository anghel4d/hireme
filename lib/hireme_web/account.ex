defmodule HiremeWeb.Account do
  @moduledoc """
  The account page over the browser's wire session: its data as tables,
  its commands as request and reply.

  **Data.** `tables/2` is five small tables, each replaced whole: `acct`
  (one row: the account, this session's id, recovery codes left, whether
  a factor is enrolled, the step-up window and when this session's
  freshness lapses), `acct_keys`, `acct_sessions`, `acct_identities` and
  `acct_factors`. They ride the browser BOOT. A change to any of them is
  announced on `Hireme.Audit.topic/1` as `{Hireme.Audit, :changed}`,
  and the session pushes them again. Changes come from these commands, from the
  ceremonies that stay HTTP, and from anything `Hireme.Audit` records:
  a sign-in elsewhere, an agent's key revoked, a factor added.

  **Commands.** `call/3` runs one `account/<name>` request for the
  session a wire ticket named. It reloads that session row on every
  call, so a step-up proved over HTTP counts on the next command, and a
  revoked session is signed out. Errors carry the status and message the
  HTTP routes used, `403 step_up` included.

  The second-factor ceremonies ride here too: step-up (app code,
  recovery code, passkey) and enrolment (app, passkey). None of them
  touches the cookie; proving a factor stamps the session row. A passkey
  ceremony is a pair of calls, `*_webauthn` for the options and
  `*_webauthn_confirm` with the browser's answer.

  What stays HTTP, and why: everything that writes the cookie (sign-in,
  sign-out, linking a new way in, which keeps the OAuth trip or the
  expected address in the cookie), the factor page of a session that has
  no wire yet, and the wire ticket itself.
  """

  import Ecto.Query

  alias Hireme.Accounts
  alias Hireme.Accounts.Session
  alias Hireme.ApiKeys
  alias Hireme.Audit
  alias Hireme.Mfa
  alias Hireme.Repo
  alias Hireme.Security
  alias HiremeWeb.Packet
  alias HiremeWeb.SignIn

  @expiries [nil, 30, 90, 365]
  @step_up ~w(create_key revoke_key revoke_other_sessions remove_factor recovery_codes unlink
              begin_totp confirm_totp begin_webauthn confirm_webauthn)

  @type context :: %{account_id: pos_integer(), session_id: pos_integer(), ip: String.t()}
  @type reply ::
          {:ok, map(), :changed | :same}
          | {:error, pos_integer(), String.t()}
          | {:signed_out, map()}

  @doc "A command's reply as the session sends it: an RPC frame, `u32 json_len | u32 0 | json`."
  @spec rpc_frame(iodata()) :: iodata()
  def rpc_frame(json),
    do: Packet.frame(:rpc, 0, [<<IO.iodata_length(json)::little-32, 0::32>>, json])

  # ---- Data ----

  @doc "The account's five tables, as `session_id` sees them."
  @spec tables(pos_integer(), pos_integer()) :: iodata()
  def tables(account_id, session_id) do
    Repo.put_account(account_id)
    account = Repo.get!(Accounts.Account, account_id, skip_account: true)
    sessions = Accounts.list_sessions(account_id)
    me = Enum.find(sessions, &(&1.id == session_id))
    methods = Mfa.methods()
    enrolled = methods != []

    [
      Packet.table(:acct, [
        %{
          id: account.id,
          name: account.name,
          me: session_id,
          recovery_left: Mfa.recovery_codes_left(),
          enrolled: enrolled,
          step_up_window: Security.step_up_window(),
          fresh_until: fresh_until(me, enrolled),
          sign_in_methods: Enum.map([:email | SignIn.providers()], &Atom.to_string/1)
        }
      ]),
      Packet.table(:acct_keys, Enum.map(ApiKeys.list(), &key_row/1)),
      Packet.table(:acct_sessions, Enum.map(sessions, &session_row/1)),
      Packet.table(:acct_identities, Enum.map(Accounts.identities(), &identity_row/1)),
      Packet.table(:acct_factors, Enum.map(methods, &factor_row/1))
    ]
  end

  defp fresh_until(nil, _enrolled), do: nil

  defp fresh_until(session, enrolled) do
    case if(enrolled, do: session.mfa_at, else: session.authenticated_at) do
      nil -> nil
      at -> DateTime.add(at, Security.step_up_window())
    end
  end

  defp session_row(s) do
    %{
      id: s.id,
      authenticated_at: s.authenticated_at,
      last_seen_at: s.last_seen_at,
      expires_at: s.expires_at,
      mfa_at: s.mfa_at,
      ip: s.ip,
      user_agent: s.user_agent
    }
  end

  defp factor_row(m) do
    %{
      id: m.id,
      kind: m.kind,
      name: m.name,
      created_at: m.verified_at,
      last_used_at: m.last_used_at,
      backed_up: m.backed_up,
      transports: String.split(m.transports, ",", trim: true)
    }
  end

  # ---- Commands ----

  @doc "Run one `account/<name>` command for the session in `ctx`."
  @spec call(String.t(), map(), context()) :: reply()
  def call("account/" <> name, params, %{account_id: account_id} = ctx) when is_map(params) do
    Repo.put_account(account_id)

    case live_session(ctx) do
      nil ->
        {:signed_out, %{signed_out: true}}

      session ->
        meta = %{ip: ctx[:ip] || "", user_agent: session.user_agent}

        if name in @step_up and not Mfa.fresh?(session),
          do: {:error, 403, "step_up"},
          else: command(name, params, session, meta)
    end
  end

  def call(_method, _params, _ctx), do: {:error, 404, "unknown method"}

  defp live_session(%{account_id: account_id, session_id: session_id}) do
    now = DateTime.utc_now()

    Repo.one(
      from(s in Session,
        where:
          s.id == ^session_id and s.account_id == ^account_id and is_nil(s.revoked_at) and
            s.expires_at > ^now
      ),
      skip_account: true
    )
  end

  defp command("rename_key", %{"id" => id, "name" => name}, _session, _meta) do
    with {:ok, key} <- key(id),
         {:ok, _} <- ApiKeys.rename(key, name) do
      done(%{})
    else
      {:error, reason} -> refuse(reason)
    end
  end

  defp command("create_key", params, _session, meta) do
    days = params["expires_in_days"]

    with true <- days in @expiries or days in Enum.map(@expiries, &to_string/1),
         {:ok, %{key: key, secret: secret}} <-
           ApiKeys.create(params["name"], days && String.to_integer(to_string(days)), meta) do
      done(%{created: key_row(key), secret: secret})
    else
      false -> refuse({:argument, "expires_in_days"})
      {:error, :name} -> refuse({:argument, "name"})
      {:error, :limit} -> {:error, 409, "This account has as many keys as it may hold."}
      {:error, reason} -> refuse(reason)
    end
  end

  defp command("revoke_key", %{"id" => id}, _session, meta) do
    with {:ok, key} <- key(id) do
      if is_nil(key.revoked_at), do: ApiKeys.revoke(key, meta)
      done(%{})
    else
      {:error, reason} -> refuse(reason)
    end
  end

  defp command("revoke_session", %{"id" => id}, me, _meta) do
    case int(id) do
      n when n == me.id ->
        Accounts.revoke_session(me)
        {:signed_out, %{ok: true, signed_out: true}}

      n when is_integer(n) ->
        case Enum.find(Accounts.list_sessions(me.account_id), &(&1.id == n)) do
          nil -> refuse(:not_found)
          session -> Accounts.revoke_session(session) && done(%{})
        end

      nil ->
        refuse(:not_found)
    end
  end

  defp command("revoke_other_sessions", _params, me, _meta) do
    Accounts.revoke_other_sessions(me)
    done(%{})
  end

  defp command("remove_factor", %{"id" => id}, me, meta) do
    with n when is_integer(n) <- int(id),
         %{} = method <- Enum.find(Mfa.methods(), &(&1.id == n)),
         :ok <- Mfa.remove(me, method, meta) do
      done(%{})
    else
      {:error, :step_up} -> {:error, 403, "step_up"}
      _ -> refuse(:not_found)
    end
  end

  defp command("recovery_codes", _params, _me, meta) do
    if Mfa.enrolled?(),
      do: done(%{recovery_codes: Mfa.recovery_codes!(meta)}),
      else: {:error, 409, "Recovery codes go with a second factor; add one first."}
  end

  defp command("unlink", %{"id" => id}, _me, meta) do
    with n when is_integer(n) <- int(id),
         :ok <- Accounts.unlink(n, meta) do
      done(%{})
    else
      {:error, :last} ->
        {:error, 409, "This is the only way into the account. Add another first."}

      _ ->
        refuse(:not_found)
    end
  end

  # Step-up: prove a factor now. The session row is stamped, so the
  # tables change (`fresh_until`) and the next sensitive command passes.
  defp command("step_up_totp", params, me, meta),
    do: stepped(Mfa.verify_totp(me, to_string(params["code"]), meta))

  defp command("step_up_recovery", params, me, meta),
    do: stepped(Mfa.verify_recovery(me, to_string(params["code"]), meta))

  defp command("step_up_webauthn", _params, me, _meta),
    do: {:ok, Mfa.begin_assertion(me), :same}

  defp command("step_up_webauthn_confirm", params, me, meta),
    do: stepped(Mfa.verify_assertion(me, params, meta))

  # Enrolment, behind a fresh step-up like every change to the ways in.
  defp command("begin_totp", _params, me, _meta),
    do: {:ok, Mfa.begin_totp(me, label(me.account_id)), :same}

  defp command("confirm_totp", params, me, meta) do
    name = to_string(params["name"] || "Authenticator app")

    case Mfa.confirm_totp(me, to_string(params["code"]), name, meta) do
      {:ok, _method, codes} -> done(%{recovery_codes: codes})
      {:error, :code} -> {:error, 400, "That code did not match. Enter the one showing now."}
      {:error, :challenge} -> {:error, 409, "Start again: the enrolment expired."}
    end
  end

  defp command("begin_webauthn", _params, me, _meta),
    do: {:ok, Mfa.begin_webauthn(me, label(me.account_id)), :same}

  defp command("confirm_webauthn", params, me, meta) do
    case Mfa.confirm_webauthn(me, params, meta) do
      {:ok, _method, codes} -> done(%{recovery_codes: codes})
      {:error, :duplicate} -> {:error, 409, "That credential is already registered."}
      {:error, reason} -> {:error, 400, message(reason)}
    end
  end

  defp command(_name, _params, _session, _meta), do: {:error, 404, "unknown method"}

  defp stepped({:ok, _session}), do: done(%{fresh: true})
  defp stepped({:error, reason}), do: {:error, 401, message(reason)}

  defp label(account_id) do
    case Repo.get!(Accounts.Account, account_id, skip_account: true).name do
      "" -> "account #{account_id}"
      name -> name
    end
  end

  defp message(:code), do: "That code did not match."
  defp message(:rate_limited), do: "Too many attempts. Wait a few minutes."
  defp message(:challenge), do: "Start again: the challenge expired."
  defp message(:assertion), do: "That passkey was not accepted."
  defp message(:clone), do: "That credential's counter went backwards; it has been disabled."
  defp message(:attestation), do: "That registration was not accepted."
  defp message(_), do: "That was not accepted."

  # The calling session pushes the tables before this reply; the
  # account's other sessions hear of it from the broadcast.
  defp done(extra) do
    Audit.changed(Repo.account_id())
    {:ok, Map.put(extra, :ok, true), :changed}
  end

  defp refuse(:not_found), do: {:error, 404, "not found"}
  defp refuse({:argument, name}), do: {:error, 400, "bad argument #{name}"}
  defp refuse(%Ecto.Changeset{}), do: {:error, 422, "invalid"}
  defp refuse(other) when is_atom(other), do: {:error, 409, Atom.to_string(other)}

  defp key(id) do
    with n when is_integer(n) <- int(id),
         %{} = key <- ApiKeys.get(n) do
      {:ok, key}
    else
      _ -> {:error, :not_found}
    end
  end

  defp int(n) when is_integer(n), do: n

  defp int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp int(_), do: nil

  # A key as the settings page lists it. The secret is never here; `display` is its visible prefix.
  defp key_row(%ApiKeys.Key{} = k) do
    %{
      id: k.id,
      key_id: "key_" <> k.key_id,
      name: k.name,
      display: ApiKeys.display(k),
      scope: k.scope,
      created_at: k.inserted_at,
      last_used_at: k.last_used_at,
      expires_at: k.expires_at,
      revoked_at: k.revoked_at,
      live: ApiKeys.live?(k)
    }
  end

  # One way into the account. A provider's user id stays on the server; the handle shows.
  defp identity_row(%Accounts.Identity{} = i),
    do: %{id: i.id, provider: i.provider, display: i.display, created_at: i.verified_at}
end

defmodule HiremeWeb.AccountController do
  @moduledoc """
  Adding a way in to the signed-in account, behind a fresh second
  factor. It stays HTTP because both kinds keep state in the cookie: an
  address gets a mailed link that adds it only when opened in this
  browser, and GitHub or X answer with the URL to send the browser to,
  whose callback checks the trip this browser started. The rest of the
  account page is `HiremeWeb.Account`, over the wire session.
  """

  use Phoenix.Controller, formats: [:json]

  alias Hireme.Accounts
  alias HiremeWeb.Auth
  alias HiremeWeb.SignIn

  def link(conn, %{"provider" => "email"} = params) do
    with {:ok, address} <- Accounts.normalize_email(params["email"]),
         :ok <- Accounts.request_link(address, &SignIn.link_url/1, Auth.meta(conn)) do
      conn
      |> SignIn.expect_email(address, conn.assigns.account.id)
      |> json(%{ok: true, sent_to: address})
    else
      {:error, :invalid} ->
        Auth.refuse(conn, {:argument, "email"})

      {:error, :rate_limited} ->
        Auth.refuse(conn, {429, "Too many links were asked for. Wait a few minutes."})
    end
  end

  def link(conn, %{"provider" => name}) do
    with {:ok, provider} <- SignIn.parse(name),
         {:ok, conn, url} <- SignIn.begin(conn, provider, :link) do
      json(conn, %{ok: true, url: url})
    else
      :error -> Auth.refuse(conn, {:argument, "provider"})
      {:error, _} -> Auth.refuse(conn, {502, "That provider could not be reached."})
    end
  end

  def link(conn, _params), do: Auth.refuse(conn, {:argument, "provider"})
end
