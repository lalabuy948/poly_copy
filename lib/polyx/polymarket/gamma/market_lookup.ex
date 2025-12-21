defmodule Polyx.Polymarket.Gamma.MarketLookup do
  @moduledoc """
  Market lookup and caching for Gamma API.
  Provides cached access to market information by token ID.
  """

  require Logger

  alias Polyx.Polymarket.GammaCache
  alias Polyx.Polymarket.RateLimiter
  alias Polyx.Polymarket.Gamma.{Parser, RetryHandler}

  @base_url "https://gamma-api.polymarket.com"
  @req_options [retry: false, receive_timeout: 30_000]
  @cache_ttl 300

  @doc """
  Look up market info by token ID. Returns cached result if available.
  """
  def get_market_by_token(token_id) when is_binary(token_id) do
    now = System.system_time(:second)

    case GammaCache.lookup(token_id) do
      [{^token_id, info, expires_at}] ->
        if expires_at > now do
          {:ok, info}
        else
          # Expired, fetch fresh
          fetch_and_cache_market(token_id)
        end

      _ ->
        # Cache miss, fetch from API
        fetch_and_cache_market(token_id)
    end
  end

  def get_market_by_token(_), do: {:error, :invalid_token_id}

  @doc """
  Fetch fresh price for a token directly from API (bypasses cache).
  Use sparingly - for live price updates when WebSocket has no activity.
  """
  def fetch_fresh_price(token_id) when is_binary(token_id) do
    with :ok <- RateLimiter.acquire(:gamma) do
      url = "#{@base_url}/markets?clob_token_ids=#{token_id}"

      case Req.get(url, @req_options) do
        {:ok, %{status: 200, body: [market | _]}} when is_map(market) ->
          {outcome, price, _opposite} = Parser.get_outcome_and_price_for_token(market, token_id)
          {:ok, %{price: price, outcome: outcome}}

        {:ok, %{status: status}} ->
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def fetch_fresh_price(_), do: {:error, :invalid_token_id}

  # Private functions

  defp fetch_and_cache_market(token_id) do
    with :ok <- RateLimiter.acquire(:gamma) do
      RetryHandler.with_retry(
        fn -> do_fetch_market(token_id) end,
        context: "fetch_market(#{String.slice(token_id, 0, 8)}...)"
      )
    end
  end

  defp do_fetch_market(token_id) do
    url = "#{@base_url}/markets?clob_token_ids=#{token_id}"

    response = Req.get(url, @req_options)

    RetryHandler.handle_response(response, fn body ->
      case body do
        [market | _] when is_map(market) ->
          {outcome, price, opposite_token_id} =
            Parser.get_outcome_and_price_for_token(market, token_id)

          # Get event slug from events array or fall back to market slug
          event_slug =
            case market["events"] do
              [%{"slug" => slug} | _] when is_binary(slug) -> slug
              _ -> market["slug"] || market["eventSlug"]
            end

          info = %{
            question: market["question"],
            event_title: market["eventTitle"] || market["groupItemTitle"],
            event_slug: event_slug,
            condition_id: market["conditionId"],
            outcome: outcome,
            price: price,
            image: market["image"],
            end_date: market["endDate"] || market["endDateIso"],
            neg_risk: market["negRisk"] == true,
            opposite_token_id: opposite_token_id
          }

          # Cache for configured TTL
          expires_at = System.system_time(:second) + @cache_ttl
          GammaCache.insert(token_id, info, expires_at)
          {:ok, info}

        [] ->
          {:error, :not_found}

        _ ->
          {:error, :invalid_response}
      end
    end)
  end
end
