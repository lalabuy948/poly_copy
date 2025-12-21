defmodule PolyxWeb.StrategiesLive.PriceUtils do
  @moduledoc """
  Price and token utilities for the StrategiesLive view.

  Contains functions for price calculations, token sorting, and price-related UI helpers.
  """

  @doc """
  Calculates the mid price from bid and ask.

  ## Examples

      iex> calculate_mid(0.8, 0.85)
      0.825

      iex> calculate_mid(0.8, nil)
      0.8

      iex> calculate_mid(nil, nil)
      nil
  """
  def calculate_mid(bid, ask) when is_number(bid) and is_number(ask), do: (bid + ask) / 2
  def calculate_mid(bid, nil) when is_number(bid), do: bid
  def calculate_mid(nil, ask) when is_number(ask), do: ask
  def calculate_mid(_, _), do: nil

  @doc """
  Returns the count of tokens in the price map.

  ## Examples

      iex> token_count(%{"token1" => %{}, "token2" => %{}})
      2

      iex> token_count(:no_markets)
      0
  """
  def token_count(:no_markets), do: 0
  def token_count(prices) when is_map(prices), do: map_size(prices)
  def token_count(_), do: 0

  @doc """
  Sorts tokens by price (highest first).

  Returns a list of {token_id, price_data} tuples sorted by best_bid or mid price.
  """
  def sort_tokens(:no_markets, _config), do: []
  def sort_tokens(prices, _config) when not is_map(prices), do: []

  def sort_tokens(prices, _config) do
    prices
    |> Enum.sort_by(fn {_, data} -> data[:best_bid] || data[:mid] || 0.5 end, :desc)
  end

  @doc """
  Returns the CSS class for a price row based on the price and threshold.

  Returns success/error classes for prices above/below thresholds.
  """
  def price_row_class(price, config) when is_number(price) do
    threshold = config["signal_threshold"] || 0.80

    cond do
      price > threshold -> "bg-success/10 border-success/30"
      price < 0.20 -> "bg-error/10 border-error/30"
      true -> "bg-base-100 border-base-300"
    end
  end

  def price_row_class(_, _), do: "bg-base-100 border-base-300"

  @doc """
  Returns the CSS class for price status text based on the price and threshold.
  """
  def price_status_class(price, config) when is_number(price) do
    threshold = config["signal_threshold"] || 0.80

    cond do
      price > threshold -> "text-success"
      price < 0.20 -> "text-error"
      true -> "text-base-content/40"
    end
  end

  def price_status_class(_, _), do: "text-base-content/40"

  @doc """
  Returns the status label for a price based on thresholds.

  ## Examples

      iex> price_status_label(0.85, %{"signal_threshold" => 0.80, "limit_price" => 0.99})
      "TARGET 99¢"

      iex> price_status_label(0.50, %{})
      "WAIT"
  """
  def price_status_label(price, config) when is_number(price) do
    threshold = config["signal_threshold"] || 0.80
    target = config["limit_price"] || 0.99

    cond do
      price > threshold -> "TARGET #{Float.round(target * 100, 0)}¢"
      price < 0.20 -> "TARGET 1¢"
      true -> "WAIT"
    end
  end

  def price_status_label(_, _), do: "N/A"

  @doc """
  Returns the Polymarket URL for a market based on available data.

  ## Examples

      iex> polymarket_url(%{event_slug: "my-market"})
      "https://polymarket.com/event/my-market"

      iex> polymarket_url(%{condition_id: "0x123"})
      "https://polymarket.com/event?id=0x123"
  """
  def polymarket_url(%{event_slug: slug}) when is_binary(slug) and slug != "",
    do: "https://polymarket.com/event/#{slug}"

  def polymarket_url(%{condition_id: cid}) when is_binary(cid) and cid != "",
    do: "https://polymarket.com/event?id=#{cid}"

  def polymarket_url(_), do: "https://polymarket.com"

  @doc """
  Shortens a token ID for display.

  ## Examples

      iex> short_token("0x1234567890abcdef1234")
      "0x123456..."

      iex> short_token("short")
      "short"

      iex> short_token(nil)
      "unknown"
  """
  def short_token(nil), do: "unknown"

  def short_token(id) when is_binary(id) do
    if String.length(id) > 16, do: String.slice(id, 0, 8) <> "...", else: id
  end
end
