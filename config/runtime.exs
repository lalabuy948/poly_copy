import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

if System.get_env("PHX_SERVER") do
  config :polyx, PolyxWeb.Endpoint, server: true
end

if config_env() == :prod do
  # Database is created next to the binary itself
  # __BURRITO_BIN_PATH is set by Burrito to the original binary location
  default_db_path =
    case System.get_env("__BURRITO_BIN_PATH") do
      nil ->
        "./polyx_dev.db"

      binary_path ->
        binary_path
        |> Path.dirname()
        |> Path.join("polyx.db")
    end

  database_path = System.get_env("DATABASE_PATH") || default_db_path

  config :polyx, Polyx.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      "AaR7ZRXC3NM3XykTdW8CgqIK8sLqr7Y9Boz6OS+JKfcCfh0yd3w2JR5vgMLZGHYE"

  # host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :polyx, PolyxWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: port],
    check_origin: false,
    secret_key_base: secret_key_base,
    server: true
end
