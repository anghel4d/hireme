defmodule HiremeWeb.SignIn do
  @moduledoc """
  The ways in that are not a mailed link: GitHub and X over OAuth 2.0,
  the authorization code flow with PKCE (S256) and a `state` kept in
  this browser's encrypted cookie, spent on the first callback and good
  for ten minutes (RFC 9700 Sec. 2.1, 4.7; RFC 7636). The redirect URI
  comes from the endpoint's configured host, never from the request. A
  provider is offered when its client id and secret are set under
  `config :hireme, :oauth`.

  A provider proves one thing: the person holds that provider account.
  Its immutable user id is the identity's subject and its handle is for
  display. Nothing it says about an email address is read, so no account
  is ever reached or joined through an address a provider asserts.

  The same cookie carries the address the account lens asked to add
  (`expect_email/3`), so a mailed link adds an address only in the
  browser that asked, to the account that asked.
  """

  import Plug.Conn

  @strategies [github: HiremeWeb.SignIn.Github, x: HiremeWeb.SignIn.X]
  @trip "hireme_oauth"
  @expect "hireme_expect_email"

  @type provider :: :github | :x
  @type refusal :: :state | :expired | :denied | :provider

  @doc "The providers offered, in the order the page lists them."
  @spec providers() :: [provider()]
  def providers, do: for({p, _} <- @strategies, match?({:ok, _}, config(p)), do: p)

  @doc "An offered provider named in a path or a param, or `:error`."
  @spec parse(term()) :: {:ok, provider()} | :error
  def parse(name) do
    case Enum.find(providers(), &(Atom.to_string(&1) == name)) do
      nil -> :error
      provider -> {:ok, provider}
    end
  end

  @spec label(provider() | :email) :: String.t()
  def label(:github), do: "GitHub"
  def label(:x), do: "X"
  def label(:email), do: "Email"

  @doc "The URL a mailed link carries; the token rides in the query."
  @spec link_url(String.t()) :: String.t()
  def link_url(token),
    do: HiremeWeb.Endpoint.url() <> "/sign-in/email?" <> URI.encode_query(token: token)

  @doc """
  Start a round trip to `provider` for `mode`: the cookie keeps the
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
  this whatever the answer; it must be this provider's and fresh, and the
  provider must hand back the state it was given.
  """
  @spec finish(Plug.Conn.t(), provider(), map()) ::
          {Plug.Conn.t(), {:ok, map(), Hireme.Accounts.claim()} | {:error, refusal()}}
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

  defp claim(provider, %{"sub" => sub} = user)
       when (is_binary(sub) and sub != "") or is_integer(sub) do
    sub = to_string(sub)

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
  def expect_email(conn, email, account_id),
    do:
      put_session(conn, @expect, %{
        email: email,
        account_id: account_id,
        at: System.system_time(:second)
      })

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
           redirect_uri: HiremeWeb.Endpoint.url() <> "/auth/#{provider}/callback",
           code_verifier: true
         ] ++ Keyword.take(opts, [:http_adapter])}

      _ ->
        {:error, :not_configured}
    end
  end
end

