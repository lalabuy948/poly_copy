defmodule Polyx.Strategies.Config do
  @moduledoc """
  Simplified configuration for Time Decay strategy.
  Only exposes essential controls - everything else is hardcoded.
  """
  use Ecto.Schema
  import Ecto.Changeset

  # Market timeframe presets (in minutes)
  @timeframe_presets %{
    "15m" => %{max_minutes: 15, min_minutes: 1, label: "15 Minutes"},
    "1h" => %{max_minutes: 60, min_minutes: 5, label: "1 Hour"},
    "4h" => %{max_minutes: 240, min_minutes: 15, label: "4 Hours"},
    "daily" => %{max_minutes: 1440, min_minutes: 60, label: "Daily"}
  }

  def timeframe_presets, do: @timeframe_presets

  @primary_key false
  embedded_schema do
    # Market timeframe - which crypto markets to watch
    field :market_timeframe, :string, default: "15m"

    # Signal threshold - buy when price exceeds this (e.g., 0.80 = 80%)
    field :signal_threshold, :float, default: 0.80

    # Order size in USD
    field :order_size, :float, default: 5.0

    # Minimum minutes before resolution to trade (overrides preset if set)
    field :min_minutes, :float, default: nil

    # Cooldown between trades on same market (seconds)
    field :cooldown_seconds, :integer, default: 60

    # Use limit order or market order (buy at current best ask)
    field :use_limit_order, :boolean, default: true

    # Limit price when use_limit_order is true (e.g., 0.99, 0.989, 0.999)
    field :limit_price, :float, default: 0.99
  end

  # Hardcoded settings (not exposed in UI)
  def defaults(timeframe \\ "15m") do
    preset = Map.get(@timeframe_presets, timeframe, @timeframe_presets["15m"])

    %{
      # Max minutes to resolution for crypto markets (from preset)
      max_minutes_to_resolution: preset.max_minutes,
      # Min minutes from preset (can be overridden)
      min_minutes_to_resolution: preset.min_minutes,
      # Always use midpoint for price evaluation
      use_midpoint: true,
      # Auto-discover crypto markets
      auto_discover_crypto: true,
      crypto_only: true,
      # Discovery interval (longer for longer timeframes)
      discovery_interval_seconds: discovery_interval_for(timeframe),
      # Minimum profit threshold
      min_profit: 0.01,
      # Scanning disabled (WebSocket provides prices)
      scan_enabled: false
    }
  end

  defp discovery_interval_for("15m"), do: 30
  defp discovery_interval_for("1h"), do: 60
  defp discovery_interval_for("4h"), do: 120
  defp discovery_interval_for("daily"), do: 300
  defp discovery_interval_for(_), do: 30

  @doc """
  Creates a changeset for config validation.
  """
  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :market_timeframe,
      :signal_threshold,
      :order_size,
      :min_minutes,
      :cooldown_seconds,
      :use_limit_order,
      :limit_price
    ])
    |> validate_inclusion(:market_timeframe, Map.keys(@timeframe_presets))
    |> validate_number(:signal_threshold,
      greater_than_or_equal_to: 0.5,
      less_than_or_equal_to: 0.99
    )
    |> validate_number(:order_size, greater_than: 0)
    |> validate_number(:cooldown_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:limit_price,
      greater_than_or_equal_to: 0.90,
      less_than_or_equal_to: 1.0
    )
  end

  @doc """
  Creates a new config struct from a map (e.g., from database JSON).
  Merges with hardcoded defaults.
  """
  def from_map(nil), do: %__MODULE__{}

  def from_map(map) when is_map(map) do
    attrs =
      map
      |> Enum.map(fn {k, v} ->
        key = if is_binary(k), do: safe_to_atom(k), else: k
        {key, v}
      end)
      |> Enum.filter(fn {k, _v} ->
        k in [
          :market_timeframe,
          :signal_threshold,
          :order_size,
          :min_minutes,
          :cooldown_seconds,
          :use_limit_order,
          :limit_price
        ]
      end)
      |> Map.new()

    struct(__MODULE__, attrs)
  end

  defp safe_to_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  @doc """
  Converts config to a full map for TimeDecay strategy (includes hardcoded values).
  """
  def to_strategy_config(%__MODULE__{} = config) do
    timeframe = config.market_timeframe || "15m"
    preset = Map.get(@timeframe_presets, timeframe, @timeframe_presets["15m"])

    # Use custom min_minutes if set, otherwise use preset default
    min_minutes = config.min_minutes || preset.min_minutes

    defaults(timeframe)
    |> Map.merge(%{
      "signal_threshold" => config.signal_threshold,
      "high_threshold" => config.signal_threshold,
      "order_size" => config.order_size,
      "min_minutes" => min_minutes,
      # Keep discovery filter low (1 min) so markets aren't removed before signals can fire
      "min_minutes_to_resolution" => 1,
      "cooldown_seconds" => config.cooldown_seconds,
      "use_limit_order" => config.use_limit_order,
      "limit_price" => config.limit_price,
      "target_high_price" => config.limit_price,
      "market_timeframe" => timeframe
    })
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
  end

  @doc """
  Converts a config struct to a map with string keys (for database storage).
  """
  def to_map(%__MODULE__{} = config) do
    %{
      "market_timeframe" => config.market_timeframe || "15m",
      "signal_threshold" => config.signal_threshold,
      "order_size" => config.order_size,
      "min_minutes" => config.min_minutes,
      "cooldown_seconds" => config.cooldown_seconds,
      "use_limit_order" => config.use_limit_order,
      "limit_price" => config.limit_price
    }
  end
end
