defmodule Polyx.Polymarket.Gamma.Parser do
  @moduledoc """
  Parser for Gamma API responses.
  Handles JSON parsing and data transformation for events, markets, and tokens.
  """

  @doc """
  Parse an event from Gamma API into normalized format.
  """
  def parse_event(event) do
    markets =
      (event["markets"] || [])
      |> Enum.map(&parse_market/1)

    %{
      id: event["id"],
      title: event["title"],
      slug: event["slug"],
      description: event["description"],
      image: event["image"],
      volume_24h: event["volume24hr"] || 0,
      liquidity: event["liquidityClob"] || event["liquidity"] || 0,
      end_date: event["endDate"],
      tags: parse_tags(event["tags"]),
      markets: markets,
      token_ids: Enum.flat_map(markets, & &1.token_ids)
    }
  end

  @doc """
  Parse a search event (slightly different format from regular events).
  """
  def parse_search_event(event) do
    markets =
      (event["markets"] || [])
      |> Enum.map(&parse_market/1)

    %{
      id: event["id"],
      title: event["title"],
      slug: event["slug"],
      description: event["description"],
      image: event["image"],
      volume_24h: event["volume24hr"] || event["volume"] || 0,
      liquidity: event["liquidityClob"] || event["liquidity"] || 0,
      end_date: event["endDate"],
      tags: parse_tags(event["tags"]),
      markets: markets,
      token_ids: Enum.flat_map(markets, & &1.token_ids)
    }
  end

  @doc """
  Parse a market from Gamma API into normalized format.
  """
  def parse_market(market) do
    token_ids = parse_clob_token_ids(market["clobTokenIds"])
    outcomes = parse_json_array(market["outcomes"])
    prices = parse_json_array(market["outcomePrices"])

    outcome_data =
      Enum.zip([outcomes, prices, token_ids])
      |> Enum.map(fn {outcome, price, token_id} ->
        %{
          name: outcome,
          price: parse_price(price),
          token_id: token_id
        }
      end)

    %{
      id: market["id"],
      question: market["question"],
      token_ids: token_ids,
      outcomes: outcome_data,
      volume_24h: market["volume24hr"] || 0
    }
  end

  @doc """
  Parse CLOB token IDs - handles both JSON string and list formats.
  """
  def parse_clob_token_ids(nil), do: []

  def parse_clob_token_ids(ids) when is_binary(ids) do
    case Jason.decode(ids) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  def parse_clob_token_ids(ids) when is_list(ids), do: ids

  @doc """
  Parse JSON array - handles both JSON string and list formats.
  """
  def parse_json_array(nil), do: []

  def parse_json_array(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  def parse_json_array(list) when is_list(list), do: list

  @doc """
  Parse price from various formats (string, number) to float.
  """
  def parse_price(price) when is_binary(price) do
    case Float.parse(price) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  def parse_price(price) when is_number(price), do: price * 1.0
  def parse_price(_), do: 0.0

  @doc """
  Parse tags into normalized format.
  """
  def parse_tags(nil), do: []

  def parse_tags(tags) when is_list(tags) do
    Enum.map(tags, fn tag ->
      %{id: tag["id"], label: tag["label"], slug: tag["slug"]}
    end)
  end

  @doc """
  Parse end date for filtering purposes (supports ISO8601 and Unix timestamp).
  """
  def parse_end_date_for_filter(nil), do: {:error, nil}

  def parse_end_date_for_filter(end_date) when is_binary(end_date) do
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

  def parse_end_date_for_filter(end_date) when is_integer(end_date) do
    {:ok, DateTime.from_unix!(end_date)}
  end

  def parse_end_date_for_filter(_), do: {:error, :invalid_format}

  @doc """
  Get outcome and price for a specific token from market data.
  Returns {outcome, price, opposite_token_id}.
  """
  def get_outcome_and_price_for_token(market, token_id) do
    token_ids = parse_clob_token_ids(market["clobTokenIds"])
    outcomes = parse_json_array(market["outcomes"])
    prices = parse_json_array(market["outcomePrices"])

    case Enum.find_index(token_ids, &(&1 == token_id)) do
      nil ->
        {nil, nil, nil}

      idx ->
        outcome = Enum.at(outcomes, idx)
        price_str = Enum.at(prices, idx)

        price =
          case price_str do
            nil ->
              nil

            str when is_binary(str) ->
              case Float.parse(str) do
                {val, _} -> val
                :error -> nil
              end

            num when is_number(num) ->
              num
          end

        # Find the opposite token (the other token in the market)
        opposite_token_id =
          token_ids
          |> Enum.reject(&(&1 == token_id))
          |> List.first()

        {outcome, price, opposite_token_id}
    end
  end
end
