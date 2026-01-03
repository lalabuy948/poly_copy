defmodule Polyx.Strategies.DeltaArb do
  @moduledoc """
  Delta-Neutral Arbitrage Strategy.

  This strategy exploits pricing inefficiencies in binary prediction markets by
  acquiring equal quantities of both YES and NO shares when their combined cost
  is significantly below $1.00. Since one side always resolves to $1.00 and the
  other to $0.00, holding both sides guarantees profit equal to the spread.

  Example:
    - YES ask: $0.45, NO ask: $0.49
    - Combined cost: $0.94 (6% spread)
    - Buy 20 shares of each for $18.80 total
    - Guaranteed payout: $20.00 (20 shares * $1.00)
    - Profit: $1.20 (before fees)

  Config options:
    - market_type: "crypto", "sports", or "all"
    - market_timeframe: "15m", "1h", "4h", "daily"
    - min_spread: Minimum spread to enter (e.g., 0.04 = 4%)
    - order_size: USD per leg (total = 2x)
    - max_entries_per_event: Max times to enter same event
    - min_minutes: Minimum minutes before resolution
    - cooldown_seconds: Cooldown between trades on same market
  """
  @behaviour Polyx.Strategies.Behaviour

  require Logger

  alias Polyx.Polymarket.Gamma
  alias Polyx.Strategies.DeltaArb.{Config, Helpers}

  # Minimum order constraints
  @min_order_value 1.0
  @min_shares 5

  @impl true
  def init(config) do
    timeframe = config["market_timeframe"] || "15m"
    full_config = Config.defaults(timeframe) |> Map.merge(config)

    state = %{
      config: full_config,
      prices: %{},
      market_cache: %{},
      event_entries: %{},
      cooldowns: %{},
      placed_orders: %{},
      discovered_tokens: MapSet.new(),
      evaluated_tokens: MapSet.new(),
      removed_tokens: [],
      last_discovery: 0,
      needs_initial_discovery: true
    }

    {:ok, state}
  end

  @impl true
  def validate_config(config) do
    min_spread = config["min_spread"]
    order_size = config["order_size"]
    max_entries = config["max_entries_per_event"]

    cond do
      min_spread != nil and (min_spread < 0.01 or min_spread > 0.20) ->
        {:error, "min_spread must be between 0.01 (1%) and 0.20 (20%)"}

      order_size != nil and order_size <= 0 ->
        {:error, "order_size must be a positive number"}

      max_entries != nil and max_entries < 1 ->
        {:error, "max_entries_per_event must be at least 1"}

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

    # Clean up resolved markets
    {state, removed_tokens} = cleanup_resolved_markets(state)

    config = state.config
    auto_discover = config["auto_discover"] == true

    discovery_interval =
      config["discovery_interval_seconds"]
      |> case do
        nil -> 120
        val when val < 30 -> 30
        val -> val
      end

    state =
      if auto_discover and now - state.last_discovery >= discovery_interval do
        case discover_crypto_markets(state) do
          {:ok, new_state} ->
            %{new_state | last_discovery: now}
        end
      else
        state
      end

    {:ok, %{state | removed_tokens: removed_tokens}}
  end

  @doc """
  Discover markets based on configured market type and timeframes.
  Called by Runner as `discover_crypto_markets/1`.
  Supports multiple timeframes - queries each and combines results.
  """
  def discover_crypto_markets(state) do
    config = state.config
    max_minutes = config["max_minutes_to_resolution"] || 60
    min_minutes = config["min_minutes_to_resolution"] || 1
    market_type = config["market_type"] || "crypto"

    # Get timeframes - supports both list and comma-separated string
    market_timeframes = get_timeframes(config)

    Logger.info(
      "[DeltaArb] Starting discovery: type=#{market_type}, timeframes=#{inspect(market_timeframes)}, max_minutes=#{max_minutes}"
    )

    # Fetch markets based on type
    events_result =
      case market_type do
        "crypto" ->
          fetch_crypto_for_timeframes(market_timeframes, max_minutes, min_minutes)

        "sports" ->
          fetch_sports_markets(max_minutes, min_minutes)

        "all" ->
          # Combine crypto and sports
          with {:ok, crypto_events} <-
                 fetch_crypto_for_timeframes(market_timeframes, max_minutes, min_minutes),
               {:ok, sports_events} <- fetch_sports_markets(max_minutes, min_minutes) do
            {:ok, crypto_events ++ sports_events}
          end

        _ ->
          fetch_crypto_for_timeframes(market_timeframes, max_minutes, min_minutes)
      end

    case events_result do
      {:ok, events} ->
        Logger.info("[DeltaArb] Discovery found #{length(events)} events")
        process_discovered_events(state, events, market_type)

      {:error, reason} ->
        Logger.warning("[DeltaArb] Discovery failed: #{inspect(reason)}")
        {:ok, state}
    end
  end

  # Get timeframes from config, handling both list and string formats
  defp get_timeframes(config) do
    case config["market_timeframes"] do
      nil -> ["15m"]
      list when is_list(list) -> list
      str when is_binary(str) -> Config.parse_timeframes(str)
    end
  end

  # Fetch crypto markets for multiple timeframes
  defp fetch_crypto_for_timeframes(timeframes, max_minutes, min_minutes) do
    results =
      timeframes
      |> Enum.map(fn timeframe ->
        intervals = Helpers.timeframe_to_intervals(timeframe)

        Gamma.fetch_crypto_markets_ending_soon(
          max_minutes: max_minutes,
          min_minutes: min_minutes,
          intervals: intervals,
          limit: 50
        )
      end)

    # Combine all successful results
    events =
      results
      |> Enum.flat_map(fn
        {:ok, events} -> events
        {:error, _} -> []
      end)
      |> Enum.uniq_by(fn event -> event[:slug] || event[:id] end)

    if events == [] do
      # If all failed, return the first error
      case Enum.find(results, &match?({:error, _}, &1)) do
        {:error, _} = error -> error
        nil -> {:ok, []}
      end
    else
      {:ok, events}
    end
  end

  # Private functions

  defp fetch_sports_markets(_max_minutes, _min_minutes) do
    # Sports events don't have fixed timeframes like crypto - they resolve when the game ends
    # Subscribe to all active sports events and check for arb opportunities
    Gamma.fetch_sports_markets_ending_soon(
      max_minutes: 10_080,
      min_minutes: 0,
      limit: 100
    )
  end

  defp process_discovered_events(state, events, market_type) do
    # Extract all token IDs and build market cache
    all_tokens =
      events
      |> Enum.flat_map(fn event ->
        (event[:markets] || [])
        |> Enum.flat_map(fn market -> market[:token_ids] || [] end)
      end)
      |> MapSet.new()

    Logger.info("[DeltaArb] Discovery found #{MapSet.size(all_tokens)} tokens")

    # Find newly discovered tokens
    new_tokens = MapSet.difference(all_tokens, state.discovered_tokens)

    # Update discovered tokens
    state = %{state | discovered_tokens: MapSet.union(state.discovered_tokens, new_tokens)}

    # Build tokens to cache with event and market info
    tokens_to_cache =
      events
      |> Enum.flat_map(fn event ->
        (event[:markets] || [])
        |> Enum.filter(fn market ->
          # Only cache binary markets (exactly 2 outcomes)
          token_ids = market[:token_ids] || []
          length(token_ids) == 2
        end)
        |> Enum.flat_map(fn market ->
          token_ids = market[:token_ids] || []

          Enum.map(token_ids, fn token_id ->
            {token_id, event, market}
          end)
        end)
      end)
      |> Enum.filter(fn {token_id, _event, _market} ->
        # Only cache if not already evaluated or missing opposite token info
        not MapSet.member?(state.evaluated_tokens, token_id) or
          is_nil(get_in(state.market_cache, [token_id, :opposite_token_id]))
      end)

    # Cache market info for each token
    state =
      Enum.reduce(tokens_to_cache, state, fn {token_id, event, market}, st ->
        token_ids = market[:token_ids] || []
        opposite_token_id = Enum.find(token_ids, fn id -> id != token_id end)
        event_id = event[:slug] || event[:id]

        market_info = %{
          question: market[:question],
          event_title: event[:title],
          event_id: event_id,
          outcome: Helpers.get_outcome_for_token(market, token_id),
          opposite_token_id: opposite_token_id,
          end_date: event[:end_date],
          market_type: market_type,
          expires_at: System.system_time(:second) + 300
        }

        %{
          st
          | evaluated_tokens: MapSet.put(st.evaluated_tokens, token_id),
            market_cache: Map.put(st.market_cache, token_id, market_info)
        }
      end)

    {:ok, state}
  end

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
    best_bid = Helpers.parse_price(order.best_bid)
    best_ask = Helpers.parse_price(order.best_ask)

    # Update prices
    prices =
      Map.put(state.prices, asset_id, %{
        best_bid: best_bid,
        best_ask: best_ask,
        updated_at: System.system_time(:millisecond)
      })

    state = %{state | prices: prices}

    # Check for arbitrage opportunity
    case check_arb_opportunity(state, asset_id) do
      {:opportunity, signals, updated_state} ->
        Logger.info("[DeltaArb] 🚀 OPPORTUNITY FOUND! Returning #{length(signals)} signals")
        {:ok, updated_state, signals}

      :no_opportunity ->
        {:ok, state}
    end
  end

  defp handle_trade(_order, state) do
    {:ok, state}
  end

  defp check_arb_opportunity(state, asset_id) do
    config = state.config

    # Get market info for this token
    market_info = Map.get(state.market_cache, asset_id)

    if is_nil(market_info) do
      # Log occasionally for debugging (not every tick)
      if rem(System.system_time(:second), 30) == 0 do
        Logger.debug(
          "[DeltaArb] No market_info in cache for token #{String.slice(asset_id, 0, 12)}..."
        )
      end

      :no_opportunity
    else
      opposite_token_id = market_info[:opposite_token_id]
      event_id = market_info[:event_id]

      # Check if we have both tokens' prices
      this_price = Map.get(state.prices, asset_id)
      opposite_price = Map.get(state.prices, opposite_token_id)

      cond do
        # Need prices for both tokens
        is_nil(this_price) or is_nil(opposite_price) ->
          # Log why we're missing prices (occasionally)
          if rem(System.system_time(:second), 30) == 0 do
            Logger.debug(
              "[DeltaArb] Missing price for pair: this=#{!is_nil(this_price)}, opposite=#{!is_nil(opposite_price)} | question=#{String.slice(market_info[:question] || "", 0, 40)}"
            )
          end

          :no_opportunity

        # Check cooldown for either token (prevents rapid re-entry)
        in_cooldown?(state, asset_id) or in_cooldown?(state, opposite_token_id) ->
          Logger.debug("[DeltaArb] Token in cooldown: #{String.slice(asset_id, 0, 12)}...")
          :no_opportunity

        # Check max entries per event (limits total entries per market)
        Map.get(state.event_entries, event_id, 0) >= config["max_entries_per_event"] ->
          Logger.debug("[DeltaArb] Max entries reached for event: #{event_id}")
          :no_opportunity

        true ->
          evaluate_arb(
            state,
            asset_id,
            opposite_token_id,
            this_price,
            opposite_price,
            market_info
          )
      end
    end
  end

  defp evaluate_arb(state, token_a, token_b, price_a, price_b, market_info) do
    config = state.config

    ask_a = price_a.best_ask
    ask_b = price_b.best_ask

    # Skip if missing ask prices
    if is_nil(ask_a) or is_nil(ask_b) do
      :no_opportunity
    else
      combined_cost = Helpers.calculate_combined_cost(ask_a, ask_b)
      spread = Helpers.calculate_spread(combined_cost)
      min_spread = config["min_spread"] || 0.04
      order_size = config["order_size"] || 10.0
      cooldown_seconds = config["cooldown_seconds"] || 60

      valid? = Helpers.is_valid_arb_opportunity?(combined_cost, min_spread)

      # Log significant spreads (> 2%) with full details
      if spread >= 0.02 do
        Logger.info(
          "[DeltaArb] 📊 Spread: #{market_info[:question]} | spread=#{Float.round(spread * 100, 2)}% | combined=$#{Float.round(combined_cost, 3)} | min=#{min_spread * 100}% | valid?=#{valid?} | asks=#{ask_a}/#{ask_b}"
        )
      end

      if valid? do
        Logger.info("[DeltaArb] ✅ Valid arb opportunity! Generating signals...")

        generate_pair_signals(
          state,
          token_a,
          token_b,
          ask_a,
          ask_b,
          combined_cost,
          spread,
          order_size,
          cooldown_seconds,
          market_info
        )
      else
        :no_opportunity
      end
    end
  end

  defp generate_pair_signals(
         state,
         token_a,
         token_b,
         ask_a,
         ask_b,
         combined_cost,
         spread,
         order_size,
         cooldown_seconds,
         market_info
       ) do
    # Calculate profit details
    profit_info = Helpers.calculate_guaranteed_profit(combined_cost, order_size)

    cond do
      is_nil(profit_info) ->
        Logger.warning("[DeltaArb] Profit calculation returned nil for combined=#{combined_cost}")
        :no_opportunity

      profit_info.net_profit < 0.01 ->
        Logger.info(
          "[DeltaArb] Net profit too low: $#{Float.round(profit_info.net_profit, 4)} < $0.01"
        )

        :no_opportunity

      profit_info.shares / 2 < @min_shares ->
        Logger.info(
          "[DeltaArb] Shares too low: #{Float.round(profit_info.shares / 2, 2)} < #{@min_shares}"
        )

        :no_opportunity

      order_size < @min_order_value ->
        Logger.info("[DeltaArb] Order size too low: $#{order_size} < $#{@min_order_value}")
        :no_opportunity

      true ->
        # All checks passed, generate signals
        shares = profit_info.shares / 2
        event_id = market_info[:event_id]
        outcome_a = market_info[:outcome]

        # Determine which is YES and which is NO
        {yes_token, no_token, yes_price, no_price, yes_outcome, no_outcome} =
          if outcome_a in ["Yes", "YES", "yes", "Up", "UP", "up"] do
            {token_a, token_b, ask_a, ask_b, outcome_a, "No"}
          else
            {token_b, token_a, ask_b, ask_a, "Yes", outcome_a}
          end

        Logger.info("[DeltaArb] ARB OPPORTUNITY: #{market_info[:question] || "unknown"}")

        Logger.info(
          "[DeltaArb]   Combined cost: #{Helpers.pct(combined_cost)}, Spread: #{Helpers.spread_pct(spread)}"
        )

        Logger.info(
          "[DeltaArb]   Expected profit: $#{Float.round(profit_info.net_profit, 2)} (#{Float.round(profit_info.roi_pct, 2)}% ROI)"
        )

        # Generate two signals - one for each leg
        signal_yes = %{
          action: :buy,
          token_id: yes_token,
          price: yes_price,
          size: order_size,
          reason:
            "Delta Arb BUY #{yes_outcome} at #{Helpers.pct(yes_price)}, spread #{Helpers.spread_pct(spread)}",
          metadata: %{
            strategy: "delta_arb",
            leg: :yes,
            pair_token: no_token,
            combined_cost: combined_cost,
            spread: spread,
            expected_profit: profit_info.net_profit,
            event_id: event_id,
            market_question: market_info[:question],
            end_date: market_info[:end_date],
            shares: shares
          }
        }

        signal_no = %{
          action: :buy,
          token_id: no_token,
          price: no_price,
          size: order_size,
          reason:
            "Delta Arb BUY #{no_outcome} at #{Helpers.pct(no_price)}, spread #{Helpers.spread_pct(spread)}",
          metadata: %{
            strategy: "delta_arb",
            leg: :no,
            pair_token: yes_token,
            combined_cost: combined_cost,
            spread: spread,
            expected_profit: profit_info.net_profit,
            event_id: event_id,
            market_question: market_info[:question],
            end_date: market_info[:end_date],
            shares: shares
          }
        }

        # Set cooldown on both tokens
        cooldown_until = System.system_time(:second) + cooldown_seconds

        cooldowns =
          state.cooldowns
          |> Map.put(yes_token, cooldown_until)
          |> Map.put(no_token, cooldown_until)

        # Track placed orders
        placed_orders =
          state.placed_orders
          |> Map.put(yes_token, signal_yes)
          |> Map.put(no_token, signal_no)

        # Increment event entries
        current_entries = Map.get(state.event_entries, event_id, 0)
        event_entries = Map.put(state.event_entries, event_id, current_entries + 1)

        updated_state = %{
          state
          | cooldowns: cooldowns,
            placed_orders: placed_orders,
            event_entries: event_entries
        }

        {:opportunity, [signal_yes, signal_no], updated_state}
    end
  end

  defp cleanup_resolved_markets(state) do
    config = state.config
    max_minutes = config["max_minutes_to_resolution"] || 15
    min_minutes = config["min_minutes_to_resolution"] || 1
    market_type = config["market_type"] || "crypto"
    market_timeframes = get_timeframes(config)

    # Fetch current active markets
    events_result =
      case market_type do
        "sports" ->
          fetch_sports_markets(max_minutes, min_minutes)

        _ ->
          fetch_crypto_for_timeframes(market_timeframes, max_minutes, min_minutes)
      end

    case events_result do
      {:ok, events} ->
        active_tokens =
          events
          |> Enum.flat_map(fn event ->
            (event[:markets] || [])
            |> Enum.flat_map(fn market -> market[:token_ids] || [] end)
          end)
          |> MapSet.new()

        resolved = MapSet.difference(state.discovered_tokens, active_tokens) |> MapSet.to_list()

        # Get event IDs that resolved
        resolved_event_ids =
          resolved
          |> Enum.map(fn token_id -> get_in(state.market_cache, [token_id, :event_id]) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        new_state = %{
          state
          | discovered_tokens: MapSet.intersection(state.discovered_tokens, active_tokens),
            prices: Map.drop(state.prices, resolved),
            cooldowns: Map.drop(state.cooldowns, resolved),
            placed_orders: Map.drop(state.placed_orders, resolved),
            evaluated_tokens: MapSet.difference(state.evaluated_tokens, MapSet.new(resolved)),
            event_entries: Map.drop(state.event_entries, resolved_event_ids),
            removed_tokens: resolved
        }

        {new_state, resolved}

      {:error, _} ->
        {state, []}
    end
  end

  defp in_cooldown?(state, token_id) do
    case Map.get(state.cooldowns, token_id) do
      nil -> false
      expire_at -> System.system_time(:second) < expire_at
    end
  end

  @doc """
  Get the current token info from cache, refreshing if expired.
  """
  def get_token_info(state, asset_id) do
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
        cached_info = Map.put(info, :expires_at, System.system_time(:second) + 300)
        new_cache = Map.put(state.market_cache, asset_id, cached_info)
        {info[:outcome], info, %{state | market_cache: new_cache}}

      {:error, _} ->
        {nil, %{}, state}
    end
  end
end
