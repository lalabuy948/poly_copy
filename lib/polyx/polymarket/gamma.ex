defmodule Polyx.Polymarket.Gamma do
  @moduledoc """
  Client for Polymarket Gamma API - fetches events and markets.
  Rate limited to 60 requests/minute.
  """

  require Logger

  @base_url "https://gamma-api.polymarket.com"
  @search_url "https://search-api.polymarket.com"

  # Disable automatic retries to avoid 429 spam in logs
  @req_options [retry: false, receive_timeout: 10_000]

  @max_retries 3

  alias Polyx.Polymarket.GammaCache
  alias Polyx.Polymarket.RateLimiter

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

  defp fetch_and_cache_market(token_id) do
    with :ok <- RateLimiter.acquire(:gamma) do
      do_fetch_market(token_id, @max_retries)
    end
  end

  defp do_fetch_market(token_id, retries_left) do
    url = "#{@base_url}/markets?clob_token_ids=#{token_id}"

    case Req.get(url, @req_options) do
      {:ok, %{status: 200, body: [market | _]}} when is_map(market) ->
        {outcome, price, opposite_token_id} = get_outcome_and_price_for_token(market, token_id)

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
          # Include end date for time-to-resolution calculations
          end_date: market["endDate"] || market["endDateIso"],
          # Include neg_risk for order building
          neg_risk: market["negRisk"] == true,
          # Include opposite token for inverse trading
          opposite_token_id: opposite_token_id
        }

        # Cache for 5 minutes
        expires_at = System.system_time(:second) + 300
        GammaCache.insert(token_id, info, expires_at)
        {:ok, info}

      {:ok, %{status: 200, body: []}} ->
        {:error, :not_found}

      {:ok, %{status: 429}} when retries_left > 0 ->
        wait_ms = 2000 * (@max_retries - retries_left + 1)
        Logger.warning("[Gamma] Rate limited, waiting #{wait_ms}ms")
        Process.sleep(wait_ms)
        do_fetch_market(token_id, retries_left - 1)

      {:ok, %{status: status}} when status >= 500 and retries_left > 0 ->
        Logger.warning("[Gamma] Server error #{status}, retrying")
        Process.sleep(1000)
        do_fetch_market(token_id, retries_left - 1)

      {:ok, %{status: status}} ->
        {:error, "API returned #{status}"}

      {:error, reason} when retries_left > 0 ->
        Logger.warning("[Gamma] Request error, retrying: #{inspect(reason)}")
        Process.sleep(500)
        do_fetch_market(token_id, retries_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_outcome_and_price_for_token(market, token_id) do
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
      do_fetch_events(opts, @max_retries)
    end
  end

  defp do_fetch_events(opts, retries_left) do
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

    case Req.get(url, @req_options) do
      {:ok, %{status: 200, body: events}} when is_list(events) ->
        events =
          events
          |> Enum.filter(&(&1["enableOrderBook"] == true))
          |> maybe_filter_search(search)
          |> Enum.map(&parse_event/1)

        {:ok, events}

      {:ok, %{status: 429}} when retries_left > 0 ->
        wait_ms = 2000 * (@max_retries - retries_left + 1)
        Logger.warning("[Gamma] Rate limited on events, waiting #{wait_ms}ms")
        Process.sleep(wait_ms)
        do_fetch_events(opts, retries_left - 1)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[Gamma] API returned #{status}: #{inspect(body)}")
        {:error, "API returned #{status}"}

      {:error, reason} when retries_left > 0 ->
        Logger.warning("[Gamma] Request failed, retrying: #{inspect(reason)}")
        Process.sleep(500)
        do_fetch_events(opts, retries_left - 1)

      {:error, reason} ->
        Logger.error("[Gamma] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
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
    with :ok <- RateLimiter.acquire(:gamma) do
      do_fetch_15m_crypto_markets(opts, @max_retries)
    end
  end

  defp do_fetch_15m_crypto_markets(opts, retries_left) do
    max_minutes = Keyword.get(opts, :max_minutes, 30)
    min_minutes = Keyword.get(opts, :min_minutes, 1)
    limit = Keyword.get(opts, :limit, 50)

    # Use the 15M tag to find 15-minute crypto markets
    params = [
      closed: false,
      active: true,
      limit: limit,
      tag_slug: "15M"
    ]

    url = "#{@base_url}/events?#{URI.encode_query(params)}"

    case Req.get(url, @req_options) do
      {:ok, %{status: 200, body: events}} when is_list(events) ->
        now = DateTime.utc_now()

        filtered_events =
          events
          |> Enum.filter(&(&1["enableOrderBook"] == true))
          |> Enum.filter(fn event ->
            case parse_end_date_for_filter(event["endDate"]) do
              {:ok, end_dt} ->
                minutes_remaining = DateTime.diff(end_dt, now, :second) / 60
                minutes_remaining >= min_minutes and minutes_remaining <= max_minutes

              _ ->
                false
            end
          end)
          |> Enum.map(&parse_event/1)

        {:ok, filtered_events}

      {:ok, %{status: 429}} when retries_left > 0 ->
        wait_ms = 2000 * (@max_retries - retries_left + 1)
        Logger.warning("[Gamma] Rate limited on 15M markets, waiting #{wait_ms}ms")
        Process.sleep(wait_ms)
        do_fetch_15m_crypto_markets(opts, retries_left - 1)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[Gamma] 15M markets API returned #{status}: #{inspect(body)}")
        {:error, "API returned #{status}"}

      {:error, reason} when retries_left > 0 ->
        Logger.warning("[Gamma] 15M markets request failed, retrying: #{inspect(reason)}")
        Process.sleep(500)
        do_fetch_15m_crypto_markets(opts, retries_left - 1)

      {:error, reason} ->
        Logger.error("[Gamma] 15M markets request failed: #{inspect(reason)}")
        {:error, reason}
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
      do_fetch_hourly_crypto_markets(opts, @max_retries)
    end
  end

  defp do_fetch_hourly_crypto_markets(opts, retries_left) do
    max_minutes = Keyword.get(opts, :max_minutes, 120)
    min_minutes = Keyword.get(opts, :min_minutes, 1)
    limit = Keyword.get(opts, :limit, 50)

    # Use the 1H tag to find hourly crypto markets
    params = [
      closed: false,
      active: true,
      limit: limit,
      tag_slug: "1H"
    ]

    url = "#{@base_url}/events?#{URI.encode_query(params)}"

    case Req.get(url, @req_options) do
      {:ok, %{status: 200, body: events}} when is_list(events) ->
        now = DateTime.utc_now()

        filtered_events =
          events
          |> Enum.filter(&(&1["enableOrderBook"] == true))
          |> Enum.filter(fn event ->
            case parse_end_date_for_filter(event["endDate"]) do
              {:ok, end_dt} ->
                minutes_remaining = DateTime.diff(end_dt, now, :second) / 60
                minutes_remaining >= min_minutes and minutes_remaining <= max_minutes

              _ ->
                false
            end
          end)
          |> Enum.map(&parse_event/1)

        {:ok, filtered_events}

      {:ok, %{status: 429}} when retries_left > 0 ->
        wait_ms = 2000 * (@max_retries - retries_left + 1)
        Logger.warning("[Gamma] Rate limited on 1H markets, waiting #{wait_ms}ms")
        Process.sleep(wait_ms)
        do_fetch_hourly_crypto_markets(opts, retries_left - 1)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[Gamma] 1H markets API returned #{status}: #{inspect(body)}")
        {:error, "API returned #{status}"}

      {:error, reason} when retries_left > 0 ->
        Logger.warning("[Gamma] 1H markets request failed, retrying: #{inspect(reason)}")
        Process.sleep(500)
        do_fetch_hourly_crypto_markets(opts, retries_left - 1)

      {:error, reason} ->
        Logger.error("[Gamma] 1H markets request failed: #{inspect(reason)}")
        {:error, reason}
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
      do_fetch_tagged_crypto_markets("4h", opts, @max_retries, 480)
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
      do_fetch_tagged_crypto_markets("weekly", opts, @max_retries, 10_080)
    end
  end

  # Generic function to fetch crypto markets by tag
  defp do_fetch_tagged_crypto_markets(tag, opts, retries_left, default_max_minutes) do
    max_minutes = Keyword.get(opts, :max_minutes, default_max_minutes)
    min_minutes = Keyword.get(opts, :min_minutes, 1)
    limit = Keyword.get(opts, :limit, 50)

    params = [
      closed: false,
      active: true,
      limit: limit,
      tag_slug: tag
    ]

    url = "#{@base_url}/events?#{URI.encode_query(params)}"

    case Req.get(url, @req_options) do
      {:ok, %{status: 200, body: events}} when is_list(events) ->
        now = DateTime.utc_now()

        filtered_events =
          events
          |> Enum.filter(&(&1["enableOrderBook"] == true))
          |> Enum.filter(&is_crypto_event?/1)
          |> Enum.filter(fn event ->
            case parse_end_date_for_filter(event["endDate"]) do
              {:ok, end_dt} ->
                minutes_remaining = DateTime.diff(end_dt, now, :second) / 60
                minutes_remaining >= min_minutes and minutes_remaining <= max_minutes

              _ ->
                false
            end
          end)
          |> Enum.map(&parse_event/1)

        {:ok, filtered_events}

      {:ok, %{status: 429}} when retries_left > 0 ->
        wait_ms = 2000 * (@max_retries - retries_left + 1)
        Logger.warning("[Gamma] Rate limited on #{tag} markets, waiting #{wait_ms}ms")
        Process.sleep(wait_ms)
        do_fetch_tagged_crypto_markets(tag, opts, retries_left - 1, default_max_minutes)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[Gamma] #{tag} markets API returned #{status}: #{inspect(body)}")
        {:error, "API returned #{status}"}

      {:error, reason} when retries_left > 0 ->
        Logger.warning("[Gamma] #{tag} markets request failed, retrying: #{inspect(reason)}")
        Process.sleep(500)
        do_fetch_tagged_crypto_markets(tag, opts, retries_left - 1, default_max_minutes)

      {:error, reason} ->
        Logger.error("[Gamma] #{tag} markets request failed: #{inspect(reason)}")
        {:error, reason}
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

    # Fetch from requested interval tags
    results =
      intervals
      |> Enum.map(fn interval ->
        fetch_opts = [max_minutes: max_minutes, min_minutes: min_minutes]

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
  Check if an event is crypto-related based on title, description, and tags.
  """
  def is_crypto_event?(event) when is_map(event) do
    title = String.downcase(event["title"] || "")
    desc = String.downcase(event["description"] || "")

    crypto_keywords = [
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

    # Check title first (most reliable)
    title_match = Enum.any?(crypto_keywords, &String.contains?(title, &1))

    # Check tags if available
    tags = event["tags"] || []

    tag_match =
      Enum.any?(tags, fn tag ->
        label = String.downcase(tag["label"] || "")
        label == "crypto" or String.contains?(label, "crypto")
      end)

    # Check description as fallback
    desc_match = Enum.any?(crypto_keywords, &String.contains?(desc, &1))

    title_match or tag_match or desc_match
  end

  def is_crypto_event?(_), do: false

  defp parse_end_date_for_filter(nil), do: {:error, nil}

  defp parse_end_date_for_filter(end_date) when is_binary(end_date) do
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

  defp parse_end_date_for_filter(end_date) when is_integer(end_date) do
    {:ok, DateTime.from_unix!(end_date)}
  end

  defp parse_end_date_for_filter(_), do: {:error, :invalid_format}

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
        {:ok, parse_event(event)}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, "API returned #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
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
          |> Enum.map(&parse_search_event/1)

        {:ok, events}

      {:ok, %{status: status}} ->
        {:error, "Search API returned #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp parse_search_event(event) do
    # Search API returns slightly different format
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

  defp parse_event(event) do
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
      # Aggregate token IDs from all markets for easy selection
      token_ids: Enum.flat_map(markets, & &1.token_ids)
    }
  end

  defp parse_market(market) do
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

  defp parse_clob_token_ids(nil), do: []

  defp parse_clob_token_ids(ids) when is_binary(ids) do
    case Jason.decode(ids) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp parse_clob_token_ids(ids) when is_list(ids), do: ids

  defp parse_json_array(nil), do: []

  defp parse_json_array(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp parse_json_array(list) when is_list(list), do: list

  defp parse_price(price) when is_binary(price) do
    case Float.parse(price) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_price(price) when is_number(price), do: price * 1.0
  defp parse_price(_), do: 0.0

  defp parse_tags(nil), do: []

  defp parse_tags(tags) when is_list(tags) do
    Enum.map(tags, fn tag ->
      %{id: tag["id"], label: tag["label"], slug: tag["slug"]}
    end)
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, _key, ""), do: params
  defp maybe_add_param(params, key, value), do: Keyword.put(params, key, value)

  defp maybe_filter_search(events, nil), do: events
  defp maybe_filter_search(events, ""), do: events

  defp maybe_filter_search(events, search) do
    search_lower = String.downcase(search)

    Enum.filter(events, fn event ->
      title = String.downcase(event["title"] || "")
      desc = String.downcase(event["description"] || "")
      String.contains?(title, search_lower) or String.contains?(desc, search_lower)
    end)
  end
end
