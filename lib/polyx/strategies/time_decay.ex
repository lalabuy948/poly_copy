defmodule Polyx.Strategies.TimeDecay do
  @moduledoc """
  Time Decay Strategy - Simple High-Confidence Version.

  Simple logic: BUY any token at 90%+ that is close to resolution.
  - If UP is at 90%+ → BUY UP (it will resolve to $1.00)
  - If DOWN is at 90%+ → BUY DOWN (it will resolve to $1.00)

  One trade per market - once we buy one side, both tokens go on cooldown.

  Config options:
  - high_threshold: Price above which we BUY (default: 0.90)
  - target_high_price: Limit price for buy orders (default: 0.99)
  - order_size: Base order size in USD (default: 10)
  - cooldown_seconds: Cooldown between orders per market (default: 300)
  - min_spread: Maximum spread to tolerate (default: 0.02)
  - use_midpoint: Use midpoint price instead of best_bid (default: true)
  - max_minutes_to_resolution: For discovery, find markets expiring within N minutes (default: 15)
  - min_minutes: Only trade when this many minutes or LESS remain (default: 2)
  - min_profit: Minimum estimated profit in USD to signal (default: 0.01)
  - auto_discover_crypto: Automatically discover 15-min crypto markets (default: false)
  """
  @behaviour Polyx.Strategies.Behaviour

  require Logger

  alias Polyx.Polymarket.{Gamma, Client}

  # Minimum order constraints
  @min_order_value 1.0
  @min_shares 5

  @impl true
  def init(config) do
    # Merge user config with hardcoded defaults
    full_config =
      Map.merge(
        %{
          "auto_discover_crypto" => true,
          "crypto_only" => true,
          # Increased from 15 to 60 minutes
          "max_minutes_to_resolution" => 60,
          "cooldown_seconds" => 60,
          "min_profit" => 0.01,
          "discovery_interval_seconds" => 30,
          "scan_enabled" => false
        },
        config
      )

    state = %{
      config: full_config,
      # Track prices per token
      prices: %{},
      # Cooldown per token to avoid rapid re-entry
      cooldowns: %{},
      # Track placed orders
      placed_orders: %{},
      # Cache market info from Gamma
      market_cache: %{},
      # Track scan offset for pagination
      scan_offset: 0,
      # Last scan time
      last_scan: 0,
      # Last crypto discovery time
      last_crypto_discovery: 0,
      # Discovered crypto tokens (auto-populated in discovery mode)
      discovered_tokens: MapSet.new(),
      # Track which tokens we've already evaluated to avoid re-processing
      evaluated_tokens: MapSet.new(),
      # Tokens removed due to resolution (for Runner to broadcast)
      removed_tokens: [],
      # Flag for async initial discovery
      needs_initial_discovery: false
    }

    # If auto_discover_crypto is enabled, mark for initial discovery (done async by Runner)
    state =
      if full_config["auto_discover_crypto"] == true do
        %{state | needs_initial_discovery: true}
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def validate_config(config) do
    # Simplified validation for new config format
    signal_threshold = config["signal_threshold"]
    order_size = config["order_size"]
    limit_price = config["limit_price"]

    cond do
      signal_threshold != nil and (signal_threshold < 0.5 or signal_threshold > 0.99) ->
        {:error, "signal_threshold must be between 0.5 and 0.99"}

      order_size != nil and order_size <= 0 ->
        {:error, "order_size must be a positive number"}

      limit_price != nil and (limit_price < 0.9 or limit_price > 1.0) ->
        {:error, "limit_price must be between 0.9 and 1.0"}

      true ->
        :ok
    end
  end

  @impl true
  def handle_order(order, state) do
    case order do
      %{event_type: "price_change"} ->
        handle_price_change(order, state)

      %{event_type: "trade"} ->
        handle_trade(order, state)

      # Handle both atom and string keys
      order when is_map(order) ->
        event_type = order[:event_type] || order["event_type"]

        case event_type do
          type when type in ["price_change", :price_change] ->
            handle_price_change(normalize_order(order), state)

          type when type in ["trade", :trade] ->
            handle_trade(normalize_order(order), state)

          _ ->
            {:ok, state}
        end

      _ ->
        {:ok, state}
    end
  end

  @impl true
  def handle_tick(state) do
    now = System.system_time(:second)

    # Clean up expired cooldowns
    cooldowns =
      state.cooldowns
      |> Enum.reject(fn {_token_id, expire_at} -> expire_at < now end)
      |> Map.new()

    state = %{state | cooldowns: cooldowns}

    # Clean up resolved markets from discovered tokens
    {state, removed_tokens} = cleanup_resolved_markets(state)

    config = state.config

    # Auto-discovery of 15-min crypto markets (runs more frequently)
    auto_discover = config["auto_discover_crypto"] == true
    discovery_interval = config["discovery_interval_seconds"] || 30

    state =
      if auto_discover and now - state.last_crypto_discovery >= discovery_interval do
        case discover_crypto_markets(state) do
          {:ok, new_state} ->
            %{new_state | last_crypto_discovery: now}
        end
      else
        state
      end

    # Proactive scanning if enabled (for non-crypto or general markets)
    scan_enabled = config["scan_enabled"] == true
    scan_interval = config["scan_interval_seconds"] || 60

    result =
      if scan_enabled and now - state.last_scan >= scan_interval do
        case scan_near_expiry_markets(state) do
          {:ok, signals, new_state} ->
            {:ok, %{new_state | last_scan: now}, signals}

          {:ok, new_state} ->
            {:ok, %{new_state | last_scan: now}}
        end
      else
        {:ok, state}
      end

    # Attach removed tokens to the result for the Runner to handle
    case result do
      {:ok, final_state, signals} ->
        {:ok, %{final_state | removed_tokens: removed_tokens}, signals}

      {:ok, final_state} ->
        {:ok, %{final_state | removed_tokens: removed_tokens}}
    end
  end

  # Discover crypto markets within the configured time window (default: 15 min)
  # Public so Runner can call it
  def discover_crypto_markets(state) do
    config = state.config
    # Use new default
    max_minutes = config["max_minutes_to_resolution"] || 60
    min_minutes = config["min_minutes_to_resolution"] || 1
    market_timeframe = config["market_timeframe"] || "15m"

    Logger.info(
      "[TimeDecay] Starting crypto discovery: max_minutes=#{max_minutes}, min_minutes=#{min_minutes}"
    )

    # Map timeframe to Gamma API interval
    intervals = timeframe_to_intervals(market_timeframe)

    case Gamma.fetch_crypto_markets_ending_soon(
           max_minutes: max_minutes,
           min_minutes: min_minutes,
           intervals: intervals,
           limit: 100
         ) do
      {:ok, events} ->
        Logger.info("[TimeDecay] Discovery found #{length(events)} events")

        # Extract all token IDs from discovered markets
        all_tokens =
          events
          |> Enum.flat_map(fn event ->
            (event[:markets] || [])
            |> Enum.flat_map(fn market ->
              market[:token_ids] || []
            end)
          end)
          |> MapSet.new()

        Logger.info("[TimeDecay] Discovery found #{MapSet.size(all_tokens)} tokens")

        # Find newly discovered tokens
        new_tokens = MapSet.difference(all_tokens, state.discovered_tokens)

        # Update discovered tokens
        state = %{state | discovered_tokens: MapSet.union(state.discovered_tokens, new_tokens)}

        # Build list of tokens to cache
        # Include tokens that are missing opposite_token_id in cache (for cooldown logic)
        tokens_to_cache =
          events
          |> Enum.flat_map(fn event ->
            (event[:markets] || [])
            |> Enum.flat_map(fn market ->
              Enum.map(market[:token_ids] || [], fn token_id ->
                {token_id, event, market}
              end)
            end)
          end)
          |> Enum.filter(fn {token_id, _event, _market} ->
            # Cache if not evaluated OR if missing opposite_token_id (migration case)
            not MapSet.member?(state.evaluated_tokens, token_id) or
              is_nil(get_in(state.market_cache, [token_id, :opposite_token_id]))
          end)

        # Cache market info (fast, no API calls) - prices come from WebSocket
        state =
          Enum.reduce(tokens_to_cache, state, fn {token_id, event, market}, st ->
            # Find the opposite token (for cooldown logic - one trade per market)
            token_ids = market[:token_ids] || []
            opposite_token_id = Enum.find(token_ids, fn id -> id != token_id end)

            market_info = %{
              question: market[:question],
              event_title: event[:title],
              outcome: get_outcome_for_token(market, token_id),
              opposite_token_id: opposite_token_id,
              end_date: event[:end_date],
              expires_at: System.system_time(:second) + 300
            }

            %{
              st
              | evaluated_tokens: MapSet.put(st.evaluated_tokens, token_id),
                market_cache: Map.put(st.market_cache, token_id, market_info)
            }
          end)

        # Don't fetch orderbooks during discovery - WebSocket will provide real-time prices
        # Signals will be generated when price updates arrive via handle_order
        {:ok, state}
    end
  end

  defp get_outcome_for_token(market, token_id) do
    outcomes = market[:outcomes] || []

    case Enum.find(outcomes, fn o -> o[:token_id] == token_id end) do
      %{name: name} -> name
      _ -> nil
    end
  end

  # Proactive scanning for near-expiry markets
  defp scan_near_expiry_markets(state) do
    config = state.config
    scan_limit = config["scan_limit"] || 20
    max_hours = config["max_hours_to_resolution"] || 24

    case Gamma.fetch_events(limit: scan_limit, offset: state.scan_offset) do
      {:ok, events} ->
        # Filter to near-expiry events
        now = DateTime.utc_now()

        near_expiry_events =
          events
          |> Enum.filter(fn event ->
            case parse_end_date(event[:end_date]) do
              {:ok, end_dt} ->
                hours_remaining = DateTime.diff(end_dt, now, :hour)
                hours_remaining > 0 and hours_remaining <= max_hours

              _ ->
                false
            end
          end)

        # Check each market for opportunities
        {signals, state} =
          near_expiry_events
          |> Enum.flat_map(&(&1[:markets] || []))
          |> Enum.reduce({[], state}, fn market, {sigs, st} ->
            token_ids = market[:token_ids] || []

            Enum.reduce(token_ids, {sigs, st}, fn token_id, {inner_sigs, inner_st} ->
              case check_token_opportunity(inner_st, token_id) do
                {:opportunity, signal, new_st} ->
                  {[signal | inner_sigs], new_st}

                :no_opportunity ->
                  {inner_sigs, inner_st}
              end
            end)
          end)

        # Update scan offset for next iteration (wrap around)
        new_offset =
          if length(events) < scan_limit,
            do: 0,
            else: state.scan_offset + scan_limit

        if signals == [] do
          {:ok, %{state | scan_offset: new_offset}}
        else
          {:ok, Enum.reverse(signals), %{state | scan_offset: new_offset}}
        end

      {:error, reason} ->
        Logger.warning("[TimeDecay] Scan failed: #{inspect(reason)}")
        {:ok, state}
    end
  end

  # Check a specific token for opportunity (used by scanner)
  defp check_token_opportunity(state, token_id) do
    # Fetch current prices from API
    case Client.get_orderbook(token_id) do
      {:ok, %{"bids" => bids, "asks" => asks}} ->
        best_bid = get_best_price(bids)
        best_ask = get_best_price(asks)

        if best_bid || best_ask do
          # Build a pseudo-order for evaluation
          order = %{
            asset_id: token_id,
            best_bid: best_bid,
            best_ask: best_ask,
            market_question: nil
          }

          check_time_decay_opportunity(state, token_id, best_bid, best_ask, order)
        else
          :no_opportunity
        end

      _ ->
        :no_opportunity
    end
  end

  defp get_best_price([%{"price" => price} | _]) when is_binary(price) do
    case Float.parse(price) do
      {val, _} -> val
      :error -> nil
    end
  end

  defp get_best_price([%{"price" => price} | _]) when is_number(price), do: price
  defp get_best_price(_), do: nil

  # Private functions

  defp normalize_order(order) do
    %{
      event_type: order[:event_type] || order["event_type"],
      asset_id: order[:asset_id] || order["asset_id"],
      best_bid: order[:best_bid] || order["best_bid"],
      best_ask: order[:best_ask] || order["best_ask"],
      price: order[:price] || order["price"],
      side: order[:side] || order["side"],
      size: order[:size] || order["size"],
      outcome: order[:outcome] || order["outcome"],
      market_question: order[:market_question] || order["market_question"]
    }
  end

  defp handle_price_change(order, state) do
    asset_id = order.asset_id
    best_bid = parse_price(order.best_bid)
    best_ask = parse_price(order.best_ask)

    # Update prices for this token
    prices =
      Map.put(state.prices, asset_id, %{
        best_bid: best_bid,
        best_ask: best_ask,
        updated_at: System.system_time(:millisecond)
      })

    state = %{state | prices: prices}

    # Check for time decay opportunity
    case check_time_decay_opportunity(state, asset_id, best_bid, best_ask, order) do
      {:opportunity, signal, updated_state} ->
        {:ok, updated_state, [signal]}

      :no_opportunity ->
        {:ok, state}
    end
  end

  defp handle_trade(_order, state) do
    # Trades provide additional price info but we primarily use price_change
    {:ok, state}
  end

  defp parse_price(nil), do: nil
  defp parse_price(price) when is_number(price), do: price

  defp parse_price(price) when is_binary(price) do
    case Float.parse(price) do
      {val, _} -> val
      :error -> nil
    end
  end

  defp check_time_decay_opportunity(state, asset_id, best_bid, best_ask, order) do
    config = state.config

    # User-configurable settings (new simplified config)
    signal_threshold = config["signal_threshold"] || config["high_threshold"] || 0.80
    order_size = config["order_size"] || 5.0
    min_minutes = config["min_minutes"] || config["min_minutes_to_resolution"] || 1.0
    use_limit_order = config["use_limit_order"] != false
    limit_price = config["limit_price"] || config["target_high_price"] || 0.99

    # Hardcoded settings
    cooldown_seconds = config["cooldown_seconds"] || 60
    min_profit = config["min_profit"] || 0.01
    crypto_only = config["crypto_only"] != false

    # Check if we already placed an order for this token (prevents duplicates in same batch)
    already_placed = Map.has_key?(state.placed_orders, asset_id)

    # Check cooldown or already placed (fast path)
    if already_placed or in_cooldown?(state, asset_id) do
      :no_opportunity
    else
      # Calculate price to use (always use midpoint)
      current_price = calculate_evaluation_price(best_bid, best_ask, true)
      _spread = calculate_spread(best_bid, best_ask)

      # Get market info for this token (to determine YES/NO and resolution status)
      {_outcome, market_info, state} = get_token_info(state, asset_id)

      # Check if crypto_only filter should skip non-crypto markets
      is_crypto = is_crypto_market?(market_info)

      # Check time to resolution (minutes-based for crypto markets)
      minutes_to_resolution = calculate_minutes_to_resolution(market_info[:end_date])

      # Time constraints: must be <= min_minutes (only trade very close to expiry)
      # min_minutes means "only trade when this many minutes or less remain"
      time_ok =
        cond do
          is_nil(minutes_to_resolution) -> false
          minutes_to_resolution <= 0 -> false
          minutes_to_resolution > min_minutes -> false
          true -> true
        end

      cond do
        # Price is nil - can't evaluate
        is_nil(current_price) ->
          :no_opportunity

        # Crypto-only filter
        crypto_only and not is_crypto ->
          :no_opportunity

        # Time constraint not met
        not time_ok ->
          :no_opportunity

        # Price not high enough
        current_price <= signal_threshold ->
          :no_opportunity

        # HIGH PRICE: Token likely resolving to 1.0 - BUY!
        current_price > signal_threshold ->
          # Determine buy price: limit order uses limit_price, market order uses best_ask
          buy_price = if use_limit_order, do: limit_price, else: best_ask

          generate_buy_signal(
            state,
            asset_id,
            current_price,
            buy_price,
            order_size,
            cooldown_seconds,
            min_profit,
            :high_price,
            market_info,
            order
          )

        true ->
          :no_opportunity
      end
    end
  end

  # Check if market is crypto-related
  defp is_crypto_market?(market_info) do
    question = String.downcase(market_info[:question] || "")
    event_title = String.downcase(market_info[:event_title] || "")

    crypto_keywords = [
      "bitcoin",
      "btc",
      "ethereum",
      "eth",
      "crypto",
      "solana",
      "sol",
      "xrp",
      "doge"
    ]

    Enum.any?(crypto_keywords, fn kw ->
      String.contains?(question, kw) or String.contains?(event_title, kw)
    end)
  end

  # Clean up resolved markets by refetching active markets from Gamma
  defp cleanup_resolved_markets(state) do
    config = state.config
    max_minutes = config["max_minutes_to_resolution"] || 15
    min_minutes = config["min_minutes_to_resolution"] || 1
    market_timeframe = config["market_timeframe"] || "15m"
    intervals = timeframe_to_intervals(market_timeframe)

    # Refetch currently active markets
    case Gamma.fetch_crypto_markets_ending_soon(
           max_minutes: max_minutes,
           min_minutes: min_minutes,
           intervals: intervals,
           limit: 100
         ) do
      {:ok, events} ->
        # Get all currently active token IDs
        active_tokens =
          events
          |> Enum.flat_map(fn event ->
            (event[:markets] || [])
            |> Enum.flat_map(fn market -> market[:token_ids] || [] end)
          end)
          |> MapSet.new()

        # Find tokens that were discovered but are no longer active (resolved)
        resolved = MapSet.difference(state.discovered_tokens, active_tokens) |> MapSet.to_list()

        # Update state with only active tokens
        new_state = %{
          state
          | discovered_tokens: MapSet.intersection(state.discovered_tokens, active_tokens),
            prices: Map.drop(state.prices, resolved),
            cooldowns: Map.drop(state.cooldowns, resolved),
            placed_orders: Map.drop(state.placed_orders, resolved),
            evaluated_tokens: MapSet.difference(state.evaluated_tokens, MapSet.new(resolved)),
            removed_tokens: resolved
        }

        {new_state, resolved}
    end
  end

  # Calculate minutes until market resolution
  defp calculate_minutes_to_resolution(nil), do: nil

  defp calculate_minutes_to_resolution(end_date) do
    case parse_end_date(end_date) do
      {:ok, end_dt} ->
        now = DateTime.utc_now()
        seconds = DateTime.diff(end_dt, now, :second)
        if seconds > 0, do: seconds / 60, else: 0.0

      _ ->
        nil
    end
  end

  # Generate a BUY signal for tokens likely to resolve to 1
  defp generate_buy_signal(
         state,
         asset_id,
         current_price,
         target_price,
         order_size,
         cooldown_seconds,
         min_profit,
         direction,
         market_info,
         order
       ) do
    # Calculate size accounting for fees
    effective_size = calculate_effective_size(order_size, target_price, :buy)

    # Check minimum requirements
    shares = effective_size / target_price
    estimated_profit = estimate_profit(:buy, target_price, effective_size)

    cond do
      effective_size < @min_order_value ->
        :no_opportunity

      shares < @min_shares ->
        :no_opportunity

      estimated_profit < min_profit ->
        :no_opportunity

      true ->
        Logger.info(
          "[TimeDecay] BUY signal: #{asset_id} at #{pct(current_price)}, " <>
            "target #{pct(target_price)}, est profit $#{Float.round(estimated_profit, 2)} (#{direction})"
        )

        signal = %{
          action: :buy,
          token_id: asset_id,
          price: target_price,
          size: effective_size,
          reason:
            "Time decay BUY - #{market_info[:outcome] || "YES"} at #{pct(current_price)}, " <>
              "#{hours_label(market_info)} to resolution, limit #{pct(target_price)}",
          metadata: %{
            strategy: "time_decay",
            current_price: current_price,
            target_price: target_price,
            direction: direction,
            outcome: market_info[:outcome],
            market_question: order.market_question || market_info[:question],
            end_date: market_info[:end_date],
            estimated_profit: estimated_profit,
            shares: shares
          }
        }

        Logger.info(
          "[TimeDecay] 🎯 BUY SIGNAL: #{market_info[:outcome] || "YES"} @ #{pct(current_price)} → #{pct(target_price)}, cooldown=#{cooldown_seconds}s"
        )

        # Put BOTH this token AND the opposite token on cooldown (one trade per market)
        cooldown_until = System.system_time(:second) + cooldown_seconds
        cooldowns = Map.put(state.cooldowns, asset_id, cooldown_until)

        cooldowns =
          if opposite_token_id = market_info[:opposite_token_id] do
            Logger.info(
              "[TimeDecay] 🔒 Setting cooldown for BOTH tokens: #{String.slice(asset_id, 0, 8)}... AND #{String.slice(opposite_token_id, 0, 8)}..."
            )

            Map.put(cooldowns, opposite_token_id, cooldown_until)
          else
            Logger.warning(
              "[TimeDecay] ⚠️ No opposite token found for #{String.slice(asset_id, 0, 8)}... - only this token on cooldown"
            )

            cooldowns
          end

        placed_orders = Map.put(state.placed_orders, asset_id, signal)

        {:opportunity, signal, %{state | cooldowns: cooldowns, placed_orders: placed_orders}}
    end
  end

  # Get token info from Gamma API (cached)
  defp get_token_info(state, asset_id) do
    now = System.system_time(:second)

    case Map.get(state.market_cache, asset_id) do
      %{expires_at: exp} = cached when is_integer(exp) ->
        if exp > now do
          {cached[:outcome], cached, state}
        else
          fetch_and_cache_token_info(state, asset_id)
        end

      _ ->
        fetch_and_cache_token_info(state, asset_id)
    end
  end

  defp fetch_and_cache_token_info(state, asset_id) do
    case Gamma.get_market_by_token(asset_id) do
      {:ok, info} ->
        # Cache for 5 minutes
        cached_info = Map.put(info, :expires_at, System.system_time(:second) + 300)
        new_cache = Map.put(state.market_cache, asset_id, cached_info)
        {info[:outcome], info, %{state | market_cache: new_cache}}

      {:error, _} ->
        # No info available, assume YES token
        {nil, %{}, state}
    end
  end

  defp parse_end_date(nil), do: {:error, nil}

  defp parse_end_date(end_date) when is_binary(end_date) do
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

  defp parse_end_date(end_date) when is_integer(end_date) do
    {:ok, DateTime.from_unix!(end_date)}
  end

  defp parse_end_date(_), do: {:error, :invalid_format}

  # Calculate evaluation price (midpoint or best_bid)
  defp calculate_evaluation_price(best_bid, best_ask, true)
       when not is_nil(best_bid) and not is_nil(best_ask) do
    (best_bid + best_ask) / 2
  end

  defp calculate_evaluation_price(best_bid, best_ask, _) do
    best_bid || best_ask
  end

  # Calculate bid-ask spread
  defp calculate_spread(nil, _), do: nil
  defp calculate_spread(_, nil), do: nil
  defp calculate_spread(best_bid, best_ask), do: best_ask - best_bid

  # Calculate effective order size after fees
  defp calculate_effective_size(order_size, _price, :buy) do
    # Return full order size - fees are charged separately by Polymarket
    # Previously reduced by taker fee, but that's not needed since feeRateBps=0 in orders
    order_size
  end

  # Estimate profit from trade
  defp estimate_profit(:buy, target_price, size) do
    # If resolves to 1, profit = (1 - target_price) * shares
    # Fees are charged by Polymarket separately, not included in profit calc
    shares = size / target_price
    (1 - target_price) * shares
  end

  defp in_cooldown?(state, token_id) do
    case Map.get(state.cooldowns, token_id) do
      nil -> false
      expire_at -> System.system_time(:second) < expire_at
    end
  end

  # Format price as percentage string
  defp pct(price) when is_number(price), do: "#{Float.round(price * 100, 1)}%"
  defp pct(_), do: "?%"

  # Format time to resolution for logging (shows minutes when <1h)
  defp hours_label(%{end_date: end_date}) do
    case calculate_minutes_to_resolution(end_date) do
      nil -> "unknown time"
      mins when mins < 60 -> "#{round(mins)}m"
      mins -> "#{round(mins / 60)}h"
    end
  end

  defp hours_label(_), do: "unknown time"

  # Map market timeframe config to Gamma API intervals
  defp timeframe_to_intervals("15m"), do: [:_15m]
  defp timeframe_to_intervals("1h"), do: [:_1h]
  defp timeframe_to_intervals("4h"), do: [:_4h]
  defp timeframe_to_intervals("daily"), do: [:weekly]
  defp timeframe_to_intervals(_), do: [:_15m]
end
