defmodule HiremeWeb.PageController do
  @moduledoc """
  The one document. Everything on it is drawn by the shell from the
  resident columns; this page is the shell's host.
  """

  use Phoenix.Controller, formats: [:html]

  use Phoenix.VerifiedRoutes,
    endpoint: HiremeWeb.Endpoint,
    router: HiremeWeb.Router,
    statics: HiremeWeb.static_paths()

  import Plug.Conn

  def index(conn, _params) do
    page = """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Desk · Hireme</title>
        <link rel="stylesheet" href="#{~p"/assets/js/app.css"}" />
        <script defer type="module" src="#{~p"/assets/js/app.js"}"></script>
      </head>
      <body>
        <div id="desk" class="desk"></div>
      </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page)
  end
end
