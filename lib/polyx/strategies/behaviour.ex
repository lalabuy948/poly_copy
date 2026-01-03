defmodule Polyx.Strategies.Behaviour do
  @moduledoc """
  Behaviour that all trading strategies must implement.

  ## Callbacks

  * `init/1` - Initialize strategy state with config
  * `handle_order/2` - Process incoming order data and return trading signals
  * `handle_tick/2` - Periodic tick for time-based logic (e.g., position checks)
  * `validate_config/1` - Validate strategy configuration

  ## Example

      defmodule MyStrategy do
        @behaviour Polyx.Strategies.Behaviour

        @impl true
        def init(config) do
          {:ok, %{config: config, state: :idle}}
        end

        @impl true
        def handle_order(order, state) do
          # Analyze order and potentially return a signal
          {:ok, state, []}
        end

        @impl true
        def handle_tick(state) do
          {:ok, state}
        end

        @impl true
        def validate_config(config) do
          if config["min_spread"], do: :ok, else: {:error, "min_spread required"}
        end
      end
  """

  @type order :: map()
  @type state :: map()
  @type config :: map()

  @type signal :: %{
          required(:action) => :buy | :sell,
          required(:token_id) => String.t(),
          required(:price) => float(),
          required(:size) => float(),
          optional(:reason) => String.t(),
          optional(:metadata) => map()
        }

  @doc """
  Initialize the strategy with its configuration.
  Returns initial state for the strategy runner.
  """
  @callback init(config()) :: {:ok, state()} | {:error, term()}

  @doc """
  Handle an incoming order/trade from the live feed.
  Returns updated state and optionally a list of trading signals.
  """
  @callback handle_order(order(), state()) ::
              {:ok, state()} | {:ok, state(), [signal()]} | {:error, term(), state()}

  @doc """
  Handle periodic tick for time-based operations.
  Called every N milliseconds based on strategy config.
  """
  @callback handle_tick(state()) :: {:ok, state()} | {:ok, state(), [signal()]}

  @doc """
  Validate strategy configuration before starting.
  """
  @callback validate_config(config()) :: :ok | {:error, String.t()}

  @doc """
  Returns the module for a strategy type.
  """
  def module_for_type(type) do
    case type do
      "time_decay" -> {:ok, Polyx.Strategies.TimeDecay}
      "delta_arb" -> {:ok, Polyx.Strategies.DeltaArb}
      _ -> {:error, "Unknown strategy type: #{type}"}
    end
  end

  @doc """
  Returns default config for a strategy type.

  Config options for filtering:
  - target_tokens: List of specific token IDs to watch
  - target_markets: List of market IDs (resolved to tokens)
  - watch_all: Set to true to watch all orders (use with caution!)

  By default, strategies watch nothing until you configure targets.
  """
  def default_config(type) do
    case type do
      "delta_arb" ->
        %{
          # Market type: "crypto", "sports", or "all"
          "market_type" => "crypto",
          # Market timeframe
          "market_timeframe" => "15m",
          # Minimum spread to enter (4% = $0.04 guaranteed profit per $1)
          "min_spread" => 0.04,
          # Order size in USD per leg (total = 2x)
          "order_size" => 10,
          # Maximum entries per event
          "max_entries_per_event" => 3,
          # Minimum minutes before resolution
          "min_minutes" => 1,
          # Cooldown between trades on same market (seconds)
          "cooldown_seconds" => 60,
          # Auto-discover markets
          "auto_discover" => true,
          # Discovery interval
          "discovery_interval_seconds" => 30,
          # Target tokens (empty for auto-discovery)
          "target_tokens" => [],
          "watch_all" => false
        }

      "time_decay" ->
        %{
          # Target price when current price > high_threshold
          "target_high_price" => 0.98,
          # Target price when current price < low_threshold
          "target_low_price" => 0.01,
          # Threshold above which we place high-price orders (85% for crypto)
          "high_threshold" => 0.85,
          # Threshold below which we place low-price orders (15% for crypto)
          "low_threshold" => 0.15,
          # Order size in USDC
          "order_size" => 10,
          # Cooldown between orders on same token (seconds)
          "cooldown_seconds" => 120,
          # Minimum spread tolerance
          "min_spread" => 0.02,
          # Use midpoint price for evaluation
          "use_midpoint" => true,
          # Maximum hours until resolution (for longer-term markets)
          "max_hours_to_resolution" => 24,
          # Maximum minutes until resolution - default 120 (2 hours) for crypto markets
          "max_minutes_to_resolution" => 120,
          # Minimum minutes before resolution (avoid last-second trades)
          "min_minutes_to_resolution" => 1,
          # Minimum profit threshold in USD
          "min_profit" => 0.05,
          # Enable proactive market scanning
          "scan_enabled" => false,
          # Number of markets to scan per tick
          "scan_limit" => 20,
          # Scan interval in seconds
          "scan_interval_seconds" => 60,
          # Only trade crypto-related markets (enabled by default)
          "crypto_only" => true,
          # Auto-discover and trade 15-min crypto markets (enabled by default)
          "auto_discover_crypto" => true,
          # Discovery interval in seconds (how often to scan for new crypto markets)
          "discovery_interval_seconds" => 30,
          # Target tokens to monitor (leave empty for auto-discovery mode)
          "target_tokens" => [],
          "watch_all" => false
        }

      _ ->
        %{}
    end
  end

  @doc """
  Returns a preset configuration for 15-minute crypto markets.
  This is the recommended configuration for auto-discovering and trading
  short-term crypto prediction markets on Polymarket.
  """
  def crypto_15min_preset do
    %{
      # Target price when current price > high_threshold
      "target_high_price" => 0.99,
      # Target price when current price < low_threshold
      "target_low_price" => 0.01,
      # Threshold above which we place high-price orders
      "high_threshold" => 0.85,
      # Threshold below which we place low-price orders
      "low_threshold" => 0.15,
      # Order size in USDC
      "order_size" => 10,
      # Cooldown between orders on same token (seconds) - shorter for fast markets
      "cooldown_seconds" => 120,
      # Minimum spread tolerance
      "min_spread" => 0.02,
      # Use midpoint price for evaluation
      "use_midpoint" => true,
      # Minutes-based filtering for 15-min markets
      "max_minutes_to_resolution" => 15,
      # Avoid trades in final minute (oracle resolution risk)
      "min_minutes_to_resolution" => 1,
      # Minimum profit threshold in USD
      "min_profit" => 0.05,
      # Disable general scanning (use crypto discovery instead)
      "scan_enabled" => false,
      # Only trade crypto-related markets
      "crypto_only" => true,
      # Enable auto-discovery of 15-min crypto markets
      "auto_discover_crypto" => true,
      # Scan for new markets every 30 seconds
      "discovery_interval_seconds" => 30,
      # Empty - auto-discovery will populate
      "target_tokens" => [],
      "watch_all" => false
    }
  end

  @doc """
  Returns human-readable name for strategy type.
  """
  def display_name(type) do
    case type do
      "time_decay" -> "Time Decay"
      "delta_arb" -> "Delta Arb"
      _ -> type
    end
  end

  @doc """
  Returns available strategy types.
  """
  def available_types do
    [
      {"time_decay", "Time Decay", "Capture final price movement near event resolution"},
      {"delta_arb", "Delta Arb", "Risk-free arbitrage by buying both sides below $1.00"}
    ]
  end

  @doc """
  Returns available presets for a strategy type.
  """
  def available_presets(type) do
    case type do
      "time_decay" ->
        [
          {"crypto_15min", "15-Min Crypto", "Auto-discover and trade 15-minute crypto markets"}
        ]

      "delta_arb" ->
        [
          {"crypto_15min", "15-Min Crypto Arb",
           "Arbitrage on 15-minute crypto prediction markets"},
          {"crypto_1h", "1-Hour Crypto Arb", "Arbitrage on hourly crypto prediction markets"},
          {"sports", "Sports Arb", "Arbitrage on sports betting markets"}
        ]

      _ ->
        []
    end
  end
end
