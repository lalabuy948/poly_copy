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
  - max_hours_to_resolution: Only trade markets expiring within N hours (default: 24)
  - max_minutes_to_resolution: For short-term markets, minutes-based filter (default: nil)
  - min_minutes_to_resolution: Minimum minutes before resolution (default: 1)
  - min_profit: Minimum estimated profit in USD to signal (default: 0.01)
  - auto_discover_crypto: Automatically discover 15-min crypto markets (default: false)
  """
  @behaviour Polyx.Strategies.Behaviour

  require Logger

  alias Polyx.Polymarket.{Gamma, Client}

  # Polymarket fee structure
  @taker_fee 0.002
  @min_order_value 1.0
  @min_shares 5

  @impl true
  def init(config) do
    state = %{
      config: config,
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
      if config["auto_discover_crypto"] == true do
        Logger.info("[TimeDecay] Auto-discovery mode enabled")
        %{state | needs_initial_discovery: true}
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def validate_config(config) do
    cond do
      !is_number(config["target_high_price"]) or config["target_high_price"] < 0.9 or
          config["target_high_price"] > 1.0 ->
        {:error, "target_high_price must be between 0.9 and 1.0"}

      !is_number(config["target_low_price"]) or config["target_low_price"] < 0.0 or
          config["target_low_price"] > 0.1 ->
        {:error, "target_low_price must be between 0.0 and 0.1"}

      !is_number(config["high_threshold"]) or config["high_threshold"] < 0.5 or
          config["high_threshold"] > 1.0 ->
        {:error, "high_threshold must be between 0.5 and 1.0"}

      !is_number(config["low_threshold"]) or config["low_threshold"] < 0.0 or
          config["low_threshold"] > 0.5 ->
        {:error, "low_threshold must be between 0.0 and 0.5"}

      !is_number(config["order_size"]) or config["order_size"] <= 0 ->
        {:error, "order_size must be a positive number"}

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
          {:ok, new_state, signals} when is_list(signals) and signals != [] ->
            # Return early with signals from discovery (include removed_tokens)
            throw(
              {:discovery_signals, %{new_state | last_crypto_discovery: now}, signals,
               removed_tokens}
            )

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
  catch
    {:discovery_signals, new_state, signals, removed} ->
      {:ok, %{new_state | removed_tokens: removed}, signals}
  end

  # Discover 15-minute crypto markets and evaluate them for opportunities
  defp discover_crypto_markets(state) do
    config = state.config
    max_minutes = config["max_minutes_to_resolution"] || 120
    min_minutes = config["min_minutes_to_resolution"] || 1

    Logger.debug(
      "[TimeDecay] Discovering crypto markets ending in #{min_minutes}-#{max_minutes} minutes"
    )

    case Gamma.fetch_crypto_markets_ending_soon(
           max_minutes: max_minutes,
           min_minutes: min_minutes,
           limit: 100
         ) do
      {:ok, events} ->
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

        # Find newly discovered tokens
        new_tokens = MapSet.difference(all_tokens, state.discovered_tokens)

        if MapSet.size(new_tokens) > 0 do
          event_titles = events |> Enum.map(& &1[:title]) |> Enum.take(5) |> Enum.join(", ")

          Logger.info(
            "[TimeDecay] Discovered #{MapSet.size(new_tokens)} new crypto tokens from #{length(events)} events: #{event_titles}"
          )
        end

        # Update discovered tokens
        state = %{state | discovered_tokens: MapSet.union(state.discovered_tokens, new_tokens)}

        # Evaluate each new token for opportunities
        {signals, state} =
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
            # Only evaluate tokens we haven't already evaluated recently
            not MapSet.member?(state.evaluated_tokens, token_id)
          end)
          |> Enum.reduce({[], state}, fn {token_id, event, market}, {sigs, st} ->
            # Mark token as evaluated
            st = %{st | evaluated_tokens: MapSet.put(st.evaluated_tokens, token_id)}

            # Cache market info for faster lookups
            market_info = %{
              question: market[:question],
              event_title: event[:title],
              outcome: get_outcome_for_token(market, token_id),
              end_date: event[:end_date],
              expires_at: System.system_time(:second) + 300
            }

            st = %{st | market_cache: Map.put(st.market_cache, token_id, market_info)}

            case check_token_opportunity(st, token_id) do
              {:opportunity, signal, new_st} ->
                Logger.info(
                  "[TimeDecay] Found opportunity in #{token_id}: #{signal.action} @ #{signal.price}"
                )

                {[signal | sigs], new_st}

              :no_opportunity ->
                {sigs, st}
            end
          end)

        if signals == [] do
          {:ok, state}
        else
          {:ok, state, Enum.reverse(signals)}
        end
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

    Logger.debug("[TimeDecay] Scanning for near-expiry markets (limit: #{scan_limit})")

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

        Logger.debug("[TimeDecay] Found #{length(near_expiry_events)} near-expiry events")

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
    high_threshold = config["high_threshold"] || 0.90
    _low_threshold = config["low_threshold"]  # unused - we only buy at high prices
    target_high_price = config["target_high_price"] || 0.99
    _target_low_price = config["target_low_price"] || 0.01
    order_size = config["order_size"] || 10
    cooldown_seconds = config["cooldown_seconds"] || 300
    min_spread = config["min_spread"] || 0.02
    use_midpoint = config["use_midpoint"] != false
    max_hours = config["max_hours_to_resolution"] || 24
    # New: minutes-based filtering for short-term markets
    max_minutes = config["max_minutes_to_resolution"]
    min_minutes = config["min_minutes_to_resolution"] || 1
    min_profit = config["min_profit"] || 0.01
    crypto_only = config["crypto_only"] == true

    # Check cooldown first (fast path)
    if in_cooldown?(state, asset_id) do
      Logger.debug("[TimeDecay] Skipping #{asset_id} - in cooldown")
      :no_opportunity
    else
      # Calculate price to use
      current_price = calculate_evaluation_price(best_bid, best_ask, use_midpoint)
      spread = calculate_spread(best_bid, best_ask)

      # Get market info for this token (to determine YES/NO and resolution status)
      {outcome, market_info, state} = get_token_info(state, asset_id)

      # Check if crypto_only filter should skip non-crypto markets
      is_crypto = is_crypto_market?(market_info)

      # Check time to resolution (supports both minutes and hours)
      minutes_to_resolution = calculate_minutes_to_resolution(market_info[:end_date])
      hours_to_resolution = if minutes_to_resolution, do: minutes_to_resolution / 60, else: nil

      # Determine time constraints based on config
      {time_ok, _time_reason} =
        cond do
          # Minutes-based filtering (for 15-min markets)
          max_minutes != nil ->
            cond do
              is_nil(minutes_to_resolution) ->
                {false, "unknown time to resolution"}

              minutes_to_resolution > max_minutes ->
                {false, "#{Float.round(minutes_to_resolution, 1)} min > #{max_minutes} min max"}

              minutes_to_resolution < min_minutes ->
                {false, "#{Float.round(minutes_to_resolution, 1)} min < #{min_minutes} min min"}

              true ->
                {true, nil}
            end

          # Hours-based filtering (original behavior)
          true ->
            cond do
              is_nil(hours_to_resolution) ->
                {false, "unknown time to resolution"}

              hours_to_resolution > max_hours ->
                {false, "#{Float.round(hours_to_resolution, 1)}h > #{max_hours}h max"}

              hours_to_resolution < 1 ->
                {false, "#{Float.round(hours_to_resolution, 1)}h too close to resolution"}

              true ->
                {true, nil}
            end
        end

      # Log price check for debugging (only for significant prices)
      if current_price && (current_price > 0.70 || current_price < 0.30) do
        Logger.debug(
          "[TimeDecay] Price check: #{Float.round(current_price * 100, 1)}¢ | outcome=#{outcome} | time_ok=#{time_ok} | spread=#{spread && Float.round(spread, 4)} | crypto=#{is_crypto}"
        )
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

        # Spread too wide - market is illiquid, skip
        spread && spread > min_spread * 2 ->
          :no_opportunity

        # Price not high enough - wait for 90%+
        current_price <= high_threshold ->
          :no_opportunity

        # HIGH PRICE (90%+): Token likely resolving to 1.0
        # BUY to capture final move to $1.00
        current_price > high_threshold ->
          generate_buy_signal(
            state,
            asset_id,
            current_price,
            target_high_price,
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

  # Clean up resolved markets from discovered tokens
  defp cleanup_resolved_markets(state) do
    now = DateTime.utc_now()

    {still_valid, resolved} =
      state.discovered_tokens
      |> MapSet.to_list()
      |> Enum.split_with(fn token_id ->
        case Map.get(state.market_cache, token_id) do
          %{end_date: end_date} when not is_nil(end_date) ->
            case parse_end_date(end_date) do
              {:ok, end_dt} ->
                # Keep if more than 0 seconds until resolution
                DateTime.diff(end_dt, now, :second) > 0

              _ ->
                # Can't parse date - keep it
                true
            end

          _ ->
            # No cached info - keep it for now
            true
        end
      end)

    if resolved != [] do
      Logger.info("[TimeDecay] 🧹 Removing #{length(resolved)} resolved markets from watch list")
    end

    # Update state with cleaned tokens
    new_state = %{
      state
      | discovered_tokens: MapSet.new(still_valid),
        # Also clean up related caches
        prices: Map.drop(state.prices, resolved),
        cooldowns: Map.drop(state.cooldowns, resolved),
        placed_orders: Map.drop(state.placed_orders, resolved),
        evaluated_tokens: MapSet.difference(state.evaluated_tokens, MapSet.new(resolved)),
        removed_tokens: resolved
    }

    {new_state, resolved}
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
              "#{hours_label(market_info)} to resolution, target #{pct(target_price)}",
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
            Map.put(cooldowns, opposite_token_id, cooldown_until)
          else
            cooldowns
          end

        Logger.debug(
          "[TimeDecay] Set cooldown for market (both tokens) until #{cooldown_until}"
        )

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
    # For buys, reduce size by taker fee
    order_size * (1 - @taker_fee)
  end

  # Estimate profit from trade
  defp estimate_profit(:buy, target_price, size) do
    # If resolves to 1, profit = (1 - target_price) * shares - fees
    shares = size / target_price
    gross = (1 - target_price) * shares
    gross * (1 - @taker_fee)
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
end
