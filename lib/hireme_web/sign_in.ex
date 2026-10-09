defmodule HiremeWeb.SignIn do
  @moduledoc """
  GitHub and X as ways in, over OAuth 2.0: the authorization code flow
  with PKCE (S256) and a `state` kept in this browser's encrypted
  session, spent on the first callback and good for ten minutes (RFC
  9700 Sec. 2.1, 4.7; RFC 7636). The redirect URI comes from the
  endpoint's configured host, never from the request, and must match
  the provider's registration exactly. A provider is offered when its
  client id and secret are set under `config :hireme, :oauth`.

  A provider proves one thing: the person holds that provider account.
  Its immutable user id is the identity's subject and its handle is for
  display. Nothing it says about an email address is read, so no account
  is ever reached or joined through an address a provider asserts.

  The same session carries the address an Account page asked to add
  (`expect_email/3`), so a mailed link adds an address only in the
  browser that asked, to the account that asked.
  """

  use Phoenix.VerifiedRoutes, endpoint: HiremeWeb.Endpoint, router: HiremeWeb.Router
  import Plug.Conn

  @strategies [github: HiremeWeb.SignIn.Github, x: HiremeWeb.SignIn.X]
  @trip "hireme_oauth"
  @expect "hireme_expect_email"

  @type provider :: :github | :x
  @type claim :: %{subject: String.t(), display: String.t()}
  @type refusal :: :state | :expired | :denied | :provider

  @doc "The providers this desk offers, in the order the pages list them."
  @spec providers() :: [provider()]
  def providers, do: for({p, _} <- @strategies, match?({:ok, _}, config(p)), do: p)

  @doc "An offered provider named on the wire, or `:error`."
  @spec parse(term()) :: {:ok, provider()} | :error
  def parse(name) do
    with {:ok, provider} <- Hireme.Closed.parse(Keyword.keys(@strategies), name),
         true <- provider in providers() do
      {:ok, provider}
    else
      _ -> :error
    end
  end

  @spec label(provider() | :email) :: String.t()
  def label(:github), do: "GitHub"
  def label(:x), do: "X"
  def label(:email), do: "Email"

  @doc "The URL a mailed link carries. The token rides in the query, out of the request line."
  @spec link_url(String.t()) :: String.t()
  def link_url(token), do: url(~p"/sign-in/email?#{[token: token]}")

  @doc """
  Start a round trip to `provider` for `mode`: the session keeps the
  state, the PKCE verifier, what the trip is for, and who asked.
  """
  @spec begin(Plug.Conn.t(), provider(), :sign_in | :link) ::
          {:ok, Plug.Conn.t(), String.t()} | {:error, term()}
  def begin(conn, provider, mode) do
    with {:ok, config} <- config(provider),
         {:ok, %{url: url, session_params: params}} <- @strategies[provider].authorize_url(config) do
      account = conn.assigns[:account]

      trip = %{
        provider: provider,
        params: params,
        mode: mode,
        account_id: account && account.id,
        at: System.system_time(:second)
      }

      {:ok, put_session(conn, @trip, trip), url}
    end
  end

  @doc """
  Finish the round trip a callback names. The stored trip is gone after
  this whatever the answer; it must be this provider's and fresh, and
  the provider must hand back the state it was given.
  """
  @spec finish(Plug.Conn.t(), provider(), map()) ::
          {Plug.Conn.t(), {:ok, map(), claim()} | {:error, refusal()}}
  def finish(conn, provider, params) do
    trip = get_session(conn, @trip)
    conn = delete_session(conn, @trip)

    result =
      with %{provider: ^provider, params: session_params, at: at} <- trip,
           {:fresh, true} <- {:fresh, fresh?(at)},
           {:ok, config} <- config(provider),
           {:ok, %{user: user}} <-
             @strategies[provider].callback(
               Keyword.put(config, :session_params, session_params),
               params
             ),
           {:ok, claim} <- claim(provider, user) do
        {:ok, trip, claim}
      else
        {:fresh, false} -> {:error, :expired}
        {:error, error} -> {:error, refusal(error)}
        _ -> {:error, :state}
      end

    {conn, result}
  end

  defp refusal(%Assent.CallbackError{error: "access_denied"}), do: :denied
  defp refusal(%Assent.CallbackCSRFError{}), do: :state
  defp refusal(%Assent.MissingParamError{key: "state"}), do: :state
  defp refusal(_), do: :provider

  defp claim(provider, %{"sub" => sub} = user) when is_binary(sub) and sub != "" do
    display =
      case {provider, user["preferred_username"]} do
        {_, handle} when not is_binary(handle) or handle == "" -> sub
        {:x, handle} -> "@" <> handle
        {_, handle} -> handle
      end

    {:ok, %{subject: sub, display: String.slice(display, 0, 100)}}
  end

  defp claim(_provider, _user), do: {:error, :claim}

  @doc "Remember that this browser, signed in as `account_id`, asked to add `email`."
  @spec expect_email(Plug.Conn.t(), String.t(), pos_integer()) :: Plug.Conn.t()
  def expect_email(conn, email, account_id) do
    put_session(conn, @expect, %{
      email: email,
      account_id: account_id,
      at: System.system_time(:second)
    })
  end

  @doc "The address this browser asked to add to the account it is signed in to, while fresh."
  @spec expected_email(Plug.Conn.t()) :: String.t() | nil
  def expected_email(conn) do
    with %{email: email, account_id: id, at: at} <- get_session(conn, @expect),
         %{id: ^id} <- conn.assigns[:account],
         false <- conn.assigns[:pending],
         true <- fresh?(at) do
      email
    else
      _ -> nil
    end
  end

  @spec forget_email(Plug.Conn.t()) :: Plug.Conn.t()
  def forget_email(conn), do: delete_session(conn, @expect)

  # A trip or an asked-for address lives as long as the link that would finish it.
  defp fresh?(at),
    do: is_integer(at) and System.system_time(:second) - at < Hireme.Security.magic_link_ttl()

  defp config(provider) do
    opts = :hireme |> Application.get_env(:oauth, []) |> Keyword.get(provider, [])

    case {opts[:client_id], opts[:client_secret]} do
      {id, secret} when is_binary(id) and id != "" and is_binary(secret) and secret != "" ->
        {:ok,
         [
           client_id: id,
           client_secret: secret,
           redirect_uri: url(~p"/auth/#{provider}/callback"),
           code_verifier: true
         ] ++ Keyword.take(opts, [:http_adapter])}

      _ ->
        {:error, :not_configured}
    end
  end
