import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :polyx, Polyx.Repo,
  database: Path.expand("../polyx_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :polyx, PolyxWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "QrU5LBOXVGAufO3PFpp0i5L2MCBU84grb572lbMNHMWe0gmYLeDyTqCAvTBLPN/a",
  server: false

# In test we don't send emails
config :polyx, Polyx.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Polymarket API Configuration for tests
config :polyx, :polymarket,
  clob_url: "https://clob.polymarket.com",
  api_key: nil,
  api_secret: nil,
  api_passphrase: nil,
  wallet_address: nil,
  private_key: nil