defmodule HiremeWeb.SignIn.Github do
  @moduledoc false
  # GitHub's OAuth app flow with PKCE. No scope: the public profile is all
  # a sign-in needs, and the person's addresses are never asked for.
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
  # X's OAuth 2.0 (assent's Twitter strategy is 1.0a). A confidential client
  # authenticates with HTTP Basic at the token endpoint; /2/users/me takes
  # users.read with tweet.read.
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
  The sign-in pages. Passwordless: a mailed link, GitHub, or X. A visitor
  ends in `Hireme.Accounts.sign_in_with/3`, which finds the account or
  makes one; a browser that asked from the account lens ends in
  `Hireme.Accounts.link/3`.

  A mailed link is a GET that only shows where it leads; the POST its
  page sends spends it, so a mail scanner that follows every link spends
  nothing. A link adds an address only in the browser that asked for it;
  any other signed-in browser is told to sign out first, and the link
  stays good, or a link mailed to someone else could be opened here and
  join their address to this account. GitHub and X start here only for a
  visitor; adding them to an account starts from the account lens
  (`start_link/2`), behind a fresh second factor.
  """

  import Plug.Conn
  import HiremeWeb, only: [json: 2, redirect: 2]
  import HiremeWeb.Auth, only: [esc: 1, page: 4, csrf_field: 0, notice: 1, meta: 1]

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

  def index(%{assigns: %{account: %{}, pending: true}} = conn, _),
    do: redirect(conn, to: "/sign-in/factor")

  def index(%{assigns: %{account: %{}}} = conn, _), do: redirect(conn, to: "/")
  def index(conn, params), do: methods(conn, 200, Map.get(@notices, params["error"]))

  def request_email(%{assigns: %{account: %{}}} = conn, _), do: redirect(conn, to: "/")

  def request_email(conn, params) do
    email = if is_binary(params["email"]), do: params["email"], else: ""

    case Accounts.request_link(email, &SignIn.link_url/1, meta(conn)) do
      :ok ->
        {:ok, address} = Accounts.normalize_email(email)
        minutes = div(Hireme.Security.magic_link_ttl(), 60)

        page(conn, 200, "Check your email", """
        <p class="lede">A sign-in link is on its way to <strong>#{esc(address)}</strong>. It works once, for #{minutes} minutes.</p>
        <p class="lede">Nothing there? Look in spam, or <a href="/sign-in">ask for another</a>.</p>
        """)

      {:error, :invalid} ->
        methods(conn, 422, "Enter a whole email address, like you@example.com.")

      {:error, :rate_limited} ->
        methods(conn, 429, "Too many links were asked for. Wait a few minutes, then try again.")
    end
  end

  def confirm_email(conn, %{"token" => token}) when is_binary(token) do
    conn = put_resp_header(conn, "referrer-policy", "no-referrer")

    with {:ok, email} <- Accounts.peek_link(token),
         {:ok, mode} <- mode(conn, email) do
      {question, button} =
        case mode do
          :add -> {"Add #{email} to your account?", "Add this address"}
          :sign_in -> {"Sign in as #{email}?", "Sign in"}
        end

      page(conn, 200, button, """
      <p class="lede">#{esc(question)}</p>
      <form method="post" action="/sign-in/email/confirm" class="method">
        #{csrf_field()}
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

  def confirm_email(conn, _), do: redirect(conn, to: "/sign-in")

  def redeem_email(conn, %{"token" => token}) when is_binary(token) do
    with {:ok, email} <- Accounts.peek_link(token),
         {:ok, mode} <- mode(conn, email),
         :ok <-
           if(mode == :sign_in and not Accounts.room?(:email, email),
             do: {:error, :cap},
             else: :ok
           ),
         {:ok, ^email} <- Accounts.redeem_link(token, meta(conn)) do
      claim = %{subject: email, display: email}

      case mode do
        :add -> conn |> SignIn.forget_email() |> add(:email, claim)
        :sign_in -> enter(conn, :email, claim)
      end
    else
      {:error, :signed_in} ->
        signed_in(conn)

      {:error, :cap} ->
        methods(
          conn,
          409,
          "This account has too many open sessions; sign out of one, then try again. The link still works."
        )

      {:error, :rate_limited} ->
        methods(conn, 429, "Too many tries. Wait a few minutes.")

      _ ->
        methods(conn, 410, @notices["link"])
    end
  end

  def redeem_email(conn, _), do: redirect(conn, to: "/sign-in")

  defp mode(conn, email) do
    cond do
      SignIn.expected_email(conn) == email -> {:ok, :add}
      conn.assigns.account -> {:error, :signed_in}
      true -> {:ok, :sign_in}
    end
  end

  def authorize(%{assigns: %{account: %{}}} = conn, _), do: redirect(conn, to: "/")

  def authorize(conn, %{"provider" => name}) do
    with {:ok, provider} <- SignIn.parse(name),
         {:ok, conn, url} <- SignIn.begin(conn, provider, :sign_in) do
      redirect(conn, external: url)
    else
      :error -> send_resp(conn, 404, "Not Found")
      {:error, _} -> redirect(conn, to: "/sign-in?error=failed")
    end
  end

  def callback(conn, %{"provider" => name} = params) do
    ip = meta(conn).ip

    # A callback calls the provider and may sign someone in, write a session
    # and the trail: bounded per peer and in all, like the mailed link.
    with :ok <- Hireme.Security.limit(:oauth_peer, ip),
         :ok <- Hireme.Security.limit(:oauth_global, :all) do
      oauth_callback(conn, name, params)
    else
      {:error, :rate_limited} ->
        methods(conn, 429, "Too many sign-ins. Wait a few minutes, then try again.")
    end
  end

  defp oauth_callback(conn, name, params) do
    case SignIn.parse(name) do
      {:ok, provider} ->
        case SignIn.finish(conn, provider, params) do
          {conn, {:ok, %{mode: :link, account_id: id}, claim}} ->
            if here?(conn, id),
              do: add(conn, provider, claim),
              else: refuse(conn, provider, :state)

          {conn, {:ok, %{mode: :sign_in}, _claim}} when conn.assigns.account != nil ->
            redirect(conn, to: "/")

          {conn, {:ok, %{mode: :sign_in}, claim}} ->
            enter(conn, provider, claim)

          {conn, {:error, reason}} ->
            refuse(conn, provider, reason)
        end

      :error ->
        send_resp(conn, 404, "Not Found")
    end
  end

  @doc """
  Start adding a way in from the account lens (step-up gated, JSON):
  `{"provider": "github"|"x"}` answers the URL to navigate to;
  `{"provider": "email", "email": ...}` mails a link that adds the address
  in this browser only.
  """
  def start_link(conn, %{"provider" => "email", "email" => email}) do
    with {:ok, email} <- Accounts.normalize_email(email),
         :ok <- Accounts.request_link(email, &SignIn.link_url/1, meta(conn)) do
      conn |> SignIn.expect_email(email, conn.assigns.account.id) |> json(%{sent: true})
    else
      {:error, :rate_limited} -> conn |> put_status(429) |> json(%{error: "rate_limited"})
      {:error, _} -> conn |> put_status(422) |> json(%{error: "email"})
    end
  end

  def start_link(conn, %{"provider" => name}) do
    with {:ok, provider} <- SignIn.parse(name),
         {:ok, conn, url} <- SignIn.begin(conn, provider, :link) do
      json(conn, %{url: url})
    else
      _ -> conn |> put_status(422) |> json(%{error: "provider"})
    end
  end

  def start_link(conn, _), do: conn |> put_status(422) |> json(%{error: "provider"})

  def sign_out(conn, _), do: conn |> Auth.sign_out() |> redirect(to: "/sign-in")

  if Application.compile_env(:hireme, :dev_routes) do
    @doc "Development only: one click into a local account, through the same path a mailed link takes."
    def dev_sign_in(conn, _) do
      {:ok, token, _} =
        Accounts.sign_in_with(
          :email,
          %{subject: "dev@localhost", display: "dev@localhost"},
          meta(conn)
        )

      conn |> Auth.sign_in(token) |> redirect(to: "/")
    end
  end

  # The browser that started a link is still that account, past its factor.
  defp here?(conn, account_id),
    do: match?(%{id: ^account_id}, conn.assigns.account) and not conn.assigns.pending

  defp enter(conn, provider, claim) do
    case Accounts.sign_in_with(provider, claim, meta(conn)) do
      {:ok, token, _session} ->
        conn |> Auth.sign_in(token) |> redirect(to: "/")

      {:error, :suspended} ->
        methods(conn, 403, @notices["suspended"])

      {:error, :cap} ->
        methods(
          conn,
          409,
          "This account has too many open sessions; sign out of one, then try again."
        )
    end
  end

  defp add(conn, provider, claim) do
    case Accounts.link(provider, claim, meta(conn)) do
      {:ok, _} -> redirect(conn, to: "/account?" <> URI.encode_query(linked: provider))
      {:error, :taken} -> redirect(conn, to: "/account?link_error=taken")
      {:error, :cap} -> redirect(conn, to: "/account?link_error=cap")
    end
  end

  # Anyone can hit a callback; the trail takes a bounded number of their
  # refusals, so it cannot be grown or the writer held from outside.
  defp refuse(conn, provider, reason) do
    m = meta(conn)

    if Hireme.Security.limit(:refusal_peer, m.ip) == :ok,
      do: Audit.record(:sign_in_refused, %{provider: provider, reason: reason}, m)

    code = if reason == :denied, do: "denied", else: "failed"

    if conn.assigns.account,
      do: redirect(conn, to: "/account?link_error=" <> code),
      else: redirect(conn, to: "/sign-in?error=" <> code)
  end

  defp signed_in(conn) do
    page(conn, 409, "Signed in", """
    <p class="lede">This browser is signed in, and this link is for signing in. To use it, sign out first, then open the link again.</p>
    <form method="post" action="/sign-out" class="method">
      #{csrf_field()}
      <button type="submit" class="primary">Sign out</button>
    </form>
    <a class="ghost method" href="/">Back to the desk</a>
    """)
  end

  defp methods(conn, status, notice) do
    providers = SignIn.providers()
    ways = ["a link to your email" | Enum.map(providers, &SignIn.label/1)]

    page(conn, status, "Sign in", """
    <p class="lede">No passwords. Sign in with #{sentence(ways)}.</p>
    #{notice(notice)}
    <form method="post" action="/sign-in/email" class="method">
      #{csrf_field()}
      <label for="email">Email</label>
      <input id="email" type="email" name="email" autocomplete="email" required placeholder="you@example.com" />
      <button type="submit" class="primary">Send a sign-in link</button>
    </form>
    #{if providers != [], do: ~s(<p class="or">or</p>)}
    #{Enum.map_join(providers, "\n", &~s(<a class="ghost method" href="/auth/#{&1}">Continue with #{SignIn.label(&1)}</a>))}
    #{dev_sign_in()}
    """)
  end

  defp sentence([one]), do: one
  defp sentence([one, two]), do: "#{one} or #{two}"
  defp sentence(ways), do: Enum.join(Enum.drop(ways, -1), ", ") <> ", or " <> List.last(ways)

  defp dev_sign_in do
    if Application.get_env(:hireme, :dev_routes) do
      """
      <form method="post" action="/dev/sign-in" class="method">
        #{csrf_field()}
        <button type="submit" class="ghost">Sign in locally (development)</button>
      </form>
      """
    end
  end
end
