defmodule HiremeWeb.Router do
  use HiremeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HiremeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HiremeWeb do
    pipe_through :browser

    live "/", BoardLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", HiremeWeb do
  #   pipe_through :api
  # end
end
