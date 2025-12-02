import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# Load .env file if it exists (for development, not tests)
if config_env() != :test and File.exists?(".env") do
  File.read!(".env")
  |> String.split("\n")
  |> Enum.each(fn line ->
    line = String.trim(line)

    unless line == "" or String.starts_with?(line, "#") do
      case String.split(line, "=", parts: 2) do
        [key, value] ->
          key = String.trim(key)
          value = String.trim(value)
          # Only set if not already set in environment
          unless System.get_env(key) do
            System.put_env(key, value)
          end

        _ ->
          :ok
      end
    end
  end)
end

# Polymarket API Configuration
config :polyx, :polymarket,
  clob_url: System.get_env("POLYMARKET_CLOB_URL") || "https://clob.polymarket.com",
  api_key: System.get_env("POLYMARKET_API_KEY"),
  api_secret: System.get_env("POLYMARKET_API_SECRET"),
  api_passphrase: System.get_env("POLYMARKET_API_PASSPHRASE"),
  wallet_address: System.get_env("POLYMARKET_WALLET_ADDRESS"),
  signer_address: System.get_env("POLYMARKET_SIGNER_ADDRESS"),
  private_key: System.get_env("POLYMARKET_PRIVATE_KEY")

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/polyx start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :polyx, PolyxWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") || Path.expand("../polyx.db", __DIR__)

  config :polyx, Polyx.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      "AaR7ZRXC3NM3XykTdW8CgqIK8sLqr7Y9Boz6OS+JKfcCfh0yd3w2JR5vgMLZGHYE"

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :polyx, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :polyx, PolyxWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    check_origin: false,
    secret_key_base: secret_key_base,
    server: true
end
