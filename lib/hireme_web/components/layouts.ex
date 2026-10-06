defmodule HiremeWeb.Layouts do
  @moduledoc """
  Root document shell. The desk draws its own chrome.
  """
  use HiremeWeb, :html

  embed_templates "layouts/*"
end
