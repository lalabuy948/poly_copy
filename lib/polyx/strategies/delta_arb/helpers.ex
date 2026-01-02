defmodule Polyx.Strategies.DeltaArb.Helpers do
  @moduledoc """
  Helper functions for Delta-Neutral Arbitrage strategy.
  Includes price calculations, profit estimation, and validation utilities.
  """

  # Estimated fee percentage (gas + slippage)
  @estimated_fee_rate 0.02

  @doc """
  Calculate the combined cost of buying both YES and NO tokens.
  Returns nil if either price is missing.
  """
  def calculate_combined_cost(nil, _), do: nil
  def calculate_combined_cost(_, nil), do: nil

  def calculate_combined_cost(yes_ask, no_ask) when is_number(yes_ask) and is_number(no_ask) do
    yes_ask + no_ask
  end

  @doc """
  Calculate the spread (guaranteed profit per share before fees).
  Spread = 1.0 - combined_cost
  """
  def calculate_spread(combined_cost) when is_number(combined_cost) do
    1.0 - combined_cost
  end

  def calculate_spread(_), do: nil

  @doc """
  Calculate guaranteed profit for a position.

  Args:
    - combined_cost: Total cost per share of both legs
    - order_size_per_leg: USD amount per leg
    - fee_rate: Estimated fee rate (default 2%)

  Returns map with profit details or nil if invalid.
  """
  def calculate_guaranteed_profit(
        combined_cost,
        order_size_per_leg,
        fee_rate \\ @estimated_fee_rate
      )

  def calculate_guaranteed_profit(combined_cost, order_size_per_leg, fee_rate)
      when is_number(combined_cost) and is_number(order_size_per_leg) do
    spread = calculate_spread(combined_cost)

    if spread > 0 do
      # Calculate shares we can buy per leg
      # We need equal shares on both sides, so use the higher ask price to determine shares
      total_investment = order_size_per_leg * 2

      # Shares = total_investment / combined_cost
      shares = total_investment / combined_cost

      # Guaranteed payout = shares * $1.00 (one side wins)
      payout = shares * 1.0

      # Gross profit
      gross_profit = payout - total_investment

      # Estimated fees
      fees = total_investment * fee_rate

      # Net profit
      net_profit = gross_profit - fees

      %{
        spread: spread,
        spread_pct: spread * 100,
        shares: shares,
        total_investment: total_investment,
        payout: payout,
        gross_profit: gross_profit,
        fees: fees,
        net_profit: net_profit,
        roi_pct: net_profit / total_investment * 100
      }
    else
      nil
    end
  end

  def calculate_guaranteed_profit(_, _, _), do: nil

  @doc """
  Check if an arbitrage opportunity is valid.
  """
  def is_valid_arb_opportunity?(combined_cost, min_spread, min_minutes, minutes_to_resolution) do
    spread = calculate_spread(combined_cost)

    cond do
      is_nil(spread) -> false
      spread < min_spread -> false
      is_nil(minutes_to_resolution) -> false
      minutes_to_resolution <= 0 -> false
      minutes_to_resolution < min_minutes -> false
      # Max combined cost check (must be less than $1.00)
      combined_cost >= 1.0 -> false
      true -> true
    end
  end

  @doc """
  Calculate minutes until market resolution.
  """
  def calculate_minutes_to_resolution(nil), do: nil

  def calculate_minutes_to_resolution(end_date) do
    case parse_end_date(end_date) do
      {:ok, end_dt} ->
        now = DateTime.utc_now()
        seconds = DateTime.diff(end_dt, now, :second)
        if seconds > 0, do: seconds / 60, else: 0.0

      _ ->
        nil
    end
  end

  @doc """
  Parse end date from various formats.
  """
  def parse_end_date(nil), do: {:error, nil}

  def parse_end_date(end_date) when is_binary(end_date) do
    case DateTime.from_iso8601(end_date) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, _} ->
        case Integer.parse(end_date) do
          {ts, _} -> {:ok, DateTime.from_unix!(ts)}
          :error -> {:error, :invalid_format}
        end
    end
  end

  def parse_end_date(end_date) when is_integer(end_date) do
    {:ok, DateTime.from_unix!(end_date)}
  end

  def parse_end_date(%DateTime{} = dt), do: {:ok, dt}
  def parse_end_date(_), do: {:error, :invalid_format}

  @doc """
  Parse price from various formats.
  """
  def parse_price(nil), do: nil
  def parse_price(price) when is_number(price), do: price

  def parse_price(price) when is_binary(price) do
    case Float.parse(price) do
      {val, _} -> val
      :error -> nil
    end
  end

  @doc """
  Check if market is crypto-related.
  """
  def is_crypto_market?(market_info) do
    question = String.downcase(market_info[:question] || "")
    event_title = String.downcase(market_info[:event_title] || "")

    crypto_keywords = [
      "bitcoin",
      "btc",
      "ethereum",
      "eth",
      "crypto",
      "solana",
      "sol",
      "xrp",
      "doge"
    ]

    Enum.any?(crypto_keywords, fn kw ->
      String.contains?(question, kw) or String.contains?(event_title, kw)
    end)
  end

  @doc """
  Check if market is sports-related.
  """
  def is_sports_market?(market_info) do
    question = String.downcase(market_info[:question] || "")
    event_title = String.downcase(market_info[:event_title] || "")

    sports_keywords = [
      "nfl",
      "nba",
      "mlb",
      "nhl",
      "soccer",
      "football",
      "basketball",
      "baseball",
      "hockey",
      "championship",
      "super bowl",
      "world series",
      "playoffs",
      "win",
      "game",
      "match"
    ]

    Enum.any?(sports_keywords, fn kw ->
      String.contains?(question, kw) or String.contains?(event_title, kw)
    end)
  end

  @doc """
  Check if market matches the configured market type.
  """
  def matches_market_type?(market_info, "crypto"), do: is_crypto_market?(market_info)
  def matches_market_type?(market_info, "sports"), do: is_sports_market?(market_info)
  def matches_market_type?(_market_info, "all"), do: true
  def matches_market_type?(market_info, _), do: is_crypto_market?(market_info)

  @doc """
  Format price as percentage string.
  """
  def pct(price) when is_number(price), do: "#{Float.round(price * 100, 1)}%"
  def pct(_), do: "?%"

  @doc """
  Format spread as percentage string.
  """
  def spread_pct(spread) when is_number(spread), do: "#{Float.round(spread * 100, 2)}%"
  def spread_pct(_), do: "?%"

  @doc """
  Format time to resolution for logging.
  """
  def time_label(%{end_date: end_date}) do
    case calculate_minutes_to_resolution(end_date) do
      nil -> "unknown time"
      mins when mins < 60 -> "#{round(mins)}m"
      mins -> "#{Float.round(mins / 60, 1)}h"
    end
  end

  def time_label(_), do: "unknown time"

  @doc """
  Map market timeframe config to Gamma API intervals.
  """
  def timeframe_to_intervals("15m"), do: [:_15m]
  def timeframe_to_intervals("1h"), do: [:_1h]
  def timeframe_to_intervals("4h"), do: [:_4h]
  def timeframe_to_intervals("daily"), do: [:weekly]
  def timeframe_to_intervals(_), do: [:_15m]

  @doc """
  Get outcome name for a token from market data.
  """
  def get_outcome_for_token(market, token_id) do
    outcomes = market[:outcomes] || []

    case Enum.find(outcomes, fn o -> o[:token_id] == token_id end) do
      %{name: name} -> name
      _ -> nil
    end
  end
end
