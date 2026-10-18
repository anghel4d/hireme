defmodule HiremeWeb.FactorController do
  @moduledoc """
  The factor page a pending session lands on after signing in, where it
  proves a second factor before it may reach the page or the wire. A
  session that owes its factor holds no ticket, so this stays HTTP.
  Enrolling, stepping up and removing factors are `account.*` RPC
  methods over the wire (`HiremeWeb.Account`).

  The passkey assertion is the only script here (`factor.js`):
  `POST /sign-in/factor/webauthn` answers the request options, and
  `POST /sign-in/factor/webauthn/verify` takes the browser's assertion,
  binary fields base64url without padding.
  """

  use Phoenix.Controller, formats: [:html, :json]
  import Plug.Conn
  import HiremeWeb.Auth, only: [esc: 1, page: 5, csrf_field: 0, meta: 1]
  alias Hireme.Mfa

  def show(conn, params) do
    factors = Mfa.factors()
    passkeys? = Enum.any?(factors, &(&1.kind == :webauthn))
    apps? = Enum.any?(factors, &(&1.kind == :totp))
    error = if is_binary(params["error"]), do: message(params["error"])

    page(
      conn,
      200,
      "Second factor",
      """
      <p class="lede">One more step: this account has a second factor.</p>
      <p class="notice" id="factor-error" role="alert"#{if error, do: "", else: " hidden"}>#{esc(error || "")}</p>
      #{if passkeys?, do: ~s(<button type="button" id="use-passkey" class="primary method">Use a passkey or security key</button>)}
      #{if passkeys? and apps?, do: ~s(<p class="or">or</p>)}
      #{if apps?, do: """
        <form method="post" action="/sign-in/factor/totp" class="method">
          #{csrf_field()}
          <label for="code">Code from your authenticator app</label>
          <input id="code" name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9 ]*" required />
          <button type="submit" class="primary">Continue</button>
        </form>
        """}
      <details class="method">
        <summary>Use a recovery code</summary>
        <form method="post" action="/sign-in/factor/recovery">
          #{csrf_field()}
          <input name="code" autocomplete="off" placeholder="xxxx-xxxx-xxxx-xxxx" required />
          <button type="submit" class="ghost">Continue</button>
        </form>
      </details>
      <form method="post" action="/sign-out" class="method">
        #{csrf_field()}
        <button type="submit" class="ghost">Sign out</button>
      </form>
      """,
      script: if(passkeys?, do: "/assets/factor.js")
    )
  end

  def totp(conn, params),
    do: proved(conn, Mfa.verify_totp(conn.assigns.session, params["code"], meta(conn)))

  def recovery(conn, params),
    do: proved(conn, Mfa.verify_recovery(conn.assigns.session, params["code"], meta(conn)))

  def webauthn(conn, _params) do
    case Mfa.begin_assertion(conn.assigns.session) do
      {:ok, options} -> json(conn, options)
      {:error, reason} -> conn |> put_status(429) |> json(%{error: message(reason)})
    end
  end

  def webauthn_verify(conn, params) do
    case Mfa.verify_assertion(conn.assigns.session, params, meta(conn)) do
      {:ok, _} -> json(conn, %{ok: true})
      {:error, reason} -> conn |> put_status(401) |> json(%{error: message(reason)})
    end
  end

  defp proved(conn, {:ok, _session}), do: redirect(conn, to: "/")
  defp proved(conn, {:error, reason}), do: redirect(conn, to: "/sign-in/factor?error=#{reason}")

  defp message(reason) when is_binary(reason) do
    Enum.find_value(
      ~w(code rate_limited challenge assertion clone)a,
      "That did not work. Try again.",
      &(Atom.to_string(&1) == reason && message(&1))
    )
  end

  defp message(:code), do: "That code did not match."
  defp message(:rate_limited), do: "Too many attempts. Wait a few minutes."
  defp message(:challenge), do: "Start again: the challenge expired."
  defp message(:assertion), do: "That passkey was not accepted."
  defp message(:clone), do: "That credential's counter went backwards; it has been disabled."
end
