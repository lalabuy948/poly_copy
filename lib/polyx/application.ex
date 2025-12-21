defmodule Polyx.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      PolyxWeb.Telemetry,
      Polyx.Repo,
      {Ecto.Migrator, repos: Application.fetch_env!(:polyx, :ecto_repos), skip: false},
      {Phoenix.PubSub, name: Polyx.PubSub},
      # API rate limiter (must start before clients)
      Polyx.Polymarket.RateLimiter,
      # Cache for Gamma market lookups
      Polyx.Polymarket.GammaCache,
      # Cache for credentials
      Polyx.Credentials.Cache,
      # Copy trading GenServers
      Polyx.CopyTrading.TradeWatcher,
      Polyx.CopyTrading.TradeExecutor,
      # Live orders WebSocket client
      Polyx.Polymarket.LiveOrders,
      # Strategy engine (supervisor for strategy runners)
      {Polyx.Strategies.Engine, []},
      # Start to serve requests, typically the last entry
      PolyxWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Polyx.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Auto-recover strategies after supervision tree is up
    schedule_strategy_recovery()

    result
  end

  # Schedule auto-recovery of strategies that were running before shutdown
  defp schedule_strategy_recovery do
    Task.start(fn ->
      # Wait for Engine to be fully ready
      Process.sleep(2_000)
      Logger.info("[Application] Auto-recovering strategies that were running before shutdown...")
      Polyx.Strategies.Engine.auto_start_strategies()
    end)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PolyxWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # defp skip_migrations?() do
  #   # By default, sqlite migrations are run when using a release
  #   System.get_env("RELEASE_NAME") == nil
  # end
end
