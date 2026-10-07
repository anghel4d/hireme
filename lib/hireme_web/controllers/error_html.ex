defmodule HiremeWeb.ErrorHTML do
  @moduledoc """
  Plain-text error pages, named by status.
  """

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
