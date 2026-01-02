defmodule Polyx.Strategies.DeltaArb.Config do
  @moduledoc """
  Configuration for Delta-Neutral Arbitrage strategy.

  This strategy buys BOTH sides (YES + NO) of binary markets simultaneously
  when the combined cost is significantly below $1.00, locking in guaranteed
  profit upon resolution.
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

  @market_types ["crypto", "sports", "all"]

  def timeframe_presets, do: @timeframe_presets
  def market_types, do: @market_types

  @primary_key false
  embedded_schema do
    # Market type - what kind of events to discover
    field :market_type, :string, default: "crypto"

    # Market timeframes - which markets to watch (supports multiple)
    # Stored as comma-separated string for Ecto compatibility
    field :market_timeframes, :string, default: "15m"

    # Minimum spread required to enter (e.g., 0.04 = 4% guaranteed profit)
    field :min_spread, :float, default: 0.04

    # Order size in USD per leg (total investment = 2x this amount)
    field :order_size, :float, default: 10.0

    # Maximum number of times to enter the same event
    field :max_entries_per_event, :integer, default: 3

    # Minimum minutes before resolution to trade
    field :min_minutes, :float, default: 1.0

    # Cooldown between trades on same market (seconds)
    field :cooldown_seconds, :integer, default: 60
  end

  @doc """
  Returns hardcoded defaults merged with timeframe-specific settings.
  """
  def defaults(timeframe \\ "15m") do
    preset = Map.get(@timeframe_presets, timeframe, @timeframe_presets["15m"])

    %{
      "max_minutes_to_resolution" => preset.max_minutes,
      "min_minutes_to_resolution" => preset.min_minutes,
      "auto_discover" => true,
      "discovery_interval_seconds" => discovery_interval_for(timeframe),
      "min_liquidity" => 100
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
    # Handle multi-select timeframes from form (comes as list or map)
    attrs = normalize_timeframes_attr(attrs)

    config
    |> cast(attrs, [
      :market_type,
      :market_timeframes,
      :min_spread,
      :order_size,
      :max_entries_per_event,
      :min_minutes,
      :cooldown_seconds
    ])
    |> validate_inclusion(:market_type, @market_types)
    |> validate_timeframes()
    |> validate_number(:min_spread,
      greater_than_or_equal_to: 0.01,
      less_than_or_equal_to: 0.20
    )
    |> validate_number(:order_size, greater_than: 0)
    |> validate_number(:max_entries_per_event, greater_than_or_equal_to: 1)
    |> validate_number(:cooldown_seconds, greater_than_or_equal_to: 0)
  end

  # Normalize timeframes from form input (checkbox map) to comma-separated string
  defp normalize_timeframes_attr(attrs) when is_map(attrs) do
    case Map.get(attrs, "market_timeframes") || Map.get(attrs, :market_timeframes) do
      # Checkbox form: %{"15m" => "true", "1h" => "true"}
      timeframes when is_map(timeframes) ->
        selected =
          timeframes
          |> Enum.filter(fn {_k, v} -> v == "true" || v == true end)
          |> Enum.map(fn {k, _v} -> k end)
          |> Enum.filter(&(&1 in Map.keys(@timeframe_presets)))

        value = if selected == [], do: "15m", else: Enum.join(selected, ",")
        Map.put(attrs, "market_timeframes", value)

      # Already a list
      timeframes when is_list(timeframes) ->
        valid = Enum.filter(timeframes, &(&1 in Map.keys(@timeframe_presets)))
        value = if valid == [], do: "15m", else: Enum.join(valid, ",")
        Map.put(attrs, "market_timeframes", value)

      # Already a string (comma-separated or single)
      _ ->
        attrs
    end
  end

  defp normalize_timeframes_attr(attrs), do: attrs

  defp validate_timeframes(changeset) do
    validate_change(changeset, :market_timeframes, fn :market_timeframes, value ->
      timeframes = parse_timeframes(value)
      valid_keys = Map.keys(@timeframe_presets)

      invalid = Enum.reject(timeframes, &(&1 in valid_keys))

      if invalid == [] do
        []
      else
        [{:market_timeframes, "contains invalid timeframes: #{Enum.join(invalid, ", ")}"}]
      end
    end)
  end

  @doc """
  Parses comma-separated timeframes string into list.
  """
  def parse_timeframes(nil), do: ["15m"]
  def parse_timeframes(""), do: ["15m"]

  def parse_timeframes(str) when is_binary(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
  end

  def parse_timeframes(list) when is_list(list), do: list

  @doc """
  Creates a new config struct from a map (e.g., from database JSON).
  """
  def from_map(nil), do: %__MODULE__{}

  def from_map(map) when is_map(map) do
    # Support legacy "market_timeframe" field by converting to "market_timeframes"
    map = migrate_legacy_timeframe(map)

    attrs =
      map
      |> Enum.map(fn {k, v} ->
        key = if is_binary(k), do: safe_to_atom(k), else: k
        {key, v}
      end)
      |> Enum.filter(fn {k, _v} ->
        k in [
          :market_type,
          :market_timeframes,
          :min_spread,
          :order_size,
          :max_entries_per_event,
          :min_minutes,
          :cooldown_seconds
        ]
      end)
      |> Map.new()

    struct(__MODULE__, attrs)
  end

  # Migrate legacy single timeframe to new multi-timeframe format
  defp migrate_legacy_timeframe(map) do
    cond do
      # Already has new field
      Map.has_key?(map, "market_timeframes") or Map.has_key?(map, :market_timeframes) ->
        map

      # Has legacy field - convert it
      Map.has_key?(map, "market_timeframe") ->
        map
        |> Map.put("market_timeframes", map["market_timeframe"])
        |> Map.delete("market_timeframe")

      Map.has_key?(map, :market_timeframe) ->
        map
        |> Map.put(:market_timeframes, map[:market_timeframe])
        |> Map.delete(:market_timeframe)

      true ->
        map
    end
  end

  defp safe_to_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  @doc """
  Converts config to a full map for DeltaArb strategy (includes hardcoded values).
  """
  def to_strategy_config(%__MODULE__{} = config) do
    timeframes = parse_timeframes(config.market_timeframes)

    # Use the most aggressive (smallest) timeframe for defaults
    primary_timeframe = List.first(timeframes) || "15m"
    preset = Map.get(@timeframe_presets, primary_timeframe, @timeframe_presets["15m"])

    # Calculate max_minutes based on largest selected timeframe
    max_minutes =
      timeframes
      |> Enum.map(fn tf ->
        Map.get(@timeframe_presets, tf, @timeframe_presets["15m"]).max_minutes
      end)
      |> Enum.max(fn -> 15 end)

    # Use custom min_minutes if set, otherwise use preset default
    min_minutes = config.min_minutes || preset.min_minutes

    defaults(primary_timeframe)
    |> Map.merge(%{
      "market_type" => config.market_type || "crypto",
      "market_timeframes" => timeframes,
      "max_minutes_to_resolution" => max_minutes,
      "min_spread" => config.min_spread || 0.04,
      "order_size" => config.order_size || 10.0,
      "max_entries_per_event" => config.max_entries_per_event || 3,
      "min_minutes" => min_minutes,
      "min_minutes_to_resolution" => 1,
      "cooldown_seconds" => config.cooldown_seconds || 60
    })
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
  end

  @doc """
  Converts a config struct to a map with string keys (for database storage).
  """
  def to_map(%__MODULE__{} = config) do
    %{
      "market_type" => config.market_type || "crypto",
      "market_timeframes" => config.market_timeframes || "15m",
      "min_spread" => config.min_spread,
      "order_size" => config.order_size,
      "max_entries_per_event" => config.max_entries_per_event,
      "min_minutes" => config.min_minutes,
      "cooldown_seconds" => config.cooldown_seconds
    }
  end

  @doc """
  Helper to check if a timeframe is selected.
  """
  def timeframe_selected?(config, timeframe) do
    timeframes = parse_timeframes(config.market_timeframes)
    timeframe in timeframes
  end
end
