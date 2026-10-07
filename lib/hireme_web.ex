defmodule HiremeWeb do
  @moduledoc """
  Entry points for the web layer: `use HiremeWeb, :router` and
  `:verified_routes`. The page is drawn by the browser shell.
  """

  def static_paths, do: ~w(assets wasm fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: HiremeWeb.Endpoint,
        router: HiremeWeb.Router,
        statics: HiremeWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
