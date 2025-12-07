defmodule Polyx.Polymarket.Subgraph do
  @moduledoc """
  Client for Polymarket Subgraph API.

  The Subgraph provides efficient access to historical on-chain data
  including market creation, resolution, and trading activity.
  Recommended by Polymarket docs for historical data queries over REST pagination.

  Subgraph endpoint: https://api.thegraph.com/subgraphs/name/polymarket/polymarket-matic
  """

  require Logger

  @subgraph_url "https://api.thegraph.com/subgraphs/name/polymarket/polymarket-matic"
  @req_options [retry: false, receive_timeout: 30_000]

  alias Polyx.Polymarket.RateLimiter

  @doc """
  Query the subgraph with a GraphQL query.
  Returns {:ok, data} or {:error, reason}.
  """
  def query(graphql_query, variables \\ %{}) do
    with :ok <- RateLimiter.acquire(:data) do
      do_query(graphql_query, variables, 3)
    end
  end

  defp do_query(graphql_query, variables, retries_left) do
    body = Jason.encode!(%{query: graphql_query, variables: variables})

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    case Req.post(@subgraph_url, [body: body, headers: headers] ++ @req_options) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} ->
        {:ok, data}

      {:ok, %Req.Response{status: 200, body: %{"errors" => errors}}} ->
        Logger.warning("[Subgraph] GraphQL errors: #{inspect(errors)}")
        {:error, {:graphql_errors, errors}}

      {:ok, %Req.Response{status: 429}} when retries_left > 0 ->
        Logger.warning("[Subgraph] Rate limited, retrying...")
        Process.sleep(2000)
        do_query(graphql_query, variables, retries_left - 1)

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("[Subgraph] API returned #{status}: #{inspect(body)}")
        {:error, {:http_error, status}}

      {:error, reason} when retries_left > 0 ->
        Logger.warning("[Subgraph] Request failed, retrying: #{inspect(reason)}")
        Process.sleep(1000)
        do_query(graphql_query, variables, retries_left - 1)

      {:error, reason} ->
        Logger.error("[Subgraph] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get recent markets with basic info.
  Useful for getting a snapshot of active markets.

  Options:
    - :limit - Number of markets (default: 100, max: 1000)
    - :skip - Pagination offset (default: 0)
    - :order_by - Field to order by (default: "creationTimestamp")
    - :order_direction - "asc" or "desc" (default: "desc")
  """
  def get_markets(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    skip = Keyword.get(opts, :skip, 0)
    order_by = Keyword.get(opts, :order_by, "creationTimestamp")
    order_direction = Keyword.get(opts, :order_direction, "desc")

    graphql = """
    query GetMarkets($limit: Int!, $skip: Int!, $orderBy: String!, $orderDirection: String!) {
      fixedProductMarketMakers(
        first: $limit
        skip: $skip
        orderBy: $orderBy
        orderDirection: $orderDirection
      ) {
        id
        creator
        creationTimestamp
        collateralToken {
          id
          symbol
          decimals
        }
        conditions {
          id
          questionId
          outcomeSlotCount
          resolutionTimestamp
        }
        fee
        scaledLiquidityParameter
        outcomeTokenAmounts
        outcomeTokenMarginalPrices
      }
    }
    """

    variables = %{
      limit: limit,
      skip: skip,
      orderBy: order_by,
      orderDirection: order_direction
    }

    case query(graphql, variables) do
      {:ok, %{"fixedProductMarketMakers" => markets}} ->
        {:ok, Enum.map(markets, &parse_market/1)}

      {:ok, data} ->
        Logger.warning("[Subgraph] Unexpected response shape: #{inspect(data)}")
        {:error, :unexpected_response}

      error ->
        error
    end
  end

  @doc """
  Get trading history for a specific user address.
  Returns trades with market context.

  Options:
    - :limit - Number of trades (default: 100, max: 1000)
    - :skip - Pagination offset (default: 0)
  """
  def get_user_trades(address, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    skip = Keyword.get(opts, :skip, 0)

    graphql = """
    query GetUserTrades($address: String!, $limit: Int!, $skip: Int!) {
      fpmmTrades(
        first: $limit
        skip: $skip
        where: { creator: $address }
        orderBy: creationTimestamp
        orderDirection: desc
      ) {
        id
        creator {
          id
        }
        creationTimestamp
        transactionHash
        fpmm {
          id
          conditions {
            questionId
          }
        }
        type
        outcomeIndex
        outcomeTokensTraded
        collateralTokensTraded
        feeAmount
      }
    }
    """

    variables = %{
      address: String.downcase(address),
      limit: limit,
      skip: skip
    }

    case query(graphql, variables) do
      {:ok, %{"fpmmTrades" => trades}} ->
        {:ok, Enum.map(trades, &parse_trade/1)}

      {:ok, data} ->
        Logger.warning("[Subgraph] Unexpected response shape: #{inspect(data)}")
        {:error, :unexpected_response}

      error ->
        error
    end
  end

  @doc """
  Get market resolution data for resolved conditions.

  Options:
    - :limit - Number of conditions (default: 100)
    - :skip - Pagination offset (default: 0)
  """
  def get_resolved_conditions(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    skip = Keyword.get(opts, :skip, 0)

    graphql = """
    query GetResolvedConditions($limit: Int!, $skip: Int!) {
      conditions(
        first: $limit
        skip: $skip
        where: { resolutionTimestamp_gt: 0 }
        orderBy: resolutionTimestamp
        orderDirection: desc
      ) {
        id
        questionId
        outcomeSlotCount
        resolutionTimestamp
        payoutNumerators
        payoutDenominator
      }
    }
    """

    variables = %{limit: limit, skip: skip}

    case query(graphql, variables) do
      {:ok, %{"conditions" => conditions}} ->
        {:ok, Enum.map(conditions, &parse_condition/1)}

      {:ok, data} ->
        Logger.warning("[Subgraph] Unexpected response shape: #{inspect(data)}")
        {:error, :unexpected_response}

      error ->
        error
    end
  end

  @doc """
  Get liquidity events for a market.
  Useful for tracking market maker activity.

  Options:
    - :limit - Number of events (default: 100)
    - :skip - Pagination offset (default: 0)
  """
  def get_liquidity_events(market_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    skip = Keyword.get(opts, :skip, 0)

    graphql = """
    query GetLiquidityEvents($marketId: String!, $limit: Int!, $skip: Int!) {
      fpmmLiquidities(
        first: $limit
        skip: $skip
        where: { fpmm: $marketId }
        orderBy: creationTimestamp
        orderDirection: desc
      ) {
        id
        type
        funder {
          id
        }
        creationTimestamp
        transactionHash
        collateralTokenAmount
        sharesAmount
        additionalLiquidityParameter
      }
    }
    """

    variables = %{
      marketId: String.downcase(market_id),
      limit: limit,
      skip: skip
    }

    case query(graphql, variables) do
      {:ok, %{"fpmmLiquidities" => events}} ->
        {:ok, events}

      {:ok, data} ->
        Logger.warning("[Subgraph] Unexpected response shape: #{inspect(data)}")
        {:error, :unexpected_response}

      error ->
        error
    end
  end

  # Parsing helpers

  defp parse_market(market) do
    %{
      id: market["id"],
      creator: market["creator"],
      created_at: parse_timestamp(market["creationTimestamp"]),
      collateral_token: market["collateralToken"],
      conditions: market["conditions"],
      fee: parse_float(market["fee"]),
      liquidity: parse_float(market["scaledLiquidityParameter"]),
      outcome_amounts: parse_float_list(market["outcomeTokenAmounts"]),
      outcome_prices: parse_float_list(market["outcomeTokenMarginalPrices"])
    }
  end

  defp parse_trade(trade) do
    %{
      id: trade["id"],
      creator: get_in(trade, ["creator", "id"]),
      timestamp: parse_timestamp(trade["creationTimestamp"]),
      tx_hash: trade["transactionHash"],
      market_id: get_in(trade, ["fpmm", "id"]),
      question_id: get_in(trade, ["fpmm", "conditions", Access.at(0), "questionId"]),
      type: trade["type"],
      outcome_index: trade["outcomeIndex"],
      outcome_tokens: parse_float(trade["outcomeTokensTraded"]),
      collateral_tokens: parse_float(trade["collateralTokensTraded"]),
      fee: parse_float(trade["feeAmount"])
    }
  end

  defp parse_condition(condition) do
    %{
      id: condition["id"],
      question_id: condition["questionId"],
      outcome_count: condition["outcomeSlotCount"],
      resolved_at: parse_timestamp(condition["resolutionTimestamp"]),
      payout_numerators: condition["payoutNumerators"],
      payout_denominator: condition["payoutDenominator"]
    }
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {n, _} -> DateTime.from_unix!(n)
      :error -> nil
    end
  end

  defp parse_timestamp(ts) when is_integer(ts), do: DateTime.from_unix!(ts)

  defp parse_float(nil), do: 0.0

  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float(val) when is_number(val), do: val * 1.0
  defp parse_float(_), do: 0.0

  defp parse_float_list(nil), do: []
  defp parse_float_list(list) when is_list(list), do: Enum.map(list, &parse_float/1)
  defp parse_float_list(_), do: []
end
