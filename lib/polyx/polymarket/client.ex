defmodule Polyx.Polymarket.Client do
  @moduledoc """
  HTTP client for Polymarket CLOB API.

  Handles L2 authentication (HMAC) for authenticated requests.
  Includes rate limiting (120 req/min for CLOB, 60 req/min for Data API).
  """

  require Logger

  alias Polyx.Polymarket.RateLimiter

  # Disable automatic retries - we handle rate limiting ourselves
  @req_options [retry: false, receive_timeout: 10_000]

  # Max retries for transient failures
  @max_retries 3

  # Custom error struct for better error context
  defmodule APIError do
    @moduledoc "Structured API error with context"
    defexception [:message, :status, :endpoint, :reason, :retryable]

    @impl true
    def message(%{message: msg}), do: msg
  end

  @doc """
  Get trades for a specific user address.
  Can filter by maker or taker role.
  """
  def get_trades(address, opts \\ []) do
    params =
      opts
      |> Keyword.take([:maker, :taker, :market, :before, :after])
      |> Keyword.put_new(:maker, address)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    authenticated_get("/data/trades", params)
  end

  @doc """
  Get trades where the user was the taker.
  """
  def get_taker_trades(address, opts \\ []) do
    params =
      opts
      |> Keyword.take([:market, :before, :after])
      |> Keyword.put(:taker, address)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    authenticated_get("/data/trades", params)
  end

  @doc """
  Get market information by condition ID.
  """
  def get_market(condition_id) do
    public_get("/markets/#{condition_id}", %{})
  end

  @doc """
  Get all markets (paginated).
  """
  def get_markets(opts \\ []) do
    params =
      opts
      |> Keyword.take([:next_cursor, :limit])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    public_get("/markets", params)
  end

  @doc """
  Get orderbook for a specific token.
  """
  def get_orderbook(token_id) do
    public_get("/book", %{token_id: token_id})
  end

  @doc """
  Get price for a token and side.
  """
  def get_price(token_id, side) do
    public_get("/price", %{token_id: token_id, side: side})
  end

  @doc """
  Get midpoint price for a token.
  """
  def get_midpoint(token_id) do
    public_get("/midpoint", %{token_id: token_id})
  end

  @doc """
  Fetch prices for multiple tokens concurrently.
  Returns a map of %{token_id => %{mid: price, bid: price, ask: price}}.
  Uses Task.async_stream for concurrent fetching with backpressure.
  """
  def get_prices_bulk(token_ids, opts \\ []) when is_list(token_ids) do
    max_concurrency = Keyword.get(opts, :max_concurrency, 5)

    results =
      token_ids
      |> Task.async_stream(
        fn token_id ->
          case get_orderbook(token_id) do
            {:ok, %{"bids" => bids, "asks" => asks}} ->
              best_bid = get_best_price(bids)
              best_ask = get_best_price(asks)

              mid =
                if best_bid && best_ask, do: (best_bid + best_ask) / 2, else: best_bid || best_ask

              {token_id,
               %{
                 best_bid: best_bid,
                 best_ask: best_ask,
                 mid: mid,
                 updated_at: System.system_time(:millisecond)
               }}

            _ ->
              {token_id, nil}
          end
        end,
        max_concurrency: max_concurrency,
        timeout: 10_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{}, fn
        {:ok, {_token_id, nil}}, acc -> acc
        {:ok, {token_id, price_data}}, acc -> Map.put(acc, token_id, price_data)
        {:exit, _reason}, acc -> acc
      end)

    {:ok, results}
  end

  defp get_best_price([%{"price" => price} | _]) when is_binary(price) do
    case Float.parse(price) do
      {val, _} -> val
      :error -> nil
    end
  end

  defp get_best_price([%{"price" => price} | _]) when is_number(price), do: price
  defp get_best_price(_), do: nil

  @doc """
  Place an order on Polymarket.

  Required params:
  - token_id: The ERC1155 token ID for the outcome
  - side: "BUY" or "SELL"
  - size: Dollar amount for buy, share amount for sell
  - price: Price per share (0.0 to 1.0)

  Optional:
  - order_type: "GTC" (default), "FOK", "FAK", "GTD"
  - neg_risk: Whether this is a neg risk market (default false)
  """
  def place_order(order_params) do
    do_place_order(order_params)
  end

  defp do_place_order(params) do
    private_key = config()[:private_key]
    wallet_address = config()[:wallet_address]
    signer_address = config()[:signer_address]

    if is_nil(private_key) or is_nil(wallet_address) do
      Logger.error("Private key or wallet address not configured")
      {:error, :credentials_not_configured}
    else
      alias Polyx.Polymarket.OrderBuilder

      # Convert side from string to atom
      side = parse_side(params[:side] || params["side"])
      token_id = params[:token_id] || params["token_id"]
      size = parse_number(params[:size] || params["size"])
      price = parse_number(params[:price] || params["price"])
      order_type = params[:order_type] || params["order_type"] || "GTC"

      # Auto-detect neg_risk from orderbook if not provided
      neg_risk_result =
        case params[:neg_risk] || params["neg_risk"] do
          nil -> detect_neg_risk(token_id)
          value -> value
        end

      case neg_risk_result do
        {:error, reason} ->
          Logger.error("Cannot place order: #{reason}")
          {:error, reason}

        neg_risk when is_boolean(neg_risk) ->
          Logger.info(
            "Building order: #{side} #{size} @ #{price} for token #{token_id} (#{order_type}, neg_risk=#{neg_risk})"
          )

          # Build order opts - include signer_address if using proxy wallet
          order_opts = [
            private_key: private_key,
            wallet_address: wallet_address,
            neg_risk: neg_risk
          ]

          order_opts =
            if signer_address do
              Keyword.put(order_opts, :signer_address, signer_address)
            else
              order_opts
            end

          case OrderBuilder.build_order(token_id, side, size, price, order_opts) do
            {:ok, signed_order} ->
              submit_order(signed_order, order_type)

            {:error, reason} ->
              Logger.error("Failed to build order: #{inspect(reason)}")
              {:error, reason}
          end
      end
    end
  end

  defp detect_neg_risk(token_id) do
    case get_orderbook(token_id) do
      {:ok, %{"neg_risk" => neg_risk}} when is_boolean(neg_risk) ->
        Logger.debug("Auto-detected neg_risk=#{neg_risk} for token #{token_id}")
        neg_risk

      {:ok, orderbook} ->
        Logger.error(
          "Orderbook missing neg_risk field for token #{token_id}. Response: #{inspect(Map.keys(orderbook))}"
        )

        {:error, "Market configuration unavailable"}

      {:error, _reason} ->
        Logger.warning("Cannot place order: market closed (no orderbook for #{token_id})")
        {:error, "Market is closed"}
    end
  end

  defp submit_order(signed_order, order_type) do
    url = build_url("/order", %{})
    timestamp = System.system_time(:second) |> to_string()

    # Build the request body
    body =
      Jason.encode!(%{
        order: signed_order,
        owner: config()[:api_key],
        orderType: order_type
      })

    headers =
      default_headers()
      |> add_l2_auth_headers_post("POST", "/order", body, timestamp)

    Logger.debug("Submitting order to #{url}")
    Logger.debug("Order body: #{body}")

    case Req.post(url, [body: body, headers: headers] ++ @req_options) do
      {:ok, %Req.Response{status: 200, body: resp_body}} ->
        Logger.info("Order submitted successfully: #{inspect(resp_body)}")
        {:ok, resp_body}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        Logger.error("Order submission failed (#{status}): #{inspect(resp_body)}")
        {:error, {status, resp_body}}

      {:error, reason} ->
        Logger.error("Order request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_side("BUY"), do: :buy
  defp parse_side("SELL"), do: :sell
  defp parse_side("YES"), do: :buy
  defp parse_side("NO"), do: :sell
  defp parse_side(:buy), do: :buy
  defp parse_side(:sell), do: :sell
  defp parse_side(_), do: :buy

  defp parse_number(n) when is_number(n), do: n

  defp parse_number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_number(_), do: 0.0

  @doc """
  Get current positions for a user (Data API - public endpoint).
  Returns list of positions with title, outcome, size, price, PnL etc.
  Uses larger page size for fewer requests.
  """
  def get_positions(address) do
    # Use 500 items per page to minimize API calls
    fetch_all_paginated("/positions", address, 500)
  end

  @doc """
  Get closed positions for a user (Data API - public endpoint).
  Returns list of closed positions with realizedPnl for each.
  Uses larger page size for fewer requests.
  """
  def get_closed_positions(address) do
    # Use 500 items per page to minimize API calls (was 50, causing many sequential requests)
    fetch_all_paginated("/closed-positions", address, 500)
  end

  # Fetch all pages of a paginated endpoint
  # Stops when receiving a partial page (fewer items than page_size)
  defp fetch_all_paginated(path, address, page_size, offset \\ 0, acc \\ []) do
    page_start = System.monotonic_time(:millisecond)

    case data_api_get(path, %{user: address, limit: page_size, offset: offset}) do
      {:ok, items} when is_list(items) and length(items) == page_size ->
        # Full page - there might be more
        page_elapsed = System.monotonic_time(:millisecond) - page_start

        Logger.debug(
          "[Client] #{path} page at offset=#{offset}: #{length(items)} items in #{page_elapsed}ms"
        )

        fetch_all_paginated(path, address, page_size, offset + page_size, acc ++ items)

      {:ok, items} when is_list(items) and length(items) > 0 ->
        # Partial page - this is the last page, no need to fetch more
        page_elapsed = System.monotonic_time(:millisecond) - page_start
        total = acc ++ items

        Logger.debug(
          "[Client] #{path} done: #{length(total)} items (last page: #{length(items)}) in #{page_elapsed}ms"
        )

        {:ok, total}

      {:ok, items} when is_list(items) ->
        # Empty page - we're done
        page_elapsed = System.monotonic_time(:millisecond) - page_start

        Logger.debug(
          "[Client] #{path} done: #{length(acc)} items (empty page) in #{page_elapsed}ms"
        )

        {:ok, acc}

      {:error, reason} when acc == [] ->
        page_elapsed = System.monotonic_time(:millisecond) - page_start

        Logger.warning(
          "[Client] #{path} failed at offset=#{offset} in #{page_elapsed}ms: #{inspect(reason)}"
        )

        {:error, reason}

      {:error, reason} ->
        page_elapsed = System.monotonic_time(:millisecond) - page_start

        Logger.warning(
          "[Client] #{path} error at offset=#{offset} in #{page_elapsed}ms: #{inspect(reason)}, returning #{length(acc)} items"
        )

        # Return what we have so far if we hit an error mid-pagination
        {:ok, acc}
    end
  end

  @doc """
  Get user activity/trades history (Data API - public endpoint).
  Fetches activities using pagination with a configurable limit.

  Options:
  - max_activities: Maximum number of activities to fetch (default: 10_000)
  - on_progress: Optional callback fn(fetched_count) for progress updates
  """
  def get_activity(address, opts \\ []) do
    max_activities = Keyword.get(opts, :max_activities, 10_000)
    on_progress = Keyword.get(opts, :on_progress)

    fetch_activities_concurrent(address, max_activities, on_progress)
  end

  # Fetch activities using concurrent requests for speed
  # Uses a smart probe to avoid unnecessary concurrent requests for small profiles
  defp fetch_activities_concurrent(address, max_activities, on_progress) do
    # For small limits, use non-blocking to avoid blocking background polling
    if max_activities <= 500 do
      case data_api_get_nowait("/activity", %{user: address, limit: max_activities, offset: 0}) do
        {:ok, activities} when is_list(activities) ->
          if on_progress do
            on_progress.(%{batch: 1, total_batches: 1, activities: length(activities)})
          end

          {:ok, activities}

        {:error, :rate_limited} ->
          # Return error so caller knows to retry later
          {:error, :rate_limited}

        {:error, reason} ->
          {:error, reason}
      end
    else
      fetch_activities_large(address, max_activities, on_progress)
    end
  end

  # Fetch large number of activities using concurrent requests
  defp fetch_activities_large(address, max_activities, on_progress) do
    page_size = 500
    # Calculate how many pages we need (at least 1)
    max_pages = max(1, div(max_activities, page_size))

    Logger.debug(
      "[Client] Starting activity fetch, max_pages=#{max_pages}, page_size=#{page_size}"
    )

    # Smart probe: fetch first page (500 items) to determine if we need concurrent fetching
    probe_start = System.monotonic_time(:millisecond)

    case data_api_get("/activity", %{user: address, limit: page_size, offset: 0}) do
      {:ok, first_page} when is_list(first_page) ->
        probe_elapsed = System.monotonic_time(:millisecond) - probe_start
        count = length(first_page)
        Logger.info("[Client] Activity probe: #{count} items in #{probe_elapsed}ms")

        cond do
          count == 0 ->
            # No activities
            {:ok, []}

          count < page_size ->
            # Small profile - we already have all activities from the probe
            if on_progress do
              on_progress.(%{batch: 1, total_batches: 1, activities: count})
            end

            {:ok, first_page}

          true ->
            # Large profile - need to fetch more pages concurrently
            # Start from page 1 since we already have page 0
            total_batches = max(1, ceil((max_pages - 1) / 10))

            if on_progress do
              on_progress.(%{batch: 0, total_batches: total_batches, activities: count})
            end

            fetch_remaining_pages(address, max_pages, page_size, first_page, on_progress)
        end

      {:error, reason} ->
        probe_elapsed = System.monotonic_time(:millisecond) - probe_start
        Logger.warning("[Client] Activity probe failed in #{probe_elapsed}ms: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Fetch remaining pages (starting from page 1) for large profiles
  defp fetch_remaining_pages(address, max_pages, page_size, first_page, on_progress) do
    Logger.debug("[Client] Fetching remaining pages (already have page 0)")
    fetch_pages_concurrent(address, max_pages, page_size, on_progress, first_page, 1)
  end

  defp fetch_pages_concurrent(address, max_pages, page_size, on_progress, initial_acc, start_page) do
    # Fetch pages in batches of 10 concurrent requests
    batch_size = 10
    max_retries = 3
    total_batches = max(1, ceil((max_pages - start_page) / batch_size))

    Logger.debug(
      "[Client] Starting concurrent page fetch, start_page=#{start_page}, max_pages=#{max_pages}"
    )

    result =
      start_page..(max_pages - 1)
      |> Enum.chunk_every(batch_size)
      |> Enum.reduce_while({:ok, initial_acc, 0}, fn page_batch, {:ok, acc, batch_num} ->
        batch_start = System.monotonic_time(:millisecond)
        Logger.debug("[Client] Fetching batch #{batch_num + 1}, pages #{inspect(page_batch)}")

        # Fetch each page with retries
        results =
          page_batch
          |> Task.async_stream(
            fn page_num ->
              offset = page_num * page_size
              fetch_page_with_retry(address, page_size, offset, max_retries)
            end,
            max_concurrency: batch_size,
            timeout: 60_000,
            on_timeout: :kill_task
          )
          |> Enum.map(fn
            {:ok, result} -> result
            {:exit, reason} -> {:error, {:task_exit, reason}}
          end)

        # Process results - track failed pages
        {activities, should_stop, failed_pages} =
          results
          |> Enum.with_index()
          |> Enum.reduce({[], false, []}, fn {result, idx}, {acts, stop, failed} ->
            page_num = Enum.at(page_batch, idx)

            case result do
              {:ok, page_activities} when is_list(page_activities) ->
                if length(page_activities) < page_size do
                  # Last page - we're done after this batch
                  {acts ++ page_activities, true, failed}
                else
                  {acts ++ page_activities, stop, failed}
                end

              {:ok, _} ->
                {acts, true, failed}

              {:error, reason} ->
                Logger.warning(
                  "Failed to fetch activity page #{page_num} after retries: #{inspect(reason)}"
                )

                {acts, stop, [page_num | failed]}
            end
          end)

        batch_elapsed = System.monotonic_time(:millisecond) - batch_start
        new_acc = acc ++ activities

        Logger.debug(
          "[Client] Batch #{batch_num + 1} completed in #{batch_elapsed}ms, " <>
            "fetched #{length(activities)} activities, total=#{length(new_acc)}, should_stop=#{should_stop}"
        )

        # Log if we had failed pages
        if failed_pages != [] do
          Logger.warning(
            "Activity fetch had #{length(failed_pages)} failed pages: #{inspect(failed_pages)}"
          )
        end

        # Report progress if callback provided (with detailed batch info)
        if on_progress do
          on_progress.(%{
            batch: batch_num + 1,
            total_batches: total_batches,
            activities: length(new_acc)
          })
        end

        if should_stop or length(new_acc) >= max_pages * page_size do
          {:halt, {:ok, new_acc}}
        else
          {:cont, {:ok, new_acc, batch_num + 1}}
        end
      end)

    case result do
      {:ok, activities} -> {:ok, activities}
      {:ok, activities, _batch_num} -> {:ok, activities}
    end
  end

  # Fetch a single page with exponential backoff retry
  defp fetch_page_with_retry(address, page_size, offset, retries_left, delay \\ 1000)

  defp fetch_page_with_retry(_address, _page_size, _offset, 0, _delay) do
    {:error, :max_retries_exceeded}
  end

  defp fetch_page_with_retry(address, page_size, offset, retries_left, delay) do
    case data_api_get("/activity", %{user: address, limit: page_size, offset: offset}) do
      {:ok, _} = success ->
        success

      {:error, {429, _}} ->
        # Rate limited - wait longer
        Logger.debug(
          "Rate limited fetching activity page at offset #{offset}, retrying in #{delay * 2}ms"
        )

        Process.sleep(delay * 2)
        fetch_page_with_retry(address, page_size, offset, retries_left - 1, delay * 2)

      {:error, {status, _}} when status >= 500 ->
        # Server error - retry with backoff
        Logger.debug(
          "Server error #{status} fetching activity page at offset #{offset}, retrying in #{delay}ms"
        )

        Process.sleep(delay)
        fetch_page_with_retry(address, page_size, offset, retries_left - 1, delay * 2)

      {:error, _} = error ->
        # Client error or other - don't retry
        error
    end
  end

  @doc """
  Test the API connection and credentials.
  Returns {:ok, server_time} if successful, {:error, reason} otherwise.
  """
  def test_connection do
    # First test public endpoint (no auth needed)
    case public_get("/time", %{}) do
      {:ok, time} ->
        # Now test authenticated endpoint
        case authenticated_get("/data/orders", %{}) do
          {:ok, _} ->
            {:ok, %{server_time: time, auth: :valid}}

          {:error, {401, _}} ->
            {:ok, %{server_time: time, auth: :invalid_credentials}}

          {:error, reason} ->
            {:ok, %{server_time: time, auth: {:error, reason}}}
        end

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  @doc """
  Check if credentials are configured.
  """
  def credentials_configured? do
    Polyx.Credentials.configured?()
  end

  @doc """
  Get USDC balance and allowances for the configured wallet.
  Returns balance in human-readable format (divided by 10^6).
  """
  def get_balance do
    # For proxy wallets, signature_type=2
    authenticated_get("/balance-allowance", %{asset_type: "COLLATERAL", signature_type: "2"})
    |> case do
      {:ok, %{"balance" => balance_str}} ->
        # Balance is in micro USDC (6 decimals)
        balance = String.to_integer(balance_str) / 1_000_000
        {:ok, balance}

      {:ok, response} ->
        Logger.warning("Unexpected balance response: #{inspect(response)}")
        {:error, :unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get full balance and allowance info for debugging.
  """
  def get_balance_allowance_raw do
    authenticated_get("/balance-allowance", %{asset_type: "COLLATERAL", signature_type: "2"})
  end

  @doc """
  Get account summary including balance and positions value.
  """
  def get_account_summary do
    wallet_address = config()[:wallet_address]

    with {:ok, balance} <- get_balance(),
         {:ok, positions} <- get_positions(wallet_address) do
      total_value =
        Enum.reduce(positions, 0.0, fn pos, acc ->
          acc + (pos["currentValue"] || 0)
        end)

      total_pnl =
        Enum.reduce(positions, 0.0, fn pos, acc ->
          acc + (pos["cashPnl"] || 0)
        end)

      {:ok,
       %{
         usdc_balance: balance,
         positions_value: total_value,
         total_pnl: total_pnl,
         positions_count: length(positions)
       }}
    end
  end

  # Private functions

  # Authenticated request with L2 headers (HMAC signature)
  # Rate limited to 120 requests/minute (CLOB bucket)
  defp authenticated_get(path, params) do
    with :ok <- RateLimiter.acquire(:clob) do
      do_authenticated_get(path, params, @max_retries)
    end
  end

  defp do_authenticated_get(path, params, retries_left) do
    url = build_url(path, params)
    # Timestamp must be in seconds (not milliseconds) to match Python client
    timestamp = System.system_time(:second) |> to_string()

    headers =
      default_headers()
      |> add_l2_auth_headers("GET", path, params, timestamp)

    case Req.get(url, [headers: headers] ++ @req_options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 429, body: body}} ->
        handle_rate_limit("CLOB", path, body, retries_left, fn ->
          do_authenticated_get(path, params, retries_left - 1)
        end)

      {:ok, %Req.Response{status: status}} when status >= 500 and retries_left > 0 ->
        Logger.warning("CLOB API server error #{status}, retrying (#{retries_left} left)")
        Process.sleep(1000)
        do_authenticated_get(path, params, retries_left - 1)

      {:ok, %Req.Response{status: status, body: body}} ->
        error = build_api_error("CLOB", path, status, body)
        Logger.warning("CLOB API error: #{error.message}")
        {:error, error}

      {:error, %Req.TransportError{reason: reason}} when retries_left > 0 ->
        Logger.warning("CLOB API transport error: #{inspect(reason)}, retrying")
        Process.sleep(500)
        do_authenticated_get(path, params, retries_left - 1)

      {:error, reason} ->
        error = build_api_error("CLOB", path, nil, reason)
        Logger.error("CLOB API request failed: #{inspect(reason)}")
        {:error, error}
    end
  end

  # Public request without authentication
  # Rate limited to 120 requests/minute (CLOB bucket)
  defp public_get(path, params) do
    with :ok <- RateLimiter.acquire(:clob) do
      do_public_get(path, params, @max_retries)
    end
  end

  defp do_public_get(path, params, retries_left) do
    url = build_url(path, params)

    case Req.get(url, [headers: default_headers()] ++ @req_options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 429, body: body}} ->
        handle_rate_limit("CLOB", path, body, retries_left, fn ->
          do_public_get(path, params, retries_left - 1)
        end)

      {:ok, %Req.Response{status: status, body: _body}} when status >= 500 and retries_left > 0 ->
        Logger.warning("CLOB API server error #{status}, retrying (#{retries_left} left)")
        Process.sleep(1000)
        do_public_get(path, params, retries_left - 1)

      {:ok, %Req.Response{status: status, body: body}} ->
        error = build_api_error("CLOB", path, status, body)
        Logger.warning("CLOB API error: #{error.message}")
        {:error, error}

      {:error, %Req.TransportError{reason: reason}} when retries_left > 0 ->
        Logger.warning("CLOB API transport error: #{inspect(reason)}, retrying")
        Process.sleep(500)
        do_public_get(path, params, retries_left - 1)

      {:error, reason} ->
        error = build_api_error("CLOB", path, nil, reason)
        Logger.error("CLOB API request failed: #{inspect(reason)}")
        {:error, error}
    end
  end

  # Data API request (rate limited to 60 requests/minute)
  defp data_api_get(path, params) do
    with :ok <- RateLimiter.acquire(:data) do
      do_data_api_get(path, params, @max_retries)
    end
  end

  # Data API request without waiting for rate limiter (for background polling)
  # Returns {:error, :rate_limited} immediately if rate limited
  defp data_api_get_nowait(path, params) do
    case RateLimiter.try_acquire(:data) do
      :ok ->
        do_data_api_get(path, params, @max_retries)

      {:error, :rate_limited} ->
        {:error, :rate_limited}
    end
  end

  defp do_data_api_get(path, params, retries_left) do
    url = build_data_api_url(path, params)

    case Req.get(url, [headers: default_headers()] ++ @req_options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 429, body: body}} ->
        handle_rate_limit("Data API", path, body, retries_left, fn ->
          do_data_api_get(path, params, retries_left - 1)
        end)

      {:ok, %Req.Response{status: status, body: _body}} when status >= 500 and retries_left > 0 ->
        Logger.warning("Data API server error #{status}, retrying (#{retries_left} left)")
        Process.sleep(1000)
        do_data_api_get(path, params, retries_left - 1)

      {:ok, %Req.Response{status: status, body: body}} ->
        error = build_api_error("Data API", path, status, body)
        Logger.warning("Data API error: #{error.message}")
        {:error, error}

      {:error, %Req.TransportError{reason: reason}} when retries_left > 0 ->
        Logger.warning("Data API transport error: #{inspect(reason)}, retrying")
        Process.sleep(500)
        do_data_api_get(path, params, retries_left - 1)

      {:error, reason} ->
        error = build_api_error("Data API", path, nil, reason)
        Logger.error("Data API request failed: #{inspect(reason)}")
        {:error, error}
    end
  end

  # Handle 429 rate limit responses with backoff
  defp handle_rate_limit(api_name, path, body, retries_left, retry_fn) do
    if retries_left > 0 do
      # Extract retry-after header or use default backoff
      wait_ms = 2000 * (@max_retries - retries_left + 1)

      Logger.warning(
        "#{api_name} rate limited on #{path}, waiting #{wait_ms}ms (#{retries_left} retries left)"
      )

      Process.sleep(wait_ms)
      retry_fn.()
    else
      error = build_api_error(api_name, path, 429, body)
      Logger.error("#{api_name} rate limit exceeded after retries: #{path}")
      {:error, error}
    end
  end

  # Build structured API error
  defp build_api_error(api_name, endpoint, status, reason) do
    retryable = status in [429, 500, 502, 503, 504] or is_nil(status)

    message =
      case reason do
        %{"error" => msg} -> "#{api_name} #{endpoint}: #{msg}"
        msg when is_binary(msg) -> "#{api_name} #{endpoint}: #{msg}"
        _ -> "#{api_name} #{endpoint}: HTTP #{status || "error"} - #{inspect(reason)}"
      end

    %APIError{
      message: message,
      status: status,
      endpoint: endpoint,
      reason: reason,
      retryable: retryable
    }
  end

  defp add_l2_auth_headers(headers, method, request_path, _params, timestamp) do
    api_key = config()[:api_key]
    api_secret = config()[:api_secret]
    passphrase = config()[:api_passphrase]
    # For proxy wallets, POLY_ADDRESS should be the signer (who derived the API creds)
    # Fall back to wallet_address for non-proxy setups
    auth_address = config()[:signer_address] || config()[:wallet_address]

    if api_key && api_secret && passphrase && auth_address do
      # Build the message to sign: timestamp + method + requestPath (no body for GET)
      # Must match Python: str(timestamp) + str(method) + str(requestPath)
      message = timestamp <> method <> request_path

      # Decode secret - try URL-safe first, then standard base64
      secret =
        case Base.url_decode64(api_secret, padding: false) do
          {:ok, decoded} -> decoded
          :error -> Base.decode64!(api_secret)
        end

      # Create HMAC-SHA256 signature and encode with URL-safe base64 (with padding)
      signature =
        :crypto.mac(:hmac, :sha256, secret, message)
        |> Base.url_encode64()

      Logger.debug("HMAC message: #{message}")
      Logger.debug("HMAC signature: #{signature}")
      Logger.debug("Auth address (signer): #{auth_address}")
      Logger.debug("API key: #{api_key}")

      headers ++
        [
          {"POLY_ADDRESS", auth_address},
          {"POLY_SIGNATURE", signature},
          {"POLY_TIMESTAMP", timestamp},
          {"POLY_API_KEY", api_key},
          {"POLY_PASSPHRASE", passphrase}
        ]
    else
      Logger.warning(
        "Missing API credentials: key=#{!!api_key}, secret=#{!!api_secret}, pass=#{!!passphrase}, auth_address=#{!!auth_address}"
      )

      headers
    end
  end

  defp add_l2_auth_headers_post(headers, method, request_path, body, timestamp) do
    api_key = config()[:api_key]
    api_secret = config()[:api_secret]
    passphrase = config()[:api_passphrase]
    # For proxy wallets, POLY_ADDRESS should be the signer (who derived the API creds)
    # Fall back to wallet_address for non-proxy setups
    auth_address = config()[:signer_address] || config()[:wallet_address]

    if api_key && api_secret && passphrase && auth_address do
      # Build the message to sign: timestamp + method + requestPath + body
      # For POST, body is included in the signature
      message = timestamp <> method <> request_path <> body

      # Decode secret - try URL-safe first, then standard base64
      secret =
        case Base.url_decode64(api_secret, padding: false) do
          {:ok, decoded} -> decoded
          :error -> Base.decode64!(api_secret)
        end

      # Create HMAC-SHA256 signature and encode with URL-safe base64 (with padding)
      signature =
        :crypto.mac(:hmac, :sha256, secret, message)
        |> Base.url_encode64()

      Logger.debug("HMAC POST message: #{String.slice(message, 0, 200)}...")
      Logger.debug("HMAC signature: #{signature}")

      headers ++
        [
          {"POLY_ADDRESS", auth_address},
          {"POLY_SIGNATURE", signature},
          {"POLY_TIMESTAMP", timestamp},
          {"POLY_API_KEY", api_key},
          {"POLY_PASSPHRASE", passphrase}
        ]
    else
      Logger.warning("Missing API credentials for POST request")
      headers
    end
  end

  defp build_url(path, params) do
    base = config()[:clob_url] || "https://clob.polymarket.com"
    query = URI.encode_query(params)

    if query == "" do
      "#{base}#{path}"
    else
      "#{base}#{path}?#{query}"
    end
  end

  defp build_data_api_url(path, params) do
    base = "https://data-api.polymarket.com"
    query = URI.encode_query(params)

    if query == "" do
      "#{base}#{path}"
    else
      "#{base}#{path}?#{query}"
    end
  end

  defp default_headers do
    [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"user-agent", "py_clob_client"}
    ]
  end

  defp config do
    # Read from database credentials instead of Application config
    Polyx.Credentials.to_config()
  end
end
