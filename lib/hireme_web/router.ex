defmodule HiremeWeb.Router do
  use HiremeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HiremeWeb do
    pipe_through :browser

    get "/", PageController, :index
  end

  scope "/api", HiremeWeb do
    pipe_through :api

    get "/pack", DeskController, :pack
    get "/scoreboard", DeskController, :scoreboard
    get "/focus/:id", DeskController, :focus
    get "/root/:id", DeskController, :root
    post "/jobs/:id/stage", DeskController, :set_stage
    post "/jobs/:id/next", DeskController, :set_next
    post "/jobs/:id/note", DeskController, :set_note
    post "/jobs/:id/score", DeskController, :set_score
    post "/jobs/:id/overlay", DeskController, :put_overlay
    post "/batches/:code/open_fire", DeskController, :name_open_fire
    post "/narratives/:id", DeskController, :save_narrative
  end
end
