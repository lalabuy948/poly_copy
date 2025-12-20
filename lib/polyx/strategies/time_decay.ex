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
  alias Polyx.Strategies.TimeDecay.Helpers

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
      prices: %{},
      cooldowns: %{},
      placed_orders: %{},
      market_cache: %{},
      scan_offset: 0,
      last_scan: 0,
      last_crypto_discovery: 0,
      discovered_tokens: MapSet.new(),
      evaluated_tokens: MapSet.new(),
      removed_tokens: [],
      needs_initial_discovery: false
    }

    # If auto_discover_crypto is enabled, mark for initial discovery
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

    # Auto-discovery
    auto_discover = config["auto_discover_crypto"] == true
    discovery_interval = config["discovery_interval_seconds"] || 120

    state =
      if auto_discover and now - state.last_crypto_discovery >= discovery_interval do
        case discover_crypto_markets(state) do
          {:ok, new_state} ->
            %{new_state | last_crypto_discovery: now}
        end
      else
        state
      end

    # Proactive scanning if enabled
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

    # Attach removed tokens
    case result do
      {:ok, final_state, signals} ->
        {:ok, %{final_state | removed_tokens: removed_tokens}, signals}

      {:ok, final_state} ->
        {:ok, %{final_state | removed_tokens: removed_tokens}}
    end
  end

  # Public functions

  @doc """
  Discover crypto markets within the configured time window.
  """
  def discover_crypto_markets(state) do
    config = state.config
    max_minutes = config["max_minutes_to_resolution"] || 60
    min_minutes = config["min_minutes_to_resolution"] || 1
    market_timeframe = config["market_timeframe"] || "15m"

    Logger.info(
      "[TimeDecay] Starting crypto discovery: max_minutes=#{max_minutes}, min_minutes=#{min_minutes}"
    )

    intervals = Helpers.timeframe_to_intervals(market_timeframe)

    case Gamma.fetch_crypto_markets_ending_soon(
           max_minutes: max_minutes,
           min_minutes: min_minutes,
           intervals: intervals,
           limit: 100
         ) do
      {:ok, events} ->
        Logger.info("[TimeDecay] Discovery found #{length(events)} events")

        # Extract all token IDs
        all_tokens =
          events
          |> Enum.flat_map(fn event ->
            (event[:markets] || [])
            |> Enum.flat_map(fn market -> market[:token_ids] || [] end)
          end)
          |> MapSet.new()

        Logger.info("[TimeDecay] Discovery found #{MapSet.size(all_tokens)} tokens")

        # Find newly discovered tokens
        new_tokens = MapSet.difference(all_tokens, state.discovered_tokens)

        # Update discovered tokens
        state = %{state | discovered_tokens: MapSet.union(state.discovered_tokens, new_tokens)}

        # Build list of tokens to cache
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
            not MapSet.member?(state.evaluated_tokens, token_id) or
              is_nil(get_in(state.market_cache, [token_id, :opposite_token_id]))
          end)

        # Cache market info
        state =
          Enum.reduce(tokens_to_cache, state, fn {token_id, event, market}, st ->
            token_ids = market[:token_ids] || []
            opposite_token_id = Enum.find(token_ids, fn id -> id != token_id end)

            market_info = %{
              question: market[:question],
              event_title: event[:title],
              outcome: Helpers.get_outcome_for_token(market, token_id),
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

        {:ok, state}
    end
  end

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

    # Check for opportunity
    case check_time_decay_opportunity(state, asset_id, best_bid, best_ask, order) do
      {:opportunity, signal, updated_state} ->
        {:ok, updated_state, [signal]}

      :no_opportunity ->
        {:ok, state}
    end
  end

  defp handle_trade(_order, state) do
    {:ok, state}
  end

  defp check_time_decay_opportunity(state, asset_id, best_bid, best_ask, order) do
    config = state.config

    # User-configurable settings
    signal_threshold = config["signal_threshold"] || config["high_threshold"] || 0.80
    order_size = config["order_size"] || 5.0
    min_minutes = config["min_minutes"] || config["min_minutes_to_resolution"] || 1.0
    use_limit_order = config["use_limit_order"] != false
    limit_price = config["limit_price"] || config["target_high_price"] || 0.99

    # Hardcoded settings
    cooldown_seconds = config["cooldown_seconds"] || 60
    min_profit = config["min_profit"] || 0.01
    crypto_only = config["crypto_only"] != false

    # Check cooldown or already placed
    already_placed = Map.has_key?(state.placed_orders, asset_id)

    if already_placed or in_cooldown?(state, asset_id) do
      :no_opportunity
    else
      # Calculate price
      current_price = Helpers.calculate_evaluation_price(best_bid, best_ask, true)
      _spread = Helpers.calculate_spread(best_bid, best_ask)

      # Get market info
      {_outcome, market_info, state} = get_token_info(state, asset_id)

      # Check filters
      is_crypto = Helpers.is_crypto_market?(market_info)
      minutes_to_resolution = Helpers.calculate_minutes_to_resolution(market_info[:end_date])

      # Time constraints
      time_ok =
        cond do
          is_nil(minutes_to_resolution) -> false
          minutes_to_resolution <= 0 -> false
          minutes_to_resolution > min_minutes -> false
          true -> true
        end

      cond do
        is_nil(current_price) ->
          :no_opportunity

        crypto_only and not is_crypto ->
          :no_opportunity

        not time_ok ->
          :no_opportunity

        current_price <= signal_threshold ->
          :no_opportunity

        current_price > signal_threshold ->
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
    # Calculate size
    effective_size = Helpers.calculate_effective_size(order_size, target_price, :buy)
    shares = effective_size / target_price
    estimated_profit = Helpers.estimate_profit(:buy, target_price, effective_size)

    cond do
      effective_size < @min_order_value ->
        :no_opportunity

      shares < @min_shares ->
        :no_opportunity

      estimated_profit < min_profit ->
        :no_opportunity

      true ->
        Logger.info(
          "[TimeDecay] BUY signal: #{asset_id} at #{Helpers.pct(current_price)}, " <>
            "target #{Helpers.pct(target_price)}, est profit $#{Float.round(estimated_profit, 2)} (#{direction})"
        )

        signal = %{
          action: :buy,
          token_id: asset_id,
          price: target_price,
          size: effective_size,
          reason:
            "Time decay BUY - #{market_info[:outcome] || "YES"} at #{Helpers.pct(current_price)}, " <>
              "#{Helpers.hours_label(market_info)} to resolution, limit #{Helpers.pct(target_price)}",
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
          "[TimeDecay] 🎯 BUY SIGNAL: #{market_info[:outcome] || "YES"} @ #{Helpers.pct(current_price)} → #{Helpers.pct(target_price)}, cooldown=#{cooldown_seconds}s"
        )

        # Put BOTH tokens on cooldown
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
        cached_info = Map.put(info, :expires_at, System.system_time(:second) + 300)
        new_cache = Map.put(state.market_cache, asset_id, cached_info)
        {info[:outcome], info, %{state | market_cache: new_cache}}

      {:error, _} ->
        {nil, %{}, state}
    end
  end

  defp cleanup_resolved_markets(state) do
    config = state.config
    max_minutes = config["max_minutes_to_resolution"] || 15
    min_minutes = config["min_minutes_to_resolution"] || 1
    market_timeframe = config["market_timeframe"] || "15m"
    intervals = Helpers.timeframe_to_intervals(market_timeframe)

    case Gamma.fetch_crypto_markets_ending_soon(
           max_minutes: max_minutes,
           min_minutes: min_minutes,
           intervals: intervals,
           limit: 100
         ) do
      {:ok, events} ->
        active_tokens =
          events
          |> Enum.flat_map(fn event ->
            (event[:markets] || [])
            |> Enum.flat_map(fn market -> market[:token_ids] || [] end)
          end)
          |> MapSet.new()

        resolved = MapSet.difference(state.discovered_tokens, active_tokens) |> MapSet.to_list()

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

  defp scan_near_expiry_markets(state) do
    config = state.config
    scan_limit = config["scan_limit"] || 20
    max_hours = config["max_hours_to_resolution"] || 24

    case Gamma.fetch_events(limit: scan_limit, offset: state.scan_offset) do
      {:ok, events} ->
        now = DateTime.utc_now()

        near_expiry_events =
          events
          |> Enum.filter(fn event ->
            case Helpers.parse_end_date(event[:end_date]) do
              {:ok, end_dt} ->
                hours_remaining = DateTime.diff(end_dt, now, :hour)
                hours_remaining > 0 and hours_remaining <= max_hours

              _ ->
                false
            end
          end)

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

  defp check_token_opportunity(state, token_id) do
    case Client.get_orderbook(token_id) do
      {:ok, %{"bids" => bids, "asks" => asks}} ->
        best_bid = get_best_price(bids)
        best_ask = get_best_price(asks)

        if best_bid || best_ask do
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

  defp in_cooldown?(state, token_id) do
    case Map.get(state.cooldowns, token_id) do
      nil -> false
      expire_at -> System.system_time(:second) < expire_at
    end
  end
end
