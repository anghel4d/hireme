defmodule HiremeWeb.MfaController do
  @moduledoc """
  The factor page a pending session lands on after signing in, where it
  proves a second factor before it may reach the desk. A session that
  owes its factor has no wire session yet, so this stays HTTP. Enrolling,
  stepping up and removing factors are account commands over the wire
  (`HiremeWeb.Account`).
  """

  use Phoenix.Controller, formats: [:html, :json]
  import Plug.Conn

  alias Hireme.Mfa
  alias HiremeWeb.Auth
  alias HiremeWeb.JSON

  ## The factor page: a pending session proves a second factor.

  def factor(conn, _params) do
    csrf = Plug.CSRFProtection.get_csrf_token()
    passkeys? = Enum.any?(Mfa.methods(), &(&1.kind == :webauthn))
    apps? = Enum.any?(Mfa.methods(), &(&1.kind == :totp))
    error = conn.params["error"]

    page = """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content="#{csrf}" />
        <title>Second factor · Hireme</title>
        <link rel="stylesheet" href="/assets/js/app.css" />
        <script defer type="module" src="/assets/js/factor.js"></script>
      </head>
      <body class="sign-in">
        <main class="sign-in-card" id="factor">
          <h1>HIREME</h1>
          <p class="lede">One more step: this account has a second factor.</p>
          #{if error, do: ~s(<p class="banner hold-error">#{Plug.HTML.html_escape(error)}</p>), else: ""}
          #{if passkeys?, do: ~s(<button type="button" id="use-passkey" class="primary method">Use a passkey or security key</button><p class="or">or</p>), else: ""}
          #{if apps?,
      do: """
      <form method="post" action="/sign-in/factor/totp" class="method">
        <input type="hidden" name="_csrf_token" value="#{csrf}" />
        <label for="code">Code from your authenticator app</label>
        <input id="code" name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9 ]*" required />
        <button type="submit" class="primary">Continue</button>
      </form>
      """,
      else: ""}
          <details class="method">
            <summary>Use a recovery code</summary>
            <form method="post" action="/sign-in/factor/recovery">
              <input type="hidden" name="_csrf_token" value="#{csrf}" />
              <input name="code" autocomplete="off" placeholder="xxxx-xxxx-xxxx-xxxx" required />
              <button type="submit" class="ghost">Continue</button>
            </form>
          </details>
          <form method="post" action="/sign-out" class="method">
            <input type="hidden" name="_csrf_token" value="#{csrf}" />
            <button type="submit" class="text-btn">Sign out</button>
          </form>
        </main>
      </body>
    </html>
    """

    conn |> put_resp_content_type("text/html") |> send_resp(200, page)
  end

  def factor_totp(conn, params),
    do: proved(conn, Mfa.verify_totp(conn.assigns.session, params["code"], Auth.meta(conn)))

  def factor_recovery(conn, params),
    do: proved(conn, Mfa.verify_recovery(conn.assigns.session, params["code"], Auth.meta(conn)))

  def factor_webauthn(conn, _params), do: json(conn, Mfa.begin_assertion(conn.assigns.session))

  def factor_webauthn_confirm(conn, params) do
    case Mfa.verify_assertion(conn.assigns.session, params, Auth.meta(conn)) do
      {:ok, _} -> json(conn, %{ok: true})
      {:error, reason} -> JSON.refuse(conn, {401, message(reason)})
    end
  end

  defp proved(conn, {:ok, _session}), do: redirect(conn, to: "/")

  defp proved(conn, {:error, reason}),
    do: redirect(conn, to: "/sign-in/factor?error=#{URI.encode_www_form(message(reason))}")

  defp message(:code), do: "That code did not match."
  defp message(:rate_limited), do: "Too many attempts. Wait a few minutes."
  defp message(:challenge), do: "Start again: the challenge expired."
  defp message(:assertion), do: "That passkey was not accepted."
  defp message(:clone), do: "That credential's counter went backwards; it has been disabled."
end
