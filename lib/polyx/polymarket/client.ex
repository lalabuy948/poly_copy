defmodule Polyx.Polymarket.Client do
  @moduledoc """
  HTTP client for Polymarket CLOB API.

  Handles L2 authentication (HMAC) for authenticated requests.
  Includes rate limiting (120 req/min for CLOB, 60 req/min for Data API).
  """

  require Logger

  alias Polyx.Polymarket.RateLimiter
  alias Polyx.Polymarket.Client.{Auth, RequestBuilder, RetryHandler, Pagination}

  # Slightly higher receive_timeout to tolerate slow Data API responses
  @req_options [retry: false, receive_timeout: 20_000]

  # Custom error struct for better error context
  defmodule APIError do
    @moduledoc "Structured API error with context"
    defexception [:message, :status, :endpoint, :reason, :retryable]

    @impl true
    def message(%{message: msg}), do: msg
  end

  # Public API - Trades

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

  # Public API - Markets

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

  # Public API - Order Placement

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

  # Public API - Positions

  @doc """
  Get current positions for a user (Data API - public endpoint).
  Returns list of positions with title, outcome, size, price, PnL etc.
  Uses larger page size for fewer requests.
  """
  def get_positions(address) do
    Pagination.fetch_all_paginated(
      fn page_size, offset ->
        data_api_get("/positions", %{user: address, limit: page_size, offset: offset})
      end,
      500
    )
  end

  @doc """
  Get closed positions for a user (Data API - public endpoint).
  Returns list of closed positions with realizedPnl for each.
  Uses larger page size for fewer requests.
  """
  def get_closed_positions(address) do
    Pagination.fetch_all_paginated(
      fn page_size, offset ->
        data_api_get("/closed-positions", %{user: address, limit: page_size, offset: offset})
      end,
      500
    )
  end

  # Public API - Activity

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

    Pagination.fetch_activities_concurrent(
      fn page_size, offset, mode ->
        case mode do
          :nowait ->
            data_api_get_nowait("/activity", %{user: address, limit: page_size, offset: offset})

          :blocking ->
            data_api_get("/activity", %{user: address, limit: page_size, offset: offset})
        end
      end,
      max_activities,
      on_progress: on_progress
    )
  end

  # Public API - Connection & Auth

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

  # Public API - Balance

  @doc """
  Get USDC balance and allowances for the configured wallet.
  Returns balance in human-readable format (divided by 10^6).
  """
  def get_balance do
    authenticated_get("/balance-allowance", %{asset_type: "COLLATERAL", signature_type: "2"})
    |> case do
      {:ok, %{"balance" => balance_str}} ->
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

  # Private functions - Order Placement

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
    conf = config()
    url = RequestBuilder.build_url("/order", %{}, conf)
    timestamp = System.system_time(:second) |> to_string()

    # Build the request body
    body =
      Jason.encode!(%{
        order: signed_order,
        owner: conf[:api_key],
        orderType: order_type
      })

    headers =
      RequestBuilder.default_headers()
      |> Auth.add_l2_auth_headers_post("POST", "/order", body, timestamp, conf)

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

  # Private functions - Request Helpers

  # Authenticated request with L2 headers (HMAC signature)
  # Rate limited to 120 requests/minute (CLOB bucket)
  defp authenticated_get(path, params) do
    with :ok <- RateLimiter.acquire(:clob) do
      RetryHandler.with_retry(
        fn -> do_authenticated_get(path, params) end,
        api_name: "CLOB",
        path: path
      )
    end
  end

  defp do_authenticated_get(path, params) do
    conf = config()
    url = RequestBuilder.build_url(path, params, conf)
    timestamp = System.system_time(:second) |> to_string()

    headers =
      RequestBuilder.default_headers()
      |> Auth.add_l2_auth_headers("GET", path, params, timestamp, conf)

    Req.get(url, [headers: headers] ++ @req_options)
  end

  # Public request without authentication
  # Rate limited to 120 requests/minute (CLOB bucket)
  defp public_get(path, params) do
    with :ok <- RateLimiter.acquire(:clob) do
      RetryHandler.with_retry(
        fn -> do_public_get(path, params) end,
        api_name: "CLOB",
        path: path
      )
    end
  end

  defp do_public_get(path, params) do
    conf = config()
    url = RequestBuilder.build_url(path, params, conf)
    Req.get(url, [headers: RequestBuilder.default_headers()] ++ @req_options)
  end

  # Data API request (rate limited to 60 requests/minute)
  defp data_api_get(path, params) do
    with :ok <- RateLimiter.acquire(:data) do
      RetryHandler.with_retry(
        fn -> do_data_api_get(path, params) end,
        api_name: "Data API",
        path: path
      )
    end
  end

  # Data API request without waiting for rate limiter (for background polling)
  defp data_api_get_nowait(path, params) do
    case RateLimiter.try_acquire(:data) do
      :ok ->
        RetryHandler.with_retry(
          fn -> do_data_api_get(path, params) end,
          api_name: "Data API",
          path: path
        )

      {:error, :rate_limited} ->
        {:error, :rate_limited}
    end
  end

  defp do_data_api_get(path, params) do
    url = RequestBuilder.build_data_api_url(path, params)
    Req.get(url, [headers: RequestBuilder.default_headers()] ++ @req_options)
  end

  # Private helper functions

  defp get_best_price([%{"price" => price} | _]) when is_binary(price) do
    case Float.parse(price) do
      {val, _} -> val
      :error -> nil
    end
  end

  defp get_best_price([%{"price" => price} | _]) when is_number(price), do: price
  defp get_best_price(_), do: nil

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

  defp config do
    # Read from database credentials instead of Application config
    Polyx.Credentials.to_config()
  end
end