end

defmodule HiremeWeb.SignIn.Github do
  @moduledoc false
  # GitHub's OAuth app flow; PKCE (S256) is honoured since July 2025. No
  # scope: the public profile is all a sign-in needs, and the person's
  # addresses are never asked for.
  use Assent.Strategy.OAuth2.Base

  @impl true
  def default_config(_config) do
    [
      base_url: "https://api.github.com",
      authorize_url: "https://github.com/login/oauth/authorize",
      token_url: "https://github.com/login/oauth/access_token",
      user_url: "/user",
      auth_method: :client_secret_post
    ]
  end

  @impl true
  def normalize(_config, user),
    do:
      {:ok, %{"sub" => user["id"], "preferred_username" => user["login"], "name" => user["name"]}}
end

defmodule HiremeWeb.SignIn.X do
  @moduledoc false
  # X's OAuth 2.0; assent's Twitter strategy is OAuth 1.0a. A confidential
  # client authenticates with HTTP Basic at the token endpoint, and reading
  # /2/users/me takes users.read with tweet.read.
  use Assent.Strategy.OAuth2.Base

  @impl true
  def default_config(_config) do
    [
      base_url: "https://api.x.com",
      authorize_url: "https://x.com/i/oauth2/authorize",
      token_url: "/2/oauth2/token",
      user_url: "/2/users/me",
      authorization_params: [scope: "users.read tweet.read"],
      auth_method: :client_secret_basic
    ]
  end

  @impl true
  def normalize(_config, %{"data" => %{} = user}),
    do:
      {:ok,
       %{"sub" => user["id"], "preferred_username" => user["username"], "name" => user["name"]}}

  def normalize(_config, _body), do: {:error, :claim}
end

