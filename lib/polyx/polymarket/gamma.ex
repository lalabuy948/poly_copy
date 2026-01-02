defmodule Polyx.Polymarket.Gamma do
  @moduledoc """
  Client for Polymarket Gamma API - fetches events and markets.
  Rate limited to 60 requests/minute.
  """

  require Logger

  alias Polyx.Polymarket.RateLimiter
  alias Polyx.Polymarket.Gamma.{Parser, RetryHandler, Filter, MarketLookup}

  @base_url "https://gamma-api.polymarket.com"
  @search_url "https://search-api.polymarket.com"
  @req_options [retry: false, receive_timeout: 30_000]

  # Delegate market lookup functions to MarketLookup module
  defdelegate get_market_by_token(token_id), to: MarketLookup
  defdelegate fetch_fresh_price(token_id), to: MarketLookup

  # Delegate filtering functions to Filter module
  defdelegate is_crypto_event?(event), to: Filter

  @doc """
  Fetch active events with their markets.

  Options:
    - :limit - Number of events to fetch (default: 50)
    - :offset - Pagination offset (default: 0)
    - :tag_id - Filter by tag ID
    - :search - Search query (searches in title)
  """
  def fetch_events(opts \\ []) do
    with :ok <- RateLimiter.acquire(:gamma) do
      RetryHandler.with_retry(
        fn -> do_fetch_events(opts) end,
        context: "fetch_events"
      )
    end
  end

  defp do_fetch_events(opts) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    tag_id = Keyword.get(opts, :tag_id)
    search = Keyword.get(opts, :search)

    params =
      [
        closed: false,
        active: true,
        limit: limit,
        offset: offset,
        order: "volume24hr",
        ascending: false
      ]
      |> maybe_add_param(:tag_id, tag_id)

    url = "#{@base_url}/events?#{URI.encode_query(params)}"
    response = Req.get(url, @req_options)

    RetryHandler.handle_response(response, fn body ->
      events =
        body
        |> Enum.filter(&(&1["enableOrderBook"] == true))
        |> Filter.maybe_filter_search(search)
        |> Enum.map(&Parser.parse_event/1)

      {:ok, events}
    end)
  end

  @doc """
  Fetch 15-minute crypto markets (Bitcoin, Ethereum, Solana, XRP Up or Down).
  Uses the "15M" tag to find these recurring short-term markets.

  Options:
    - :max_minutes - Maximum minutes until resolution (default: 30)
    - :min_minutes - Minimum minutes until resolution (default: 1)
    - :limit - Number of events to fetch (default: 50)
  """
  def fetch_15m_crypto_markets(opts \\ []) do
    # Use try_acquire for non-blocking discovery
    non_blocking = Keyword.get(opts, :non_blocking, false)

    result =
      if non_blocking do
        RateLimiter.try_acquire(:gamma)
      else
        RateLimiter.acquire(:gamma)
      end

    case result do
      :ok ->
        RetryHandler.with_retry(
          fn -> do_fetch_tagged_crypto_markets("15M", opts) end,
          context: "fetch_15m_crypto_markets"
        )

      {:error, :rate_limited} ->
        {:error, :rate_limited}
    end
  end

  @doc """
  Fetch hourly crypto markets (Bitcoin, Ethereum, Solana, XRP Up or Down).
  Uses the "1H" tag to find these recurring hourly markets.

  Options:
    - :max_minutes - Maximum minutes until resolution (default: 120)
    - :min_minutes - Minimum minutes until resolution (default: 1)
    - :limit - Number of events to fetch (default: 50)
  """
  def fetch_hourly_crypto_markets(opts \\ []) do
    with :ok <- RateLimiter.acquire(:gamma) do
      RetryHandler.with_retry(
        fn -> do_fetch_tagged_crypto_markets("1H", opts) end,
        context: "fetch_hourly_crypto_markets"
      )
    end
  end

  @doc """
  Fetch 4-hour crypto markets.
  Uses the "4h" tag to find these recurring 4-hour markets.

  Options:
    - :max_minutes - Maximum minutes until resolution (default: 480)
    - :min_minutes - Minimum minutes until resolution (default: 1)
    - :limit - Number of events to fetch (default: 50)
  """
  def fetch_4h_crypto_markets(opts \\ []) do
    with :ok <- RateLimiter.acquire(:gamma) do
      RetryHandler.with_retry(
        fn -> do_fetch_tagged_crypto_markets("4h", opts) end,
        context: "fetch_4h_crypto_markets"
      )
    end
  end

  @doc """
  Fetch weekly crypto markets.
  Uses the "weekly" tag to find these recurring weekly markets.

  Options:
    - :max_minutes - Maximum minutes until resolution (default: 10080, i.e., 7 days)
    - :min_minutes - Minimum minutes until resolution (default: 1)
    - :limit - Number of events to fetch (default: 50)
  """
  def fetch_weekly_crypto_markets(opts \\ []) do
    with :ok <- RateLimiter.acquire(:gamma) do
      RetryHandler.with_retry(
        fn -> do_fetch_tagged_crypto_markets("weekly", opts) end,
        context: "fetch_weekly_crypto_markets"
      )
    end
  end

  @doc """
  Fetch crypto markets ending soon from all time interval tags (15M, 1H, 4H, Weekly).
  This combines results from all market types for comprehensive coverage.

  Options:
    - :max_minutes - Maximum minutes until resolution (default: 120)
    - :min_minutes - Minimum minutes until resolution (default: 1)
    - :intervals - List of intervals to fetch, e.g., [:15m, :1h, :4h, :weekly] (default: all)
  """
  def fetch_crypto_markets_ending_soon(opts \\ []) do
    max_minutes = Keyword.get(opts, :max_minutes, 120)
    min_minutes = Keyword.get(opts, :min_minutes, 1)
    intervals = Keyword.get(opts, :intervals, [:_15m, :_1h, :_4h, :weekly])
    non_blocking = Keyword.get(opts, :non_blocking, false)

    # Fetch from requested interval tags
    results =
      intervals
      |> Enum.map(fn interval ->
        fetch_opts = [
          max_minutes: max_minutes,
          min_minutes: min_minutes,
          non_blocking: non_blocking
        ]

        case interval do
          :_15m -> fetch_15m_crypto_markets(fetch_opts)
          :_1h -> fetch_hourly_crypto_markets(fetch_opts)
          :_4h -> fetch_4h_crypto_markets(fetch_opts)
          :weekly -> fetch_weekly_crypto_markets(fetch_opts)
          _ -> {:ok, []}
        end
      end)
      |> Enum.filter(fn
        {:ok, _} -> true
        _ -> false
      end)
      |> Enum.flat_map(fn {:ok, events} -> events end)

    # Dedupe by slug and sort by end date
    all_events =
      results
      |> Enum.uniq_by(& &1.slug)
      |> Enum.sort_by(& &1.end_date)

    {:ok, all_events}
  end

  @doc """
  Get main category filters for the UI.
  These are hardcoded since the API doesn't provide proper categories.
  We use search-based filtering with these keywords.
  """
  def get_categories do
    [
      %{
        id: "politics",
        label: "Politics",
        keywords: ["election", "president", "congress", "senate", "government", "trump", "biden"]
      },
      %{
        id: "crypto",
        label: "Crypto",
        keywords: ["bitcoin", "ethereum", "crypto", "token", "blockchain", "btc", "eth"]
      },
      %{
        id: "sports",
        label: "Sports",
        keywords: ["nfl", "nba", "soccer", "football", "basketball", "championship", "super bowl"]
      },
      %{
        id: "finance",
        label: "Finance",
        keywords: ["stock", "market", "fed", "interest rate", "inflation", "economy"]
      },
      %{
        id: "tech",
        label: "Tech",
        keywords: ["ai", "openai", "google", "apple", "microsoft", "tesla", "spacex"]
      },
      %{
        id: "entertainment",
        label: "Entertainment",
        keywords: ["movie", "oscars", "grammy", "music", "celebrity"]
      },
      %{
        id: "world",
        label: "World",
        keywords: ["war", "ukraine", "russia", "china", "israel", "international"]
      }
    ]
  end

  @doc """
  Fetch a single event by slug.
  """
  def fetch_event_by_slug(slug) do
    url = "#{@base_url}/events/slug/#{slug}"

    case Req.get(url, @req_options) do
      {:ok, %{status: 200, body: event}} when is_map(event) ->
        {:ok, Parser.parse_event(event)}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, "API returned #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetch sports markets ending within the specified time window.
  Filters by sports-related keywords in the event title.

  Options:
    - :max_minutes - Maximum minutes until resolution (default: 120)
    - :min_minutes - Minimum minutes until resolution (default: 1)
    - :limit - Number of events to fetch (default: 50)
  """
  def fetch_sports_markets_ending_soon(opts \\ []) do
    with :ok <- RateLimiter.acquire(:gamma) do
      RetryHandler.with_retry(
        fn -> do_fetch_sports_markets(opts) end,
        context: "fetch_sports_markets_ending_soon"
      )
    end
  end

  defp do_fetch_sports_markets(opts) do
    max_minutes = Keyword.get(opts, :max_minutes, 120)
    min_minutes = Keyword.get(opts, :min_minutes, 1)
    limit = Keyword.get(opts, :limit, 50)

    params = [
      closed: false,
      active: true,
      limit: limit,
      order: "volume24hr",
      ascending: false
    ]

    url = "#{@base_url}/events?#{URI.encode_query(params)}"
    response = Req.get(url, @req_options)

    RetryHandler.handle_response(response, fn body ->
      filtered_events =
        body
        |> Enum.filter(&(&1["enableOrderBook"] == true))
        |> Enum.filter(&Filter.is_sports_event?/1)
        |> Filter.filter_by_time_window(min_minutes, max_minutes)
        |> Enum.map(&Parser.parse_event/1)

      {:ok, filtered_events}
    end)
  end

  @doc """
  Search events using the search API.
  """
  def search_events(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    url = "#{@search_url}/search?#{URI.encode_query(text: query, type: "events", limit: limit)}"

    case Req.get(url, @req_options) do
      {:ok, %{status: 200, body: events}} when is_list(events) ->
        events =
          events
          |> Enum.filter(&(&1["enableOrderBook"] == true and &1["active"] == true))
          |> Enum.map(&Parser.parse_search_event/1)

        {:ok, events}

      {:ok, %{status: status}} ->
        {:error, "Search API returned #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  # Generic function to fetch crypto markets by tag
  defp do_fetch_tagged_crypto_markets(tag, opts) do
    max_minutes = Keyword.get(opts, :max_minutes, get_default_max_minutes(tag))
    min_minutes = Keyword.get(opts, :min_minutes, 1)
    limit = Keyword.get(opts, :limit, 50)

    params = [
      closed: false,
      active: true,
      limit: limit,
      tag_slug: tag
    ]

    url = "#{@base_url}/events?#{URI.encode_query(params)}"
    response = Req.get(url, @req_options)

    RetryHandler.handle_response(response, fn body ->
      filtered_events =
        body
        |> Enum.filter(&(&1["enableOrderBook"] == true))
        |> Enum.filter(&Filter.is_crypto_event?/1)
        |> Filter.filter_by_time_window(min_minutes, max_minutes)
        |> Enum.map(&Parser.parse_event/1)

      {:ok, filtered_events}
    end)
  end

  defp get_default_max_minutes("15M"), do: 30
  defp get_default_max_minutes("1H"), do: 120
  defp get_default_max_minutes("4h"), do: 480
  defp get_default_max_minutes("weekly"), do: 10_080
  defp get_default_max_minutes(_), do: 120

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, _key, ""), do: params
  defp maybe_add_param(params, key, value), do: Keyword.put(params, key, value)
end
