defmodule Polyx.Strategies.Config do
  @moduledoc """
  Embedded schema for Time Decay strategy configuration.
  Provides proper form handling and validation for strategy settings.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Price thresholds
    field :target_high_price, :float, default: 0.99
    field :target_low_price, :float, default: 0.01
    field :high_threshold, :float, default: 0.85
    field :low_threshold, :float, default: 0.15

    # Order settings
    field :order_size, :float, default: 10.0
    field :cooldown_seconds, :integer, default: 120
    field :min_spread, :float, default: 0.02
    field :min_profit, :float, default: 0.05

    # Time-based filtering
    field :max_hours_to_resolution, :integer, default: 24
    field :max_minutes_to_resolution, :integer, default: 120
    field :min_minutes_to_resolution, :integer, default: 1

    # Scanning settings
    field :scan_enabled, :boolean, default: false
    field :scan_interval_seconds, :integer, default: 60
    field :scan_limit, :integer, default: 20

    # Crypto auto-discovery (enabled by default for 15-min crypto)
    field :auto_discover_crypto, :boolean, default: true
    field :crypto_only, :boolean, default: true
    field :discovery_interval_seconds, :integer, default: 30

    # Price evaluation
    field :use_midpoint, :boolean, default: true

    # Token selection
    field :watch_all, :boolean, default: false
    field :target_tokens, {:array, :string}, default: []
  end

  @doc """
  Creates a changeset for config validation.
  """
  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :target_high_price,
      :target_low_price,
      :high_threshold,
      :low_threshold,
      :order_size,
      :cooldown_seconds,
      :min_spread,
      :min_profit,
      :max_hours_to_resolution,
      :max_minutes_to_resolution,
      :min_minutes_to_resolution,
      :scan_enabled,
      :scan_interval_seconds,
      :scan_limit,
      :auto_discover_crypto,
      :crypto_only,
      :discovery_interval_seconds,
      :use_midpoint,
      :watch_all,
      :target_tokens
    ])
    |> validate_number(:target_high_price,
      greater_than_or_equal_to: 0.9,
      less_than_or_equal_to: 1.0
    )
    |> validate_number(:target_low_price,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 0.1
    )
    |> validate_number(:high_threshold, greater_than_or_equal_to: 0.5, less_than_or_equal_to: 1.0)
    |> validate_number(:low_threshold, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 0.5)
    |> validate_number(:order_size, greater_than: 0)
    |> validate_number(:cooldown_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:min_spread, greater_than_or_equal_to: 0)
    |> validate_number(:min_profit, greater_than_or_equal_to: 0)
  end

  @doc """
  Creates a new config struct from a map (e.g., from database JSON).
  """
  def from_map(nil), do: %__MODULE__{}

  def from_map(map) when is_map(map) do
    # Convert string keys to atoms for struct creation
    attrs =
      map
      |> Enum.map(fn {k, v} ->
        key = if is_binary(k), do: String.to_existing_atom(k), else: k
        {key, v}
      end)
      |> Enum.filter(fn {k, _v} ->
        k in [
          :target_high_price,
          :target_low_price,
          :high_threshold,
          :low_threshold,
          :order_size,
          :cooldown_seconds,
          :min_spread,
          :min_profit,
          :max_hours_to_resolution,
          :max_minutes_to_resolution,
          :min_minutes_to_resolution,
          :scan_enabled,
          :scan_interval_seconds,
          :scan_limit,
          :auto_discover_crypto,
          :crypto_only,
          :discovery_interval_seconds,
          :use_midpoint,
          :watch_all,
          :target_tokens
        ]
      end)
      |> Map.new()

    struct(__MODULE__, attrs)
  rescue
    ArgumentError -> %__MODULE__{}
  end

  @doc """
  Converts a config struct to a map with string keys (for database storage).
  """
  def to_map(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Map.new()
  end

  @doc """
  Returns the preset configuration for 15-minute crypto markets.
  """
  def crypto_15min_preset do
    %__MODULE__{
      target_high_price: 0.99,
      target_low_price: 0.01,
      high_threshold: 0.85,
      low_threshold: 0.15,
      order_size: 10.0,
      cooldown_seconds: 120,
      min_spread: 0.02,
      use_midpoint: true,
      max_minutes_to_resolution: 15,
      min_minutes_to_resolution: 1,
      min_profit: 0.05,
      scan_enabled: false,
      crypto_only: true,
      auto_discover_crypto: true,
      discovery_interval_seconds: 30,
      target_tokens: [],
      watch_all: false
    }
  end
end
