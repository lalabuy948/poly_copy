defmodule Polyx.Strategies.Config do
  @moduledoc """
  Simplified configuration for Time Decay strategy.
  Only exposes essential controls - everything else is hardcoded.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Signal threshold - buy when price exceeds this (e.g., 0.80 = 80%)
    field :signal_threshold, :float, default: 0.80

    # Order size in shares (integer)
    field :order_size, :integer, default: 10

    # Only trade when market has at least this many minutes until resolution
    field :min_minutes, :float, default: 3.0

    # Cooldown between trades on same market (seconds)
    field :cooldown_seconds, :integer, default: 60

    # Use limit order or market order (buy at current best ask)
    field :use_limit_order, :boolean, default: true

    # Limit price when use_limit_order is true (e.g., 0.98, 0.99, 0.989)
    field :limit_price, :float, default: 0.98
  end

  # Hardcoded settings (not exposed in UI)
  def defaults do
    %{
      # Max minutes to resolution for crypto markets
      max_minutes_to_resolution: 15,
      # Always use midpoint for price evaluation
      use_midpoint: true,
      # Auto-discover 15-min crypto markets
      auto_discover_crypto: true,
      crypto_only: true,
      # Discovery interval
      discovery_interval_seconds: 30,
      # Minimum profit threshold
      min_profit: 0.01,
      # Scanning disabled (WebSocket provides prices)
      scan_enabled: false
    }
  end

  @doc """
  Creates a changeset for config validation.
  """
  def changeset(config, attrs) do
    # Convert string "true"/"false" from radio buttons to boolean
    attrs =
      case attrs["use_limit_order"] do
        "true" -> Map.put(attrs, "use_limit_order", true)
        "false" -> Map.put(attrs, "use_limit_order", false)
        _ -> attrs
      end

    config
    |> cast(attrs, [
      :signal_threshold,
      :order_size,
      :min_minutes,
      :cooldown_seconds,
      :use_limit_order,
      :limit_price
    ])
    |> validate_number(:signal_threshold,
      greater_than_or_equal_to: 0.5,
      less_than_or_equal_to: 0.99
    )
    |> validate_number(:order_size, greater_than: 0)
    |> validate_number(:min_minutes, greater_than_or_equal_to: 0)
    |> validate_number(:cooldown_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:limit_price,
      greater_than_or_equal_to: 0.90,
      less_than_or_equal_to: 0.999,
      message: "must be between 0.90 and 0.999 (we only buy high-confidence tokens)"
    )
    |> validate_required([:order_size])
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
    defaults()
    |> Map.merge(%{
      "high_threshold" => config.signal_threshold,
      "order_size" => config.order_size,
      "min_minutes_to_resolution" => config.min_minutes,
      "use_limit_order" => config.use_limit_order,
      "target_high_price" => config.limit_price
    })
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
  end

  @doc """
  Converts a config struct to a map with string keys (for database storage).
  """
  def to_map(%__MODULE__{} = config) do
    %{
      "signal_threshold" => config.signal_threshold,
      "order_size" => config.order_size,
      "min_minutes" => config.min_minutes,
      "cooldown_seconds" => config.cooldown_seconds,
      "use_limit_order" => config.use_limit_order,
      "limit_price" => config.limit_price
    }
  end
end
