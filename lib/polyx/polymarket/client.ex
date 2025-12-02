defmodule Polyx.Polymarket.Client do
  @moduledoc """
  HTTP client for Polymarket CLOB API.

  Handles L2 authentication (HMAC) for authenticated requests.
  """

  require Logger

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
      neg_risk =
        case params[:neg_risk] || params["neg_risk"] do
          nil -> detect_neg_risk(token_id)
          value -> value
        end

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

  defp detect_neg_risk(token_id) do
    case get_orderbook(token_id) do
      {:ok, %{"neg_risk" => neg_risk}} ->
        Logger.debug("Auto-detected neg_risk=#{neg_risk} for token #{token_id}")
        neg_risk

      _ ->
        Logger.warning("Could not detect neg_risk for token #{token_id}, defaulting to false")
        false
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

    case Req.post(url, body: body, headers: headers) do
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
  """
  def get_positions(address) do
    data_api_get("/positions", %{user: address})
  end

  @doc """
  Get user activity/trades history (Data API - public endpoint).
  """
  def get_activity(address) do
    data_api_get("/activity", %{user: address})
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
    api_key = config()[:api_key]
    api_secret = config()[:api_secret]
    passphrase = config()[:api_passphrase]
    wallet_address = config()[:wallet_address]

    !!(api_key && api_secret && passphrase && wallet_address)
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
  defp authenticated_get(path, params) do
    url = build_url(path, params)
    # Timestamp must be in seconds (not milliseconds) to match Python client
    timestamp = System.system_time(:second) |> to_string()

    headers =
      default_headers()
      |> add_l2_auth_headers("GET", path, params, timestamp)

    case Req.get(url, headers: headers) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Polymarket API returned #{status}: #{inspect(body)}")
        {:error, {status, body}}

      {:error, reason} ->
        Logger.error("Polymarket API request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Public request without authentication
  defp public_get(path, params) do
    url = build_url(path, params)

    case Req.get(url, headers: default_headers()) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Polymarket API returned #{status}: #{inspect(body)}")
        {:error, {status, body}}

      {:error, reason} ->
        Logger.error("Polymarket API request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp data_api_get(path, params) do
    url = build_data_api_url(path, params)

    case Req.get(url, headers: default_headers()) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Data API returned #{status}: #{inspect(body)}")
        {:error, {status, body}}

      {:error, reason} ->
        Logger.error("Data API request failed: #{inspect(reason)}")
        {:error, reason}
    end
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
    Application.get_env(:polyx, :polymarket, [])
  end
end
