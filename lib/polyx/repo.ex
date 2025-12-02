defmodule Polyx.Repo do
  use Ecto.Repo,
    otp_app: :polyx,
    adapter: Ecto.Adapters.SQLite3
end