defmodule HiremeWeb.SignInController do
  @moduledoc """
  The sign-in pages. Passwordless: a mailed link, GitHub, or X. A
  visitor ends in `Hireme.Accounts.sign_in_with/3`, which finds the
  account or makes one; a browser that asked from the Account page ends
  in `Hireme.Accounts.link/3`.

  A mailed link is a GET that only shows where it leads; the POST its
  page sends spends it, so a mail scanner that follows every link spends
  nothing. A link adds an address only in the browser that asked for it
  on the Account page; any other signed-in browser is told to sign out
  first, and the link stays good. GitHub and X start here only for a
  visitor; adding them to an account starts on the Account page, behind
  a fresh second factor.
  """

  use Phoenix.Controller, formats: [:html]

  use Phoenix.VerifiedRoutes,
    endpoint: HiremeWeb.Endpoint,
    router: HiremeWeb.Router,
    statics: HiremeWeb.static_paths()

  import Plug.Conn

  alias Hireme.Accounts
  alias Hireme.Audit
  alias HiremeWeb.Auth
  alias HiremeWeb.SignIn

  @notices %{
    "link" => "That link has expired or was already used. Ask for a new one.",
    "denied" => "Sign-in was cancelled.",
    "failed" => "Sign-in did not finish. Try again.",
    "suspended" => "This account is suspended."
  }

  def index(%{assigns: %{account: %{}, pending: true}} = conn, _params),
    do: redirect(conn, to: ~p"/sign-in/factor")

  def index(%{assigns: %{account: %{}}} = conn, _params), do: redirect(conn, to: ~p"/")
  def index(conn, params), do: methods(conn, 200, Map.get(@notices, params["error"]))

  def request_email(%{assigns: %{account: %{}}} = conn, _params), do: redirect(conn, to: ~p"/")

  def request_email(conn, params) do
    email = if is_binary(params["email"]), do: params["email"], else: ""

    case Accounts.request_link(email, &SignIn.link_url/1, Auth.meta(conn)) do
      :ok ->
        {:ok, address} = Accounts.normalize_email(email)

        page(conn, 200, "Check your email", """
        <p class="lede">A sign-in link is on its way to <strong>#{esc(address)}</strong>. It works once, for ten minutes.</p>
        <p class="lede">Nothing there? Look in spam, or <a href="#{~p"/sign-in"}">ask for another</a>.</p>
        """)

      {:error, :invalid} ->
        methods(conn, 422, "Enter a whole email address, like you@example.com.")

      {:error, :rate_limited} ->
        methods(conn, 429, "Too many links were asked for. Wait a few minutes, then try again.")
    end
  end

  def confirm_email(conn, %{"token" => token}) when is_binary(token) do
    conn = no_store(conn)

    with {:ok, email} <- Accounts.peek_link(token),
         {:ok, mode} <- mode(conn, email) do
      {question, button} =
        case mode do
          :add -> {"Add #{email} to your account?", "Add this address"}
          :sign_in -> {"Sign in as #{email}?", "Sign in"}
        end

      page(conn, 200, button, """
      <p class="lede">#{esc(question)}</p>
      <form method="post" action="#{~p"/sign-in/email/confirm"}" class="method">
        <input type="hidden" name="_csrf_token" value="#{Plug.CSRFProtection.get_csrf_token()}" />
        <input type="hidden" name="token" value="#{esc(token)}" />
        <button type="submit" class="primary">#{button}</button>
      </form>
      <p class="lede">Did not ask for this? Close the page; nothing happens.</p>
      """)
    else
      {:error, :invalid} -> methods(conn, 410, @notices["link"])
      {:error, :signed_in} -> signed_in(conn)
    end
  end

  def confirm_email(conn, _params), do: redirect(conn, to: ~p"/sign-in")

  def redeem_email(conn, %{"token" => token}) when is_binary(token) do
    with {:ok, email} <- Accounts.peek_link(token),
         {:ok, mode} <- mode(conn, email),
         {:ok, ^email} <- Accounts.redeem_link(token, Auth.meta(conn)) do
      claim = %{subject: email, display: email}

      case mode do
        :add -> conn |> SignIn.forget_email() |> add(:email, claim)
        :sign_in -> enter(conn, :email, claim)
      end
    else
      {:error, :signed_in} -> signed_in(conn)
      {:error, :rate_limited} -> methods(conn, 429, "Too many tries. Wait a few minutes.")
      _ -> methods(conn, 410, @notices["link"])
    end
  end

  def redeem_email(conn, _params), do: redirect(conn, to: ~p"/sign-in")

  # What a live link does in this browser. It adds an address only where
  # the Account page asked for that address; any other signed-in browser
  # must sign out first, or a link mailed to someone else's address could
  # be opened here and join it to this account.
  defp mode(conn, email) do
    cond do
      SignIn.expected_email(conn) == email -> {:ok, :add}
      conn.assigns.account -> {:error, :signed_in}
      true -> {:ok, :sign_in}
    end
  end

  def authorize(%{assigns: %{account: %{}}} = conn, _params), do: redirect(conn, to: ~p"/")

  def authorize(conn, %{"provider" => name}) do
    with {:ok, provider} <- SignIn.parse(name),
         {:ok, conn, url} <- SignIn.begin(conn, provider, :sign_in) do
      redirect(conn, external: url)
    else
      :error -> send_resp(conn, 404, "Not Found")
      {:error, _} -> redirect(conn, to: ~p"/sign-in?#{[error: "failed"]}")
    end
  end

  def callback(conn, %{"provider" => name} = params) do
    case SignIn.parse(name) do
      {:ok, provider} ->
        case SignIn.finish(conn, provider, params) do
          {conn, {:ok, %{mode: :link, account_id: id}, claim}} ->
            if here?(conn, id),
              do: add(conn, provider, claim),
              else: refuse(conn, provider, :state)

          {conn, {:ok, %{mode: :sign_in}, _claim}} when conn.assigns.account != nil ->
            redirect(conn, to: ~p"/")

          {conn, {:ok, %{mode: :sign_in}, claim}} ->
            enter(conn, provider, claim)

          {conn, {:error, reason}} ->
            refuse(conn, provider, reason)
        end

      :error ->
        send_resp(conn, 404, "Not Found")
    end
  end

  # The browser that started a link is still that account, past its factor.
  defp here?(conn, account_id) do
    match?(%{id: ^account_id}, conn.assigns.account) and not conn.assigns.pending
  end

  defp enter(conn, provider, claim) do
    case Accounts.sign_in_with(provider, claim, Auth.meta(conn)) do
      {:ok, token, _session} -> conn |> Auth.sign_in(token) |> redirect(to: ~p"/")
      {:error, :suspended} -> methods(conn, 403, @notices["suspended"])
    end
  end

  defp add(conn, provider, claim) do
    case Accounts.link(provider, claim, Auth.meta(conn)) do
      {:ok, _identity} -> redirect(conn, to: ~p"/?#{[lens: "settings", linked: provider]}")
      {:error, :taken} -> redirect(conn, to: ~p"/?#{[lens: "settings", link_error: "taken"]}")
    end
  end

  defp refuse(conn, provider, reason) do
    Audit.record(:sign_in_refused, %{provider: provider, reason: reason}, Auth.meta(conn))
    code = if reason == :denied, do: "denied", else: "failed"

    if conn.assigns.account,
      do: redirect(conn, to: ~p"/?#{[lens: "settings", link_error: code]}"),
      else: redirect(conn, to: ~p"/sign-in?#{[error: code]}")
  end

  defp signed_in(conn) do
    page(conn, 409, "Signed in", """
    <p class="lede">This browser is signed in, and this link is for signing in. To use it, sign out first, then open the link again.</p>
    <form method="post" action="#{~p"/sign-out"}" class="method">
      <input type="hidden" name="_csrf_token" value="#{Plug.CSRFProtection.get_csrf_token()}" />
      <button type="submit" class="primary">Sign out</button>
    </form>
    <a class="ghost method" href="#{~p"/"}">Back to the desk</a>
    """)
  end

  defp methods(conn, status, notice) do
    csrf = Plug.CSRFProtection.get_csrf_token()
    providers = SignIn.providers()
    ways = ["a link to your email" | Enum.map(providers, &SignIn.label/1)]

    page(conn, status, "Sign in", """
    <p class="lede">No passwords. Sign in with #{sentence(ways)}.</p>
    #{if notice, do: ~s(<p class="banner hold-error" role="alert">#{esc(notice)}</p>)}
    <form method="post" action="#{~p"/sign-in/email"}" class="method">
      <input type="hidden" name="_csrf_token" value="#{csrf}" />
      <label for="email">Email</label>
      <input id="email" type="email" name="email" autocomplete="email" required placeholder="you@example.com" />
      <button type="submit" class="primary">Send a sign-in link</button>
    </form>
    #{if providers != [], do: ~s(<p class="or">or</p>)}
    #{Enum.map_join(providers, "\n", fn p -> ~s(<a class="ghost method" href="#{~p"/auth/#{p}"}">Continue with #{SignIn.label(p)}</a>) end)}
    #{dev_sign_in(csrf)}
    """)
  end

  defp sentence([one]), do: one
  defp sentence([one, two]), do: "#{one} or #{two}"
  defp sentence(ways), do: Enum.join(Enum.drop(ways, -1), ", ") <> ", or " <> List.last(ways)

  # Development only: the one-click sign-in to the local desk.
  defp dev_sign_in(csrf) do
    if Application.get_env(:hireme, :dev_routes) do
      """
      <form method="post" action="/dev/sign-in" class="method">
        <input type="hidden" name="_csrf_token" value="#{csrf}" />
        <button type="submit" class="primary">Sign in to the local desk (development)</button>
      </form>
      """
    end
  end

  defp page(conn, status, title, body) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>#{esc(title)} · Hireme</title>
        <link rel="stylesheet" href="#{~p"/assets/js/app.css"}" />
      </head>
      <body class="sign-in">
        <main class="sign-in-card">
          <h1>HIREME</h1>
          #{body}
        </main>
      </body>
    </html>
    """)
  end

  # A page that carries a token in its URL is not cached and sends no referrer.
  defp no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp esc(text), do: text |> Plug.HTML.html_escape() |> IO.iodata_to_binary()
end
