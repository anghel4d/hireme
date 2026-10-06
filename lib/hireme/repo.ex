defmodule Hireme.Repo do
  use Ecto.Repo,
    otp_app: :hireme,
    adapter: Ecto.Adapters.SQLite3
end
