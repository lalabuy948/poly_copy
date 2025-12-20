defmodule Polyx.Polymarket.Gamma.Filter do
  @moduledoc """
  Filtering utilities for Gamma API events and markets.
  """

  @crypto_keywords [
    "bitcoin",
    "btc",
    "ethereum",
    "eth",
    "crypto",
    "solana",
    "sol",
    "xrp",
    "doge",
    "dogecoin",
    "bnb",
    "cardano",
    "ada",
    "polygon",
    "matic",
    "avalanche",
    "avax",
    "chainlink",
    "link",
    "uniswap",
    "uni"
  ]

  @doc """
  Check if an event is crypto-related based on title, description, and tags.
  """
  def is_crypto_event?(event) when is_map(event) do
    title = String.downcase(event["title"] || "")
    desc = String.downcase(event["description"] || "")

    # Check title first (most reliable)
    title_match = Enum.any?(@crypto_keywords, &String.contains?(title, &1))

    # Check tags if available
    tags = event["tags"] || []

    tag_match =
      Enum.any?(tags, fn tag ->
        label = String.downcase(tag["label"] || "")
        label == "crypto" or String.contains?(label, "crypto")
      end)

    # Check description as fallback
    desc_match = Enum.any?(@crypto_keywords, &String.contains?(desc, &1))

    title_match or tag_match or desc_match
  end

  def is_crypto_event?(_), do: false

  @doc """
  Filter events by search query (searches in title and description).
  Returns the filtered list.
  """
  def maybe_filter_search(events, nil), do: events
  def maybe_filter_search(events, ""), do: events

  def maybe_filter_search(events, search) do
    search_lower = String.downcase(search)

    Enum.filter(events, fn event ->
      title = String.downcase(event["title"] || "")
      desc = String.downcase(event["description"] || "")
      String.contains?(title, search_lower) or String.contains?(desc, search_lower)
    end)
  end

  @doc """
  Filter events by time window (minutes to resolution).
  """
  def filter_by_time_window(events, min_minutes, max_minutes) do
    now = DateTime.utc_now()

    Enum.filter(events, fn event ->
      case parse_end_date(event["endDate"]) do
        {:ok, end_dt} ->
          minutes_remaining = DateTime.diff(end_dt, now, :second) / 60
          minutes_remaining >= min_minutes and minutes_remaining <= max_minutes

        _ ->
          false
      end
    end)
  end

  # Private helper for parsing end dates
  defp parse_end_date(nil), do: {:error, nil}

  defp parse_end_date(end_date) when is_binary(end_date) do
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

  defp parse_end_date(end_date) when is_integer(end_date) do
    {:ok, DateTime.from_unix!(end_date)}
  end

  defp parse_end_date(_), do: {:error, :invalid_format}
end
