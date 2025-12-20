defmodule Polyx.Strategies.TimeDecay.Helpers do
  @moduledoc """
  Helper functions for TimeDecay strategy.
  Includes time calculations, price parsing, and formatting utilities.
  """

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
    # Try ISO8601 format first
    case DateTime.from_iso8601(end_date) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, _} ->
        # Try Unix timestamp (string)
        case Integer.parse(end_date) do
          {ts, _} -> {:ok, DateTime.from_unix!(ts)}
          :error -> {:error, :invalid_format}
        end
    end
  end

  def parse_end_date(end_date) when is_integer(end_date) do
    {:ok, DateTime.from_unix!(end_date)}
  end

  def parse_end_date(_), do: {:error, :invalid_format}

  @doc """
  Calculate evaluation price (midpoint or best_bid).
  """
  def calculate_evaluation_price(best_bid, best_ask, true)
      when not is_nil(best_bid) and not is_nil(best_ask) do
    (best_bid + best_ask) / 2
  end

  def calculate_evaluation_price(best_bid, best_ask, _) do
    best_bid || best_ask
  end

  @doc """
  Calculate bid-ask spread.
  """
  def calculate_spread(nil, _), do: nil
  def calculate_spread(_, nil), do: nil
  def calculate_spread(best_bid, best_ask), do: best_ask - best_bid

  @doc """
  Calculate effective order size after fees.
  """
  def calculate_effective_size(order_size, _price, :buy) do
    # Return full order size - fees are charged separately by Polymarket
    order_size
  end

  @doc """
  Estimate profit from trade.
  """
  def estimate_profit(:buy, target_price, size) do
    # If resolves to 1, profit = (1 - target_price) * shares
    shares = size / target_price
    (1 - target_price) * shares
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
  Format price as percentage string.
  """
  def pct(price) when is_number(price), do: "#{Float.round(price * 100, 1)}%"
  def pct(_), do: "?%"

  @doc """
  Format time to resolution for logging (shows minutes when <1h).
  """
  def hours_label(%{end_date: end_date}) do
    case calculate_minutes_to_resolution(end_date) do
      nil -> "unknown time"
      mins when mins < 60 -> "#{round(mins)}m"
      mins -> "#{round(mins / 60)}h"
    end
  end

  def hours_label(_), do: "unknown time"

  @doc """
  Map market timeframe config to Gamma API intervals.
  """
  def timeframe_to_intervals("15m"), do: [:_15m]
  def timeframe_to_intervals("1h"), do: [:_1h]
  def timeframe_to_intervals("4h"), do: [:_4h]
  def timeframe_to_intervals("daily"), do: [:weekly]
  def timeframe_to_intervals(_), do: [:_15m]

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
