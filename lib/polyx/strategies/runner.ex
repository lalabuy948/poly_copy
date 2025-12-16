defmodule Polyx.Strategies.Runner do
  @moduledoc """
  GenServer that runs a single trading strategy instance.

  Subscribes to live order feed, processes orders through strategy,
  and executes signals via the trade executor.
  """
  use GenServer

  require Logger

  alias Polyx.Strategies
  alias Polyx.Strategies.Behaviour
  alias Polyx.Polymarket.LiveOrders

  @tick_interval 5_000
  # Reduced for more responsive price updates in UI
  @broadcast_throttle_ms 100
  @ets_table :strategy_discovered_tokens
  # Refresh prices from Gamma API every 10 seconds as fallback
  # WebSocket provides real-time updates (primary source)
  @price_refresh_interval 10_000
  # Threshold for prioritizing WebSocket subscriptions (15 minutes)
  @priority_resolution_minutes 15

  defstruct [
    :strategy_id,
    :strategy,
    :module,
    :state,
    :tick_ref,
    :price_refresh_ref,
    :target_tokens,
    :last_broadcast,
    # Tokens with active WebSocket subscriptions (get real-time updates)
    websocket_subscribed: MapSet.new(),
    # Token resolution times for prioritization
    token_resolution_times: %{},
    paused: false
  ]

  # Public API

  def start_link(strategy_id) do
    GenServer.start_link(__MODULE__, strategy_id, name: via_tuple(strategy_id))
  end

  def stop(strategy_id) do
    GenServer.stop(via_tuple(strategy_id))
  end

  def get_state(strategy_id) do
    GenServer.call(via_tuple(strategy_id), :get_state)
  end

  @doc """
  Set paper_mode for a running strategy.
  """
  def set_paper_mode(strategy_id, paper_mode) when is_boolean(paper_mode) do
    GenServer.call(via_tuple(strategy_id), {:set_paper_mode, paper_mode})
  end

  @doc """
  Get discovered tokens from a running strategy.
  Returns {:ok, list} - reads from ETS for non-blocking access.
  """
  def get_discovered_tokens(strategy_id) do
    ensure_ets_table()

    case :ets.lookup(@ets_table, strategy_id) do
      [{^strategy_id, tokens}] -> {:ok, tokens}
      [] -> {:ok, []}
    end
  end

  # Ensure ETS table exists (creates if not)
  defp ensure_ets_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        # Handle race condition - another process may have created it between check and create
        try do
          :ets.new(@ets_table, [:named_table, :public, :set])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  # Store discovered tokens in ETS for fast non-blocking reads
  defp store_discovered_tokens(strategy_id, tokens) when is_list(tokens) do
    ensure_ets_table()
    :ets.insert(@ets_table, {strategy_id, tokens})
  end

  def pause(strategy_id) do
    GenServer.call(via_tuple(strategy_id), :pause)
  end

  def resume(strategy_id) do
    GenServer.call(via_tuple(strategy_id), :resume)
  end

  defp via_tuple(strategy_id) do
    {:via, Registry, {Polyx.Strategies.Registry, strategy_id}}
  end

  # GenServer callbacks

  @impl true
  def init(strategy_id) do
    strategy = Strategies.get_strategy!(strategy_id)

    case Behaviour.module_for_type(strategy.type) do
      {:ok, module} ->
        # Convert raw config to full strategy config with timeframe defaults
        full_config = convert_config(strategy.config)
        Logger.info("[Runner] Module: #{module}, timeframe: #{full_config["market_timeframe"]}, max_minutes: #{full_config["max_minutes_to_resolution"]}")

        case module.init(full_config) do
          {:ok, strategy_state} ->
            # Subscribe to live orders
            LiveOrders.subscribe()

            # Update strategy status
            Strategies.update_strategy_status(strategy, "running")
            mode = if strategy.paper_mode, do: "paper", else: "live"

            # Extract target tokens from config (list of token IDs to watch)
            target_tokens = extract_target_tokens(strategy.config)

            target_count =
              if target_tokens == :all, do: "all markets", else: "#{length(target_tokens)} tokens"

            Strategies.log_event(
              strategy,
              "info",
              "Strategy started (#{mode} mode, watching #{target_count})"
            )

            # Schedule periodic tick
            tick_ref = Process.send_after(self(), :tick, @tick_interval)
            # Schedule periodic price refresh from API
            price_refresh_ref =
              Process.send_after(self(), :refresh_prices, @price_refresh_interval)

            state = %__MODULE__{
              strategy_id: strategy_id,
              strategy: strategy,
              module: module,
              state: strategy_state,
              tick_ref: tick_ref,
              price_refresh_ref: price_refresh_ref,
              target_tokens: target_tokens,
              last_broadcast: 0
            }

            # Schedule initial discovery async if needed (don't block init)
            needs_discovery = Map.get(strategy_state, :needs_initial_discovery, false)
            if needs_discovery do
              send(self(), :initial_discovery)
            end

            Logger.info(
              "[Runner] Started strategy #{strategy.name} (#{strategy.type}, #{mode}, #{target_count})"
            )

            {:ok, state}
        end

      {:error, reason} ->
        Logger.error("[Runner] Unknown strategy type: #{strategy.type}")
        {:stop, {:unknown_type, reason}}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.state, state}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    Strategies.update_strategy_status(state.strategy, "paused")
    Strategies.log_event(state.strategy, "info", "Strategy paused")
    {:reply, :ok, %{state | paused: true}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    Strategies.update_strategy_status(state.strategy, "running")
    Strategies.log_event(state.strategy, "info", "Strategy resumed")
    {:reply, :ok, %{state | paused: false}}
  end

  @impl true
  def handle_call({:set_paper_mode, paper_mode}, _from, state) do
    updated_strategy = %{state.strategy | paper_mode: paper_mode}
    mode_label = if paper_mode, do: "Paper", else: "Live"
    Strategies.log_event(state.strategy, "info", "Switched to #{mode_label} mode")
    {:reply, :ok, %{state | strategy: updated_strategy}}
  end

  @impl true
  def handle_info({:new_order, order}, state) do
    # Only process if strategy is not paused (use cached state, not DB)
    if not state.paused do
      # Check if this order matches our target tokens (filter)
      asset_id = order[:asset_id] || order["asset_id"]

      # Check if auto-discovery mode is enabled and token is in discovered list
      # Use strategy state config (merged with hardcoded defaults) instead of DB config
      strategy_config = Map.get(state.state, :config, %{})
      auto_discover = strategy_config["auto_discover_crypto"] == true
      discovered_tokens = extract_discovered_tokens(state.state)
      is_discovered = auto_discover and MapSet.member?(discovered_tokens, asset_id)

      cond do
        # Configured tokens - process through strategy
        should_process_order?(state.target_tokens, asset_id) ->
          process_order(order, state)

        # Auto-discovered crypto tokens - process through strategy
        is_discovered ->
          process_order(order, state)

        # No tokens configured but watch_all is set - broadcast all orders
        state.target_tokens == :all ->
          process_order(order, state)

        # No tokens configured and auto-discover disabled - broadcast for visibility
        state.target_tokens == [] and not auto_discover ->
          now = System.system_time(:millisecond)
          # Heavier throttle (500ms) for unfiltered orders
          if now - state.last_broadcast >= 500 do
            broadcast_live_order(state.strategy_id, order, nil)
            {:noreply, %{state | last_broadcast: now}}
          else
            {:noreply, state}
          end

        true ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:connected, connected}, state) do
    status = if connected, do: "connected", else: "disconnected"
    Logger.info("[Runner] Live orders WebSocket #{status}")
    {:noreply, state}
  end

  @impl true
  def handle_info(:initial_discovery, state) do

    # Call discover function if the module supports it
    new_state =
      if function_exported?(state.module, :discover_crypto_markets, 1) do
        case state.module.discover_crypto_markets(state.state) do
          {:ok, new_strategy_state, _signals} ->
            updated_runner_state =
              subscribe_to_discovered(state.strategy_id, new_strategy_state, state)

            %{
              updated_runner_state
              | state: %{new_strategy_state | needs_initial_discovery: false}
            }

          {:ok, new_strategy_state} ->
            updated_runner_state =
              subscribe_to_discovered(state.strategy_id, new_strategy_state, state)

            %{
              updated_runner_state
              | state: %{new_strategy_state | needs_initial_discovery: false}
            }

          _ ->
            state
        end
      else
        state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:tick, state) do
    old_discovered = extract_discovered_tokens(state.state)

    new_state =
      if not state.paused do
        case state.module.handle_tick(state.state) do
          {:ok, new_strategy_state} ->
            %{state | state: new_strategy_state}

          {:ok, new_strategy_state, signals} when is_list(signals) ->
            execute_signals(state.strategy, signals)
            %{state | state: new_strategy_state}
        end
      else
        state
      end

    # Handle removed tokens (resolved markets)
    removed_tokens = Map.get(new_state.state, :removed_tokens, [])

    new_state =
      if removed_tokens != [] do
        # Update ETS with cleaned token list
        current_discovered = extract_discovered_tokens(new_state.state)
        store_discovered_tokens(state.strategy_id, MapSet.to_list(current_discovered))
        # Broadcast removal to UI
        broadcast_removed_tokens(state.strategy_id, removed_tokens)
        # Unsubscribe from LiveOrders ETS to prevent memory leak
        LiveOrders.unsubscribe_from_markets(removed_tokens)
        # Clear removed_tokens from state to avoid re-broadcasting
        cleaned_strategy_state = Map.put(new_state.state, :removed_tokens, [])
        # Also remove from WebSocket subscribed set and resolution times
        removed_set = MapSet.new(removed_tokens)

        %{
          new_state
          | state: cleaned_strategy_state,
            websocket_subscribed: MapSet.difference(new_state.websocket_subscribed, removed_set),
            token_resolution_times: Map.drop(new_state.token_resolution_times, removed_tokens)
        }
      else
        new_state
      end

    # Broadcast newly discovered tokens to UI and subscribe to WebSocket
    new_discovered = extract_discovered_tokens(new_state.state)

    new_state =
      if MapSet.size(new_discovered) > MapSet.size(old_discovered) do
        new_tokens = MapSet.difference(new_discovered, old_discovered)

        if MapSet.size(new_tokens) > 0 do
          new_token_list = MapSet.to_list(new_tokens)
          # Update ETS with ALL discovered tokens for fast reads
          all_tokens = MapSet.to_list(new_discovered)
          store_discovered_tokens(state.strategy_id, all_tokens)
          broadcast_discovered_tokens(state.strategy_id, new_token_list)

          # Get resolution times for tracking
          {_priority_tokens, resolution_times} =
            get_priority_tokens_for_subscription(new_state.state)

          # Subscribe ALL new tokens to WebSocket
          LiveOrders.subscribe_to_markets(new_token_list)

          %{
            new_state
            | websocket_subscribed: MapSet.union(new_state.websocket_subscribed, new_tokens),
              token_resolution_times:
                Map.merge(new_state.token_resolution_times, resolution_times)
          }
        else
          new_state
        end
      else
        new_state
      end

    # Schedule next tick
    tick_ref = Process.send_after(self(), :tick, @tick_interval)
    {:noreply, %{new_state | tick_ref: tick_ref}}
  end

  @impl true
  def handle_info(:refresh_prices, state) do
    # WebSocket is the only source of prices - no API polling
    price_refresh_ref = Process.send_after(self(), :refresh_prices, @price_refresh_interval)
    {:noreply, %{state | price_refresh_ref: price_refresh_ref}}
  end

  @impl true
  def handle_info({:new_orders_batch, _orders}, state) do
    # Ignore batch messages - we process individual {:new_order, order} messages instead
    # LiveOrders broadcasts both batch AND individual messages for compatibility
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    # Ignore unknown messages
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    if state.tick_ref, do: Process.cancel_timer(state.tick_ref)
    if state.price_refresh_ref, do: Process.cancel_timer(state.price_refresh_ref)

    case reason do
      :normal ->
        Strategies.update_strategy_status(state.strategy, "stopped")
        Strategies.log_event(state.strategy, "info", "Strategy stopped")

      _ ->
        Strategies.update_strategy_status(state.strategy, "error")
        Strategies.log_event(state.strategy, "error", "Strategy crashed: #{inspect(reason)}")
    end

    :ok
  end

  # Private functions

  # Subscribe ALL discovered tokens to WebSocket - single source of truth for prices
  defp subscribe_to_discovered(strategy_id, strategy_state, runner_state) do
    discovered = extract_discovered_tokens(strategy_state)

    if MapSet.size(discovered) > 0 do
      token_list = MapSet.to_list(discovered)
      store_discovered_tokens(strategy_id, token_list)
      broadcast_discovered_tokens(strategy_id, token_list)

      # Get resolution times for tracking
      {_priority_tokens, resolution_times} = get_priority_tokens_for_subscription(strategy_state)

      LiveOrders.subscribe_to_markets(token_list)

      # Schedule immediate price refresh to seed initial prices
      # (WebSocket may not have activity on quiet markets)
      Process.send_after(self(), :refresh_prices, 500)

      %{
        runner_state
        | websocket_subscribed: MapSet.new(token_list),
          token_resolution_times: resolution_times
      }
    else
      runner_state
    end
  end

  # Subscribe to priority tokens (those resolving within @priority_resolution_minutes)
  # Returns {tokens_to_subscribe, resolution_times_map}
  defp get_priority_tokens_for_subscription(strategy_state) do
    market_cache = Map.get(strategy_state, :market_cache, %{})
    discovered = extract_discovered_tokens(strategy_state)
    now = DateTime.utc_now()

    discovered
    |> MapSet.to_list()
    |> Enum.reduce({[], %{}}, fn token_id, {priority_tokens, times} ->
      case Map.get(market_cache, token_id) do
        %{end_date: end_date} when not is_nil(end_date) ->
          case parse_end_date_for_runner(end_date) do
            {:ok, end_dt} ->
              minutes = DateTime.diff(end_dt, now, :second) / 60

              if minutes > 0 and minutes <= @priority_resolution_minutes do
                # Priority token - subscribe via WebSocket
                {[token_id | priority_tokens], Map.put(times, token_id, minutes)}
              else
                # Non-priority - just track resolution time
                {priority_tokens, Map.put(times, token_id, minutes)}
              end

            _ ->
              {priority_tokens, times}
          end

        _ ->
          {priority_tokens, times}
      end
    end)
  end

  defp parse_end_date_for_runner(end_date) when is_binary(end_date) do
    case DateTime.from_iso8601(end_date) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, _} ->
        case Integer.parse(end_date) do
          {ts, _} -> {:ok, DateTime.from_unix!(ts)}
          :error -> {:error, :invalid_format}
        end
    end
  end

  defp parse_end_date_for_runner(end_date) when is_integer(end_date) do
    {:ok, DateTime.from_unix!(end_date)}
  end

  defp parse_end_date_for_runner(_), do: {:error, :invalid_format}

  defp execute_signals(strategy, signals) do
    # Use cached strategy from state - paper_mode is updated via toggle_paper_mode event
    # which triggers a restart, so we don't need to reload from DB

    Enum.each(signals, fn signal ->
      mode_label = if strategy.paper_mode, do: "[PAPER]", else: "[LIVE]"

      # Check if sell signal requires a position we don't have
      requires_position = get_in(signal, [:metadata, :requires_position]) == true

      if signal.action == :sell and requires_position and not strategy.paper_mode do
        # Live sell orders require holding the position - check if we have one
        position = Strategies.get_position(strategy.id, signal.token_id)

        position_size =
          if position, do: Decimal.to_float(position.size || Decimal.new(0)), else: 0

        if position_size < signal.size do
          Logger.warning(
            "[Runner] [LIVE] Skipping SELL signal - requires position of #{signal.size} but only have #{position_size}"
          )

          Strategies.log_event(strategy, "warning", "Skipped SELL - insufficient position", %{
            token_id: signal.token_id,
            required_size: signal.size,
            current_position: position_size
          })

          # Skip this signal - don't execute
          :skip
        else
          do_execute_signal(strategy, signal, mode_label)
        end
      else
        do_execute_signal(strategy, signal, mode_label)
      end
    end)
  end

  defp do_execute_signal(strategy, signal, mode_label) do
    Logger.info(
      "[Runner] #{mode_label} Signal: #{signal.action} #{signal.size} @ #{signal.price} - #{signal.reason}"
    )

    # Log the signal as an event
    Strategies.log_event(strategy, "signal", "#{mode_label} #{signal.reason}", %{
      action: signal.action,
      token_id: signal.token_id,
      price: signal.price,
      size: signal.size,
      paper_mode: strategy.paper_mode
    })

    # Create a trade record
    initial_status = if strategy.paper_mode, do: "simulated", else: "pending"

    trade_attrs = %{
      market_id: signal[:metadata][:market_id] || "unknown",
      asset_id: signal.token_id,
      side: if(signal.action == :buy, do: "BUY", else: "SELL"),
      price: Decimal.from_float(signal.price),
      size: Decimal.from_float(signal.size * 1.0),
      status: initial_status
    }

    case Strategies.create_trade(strategy, trade_attrs) do
      {:ok, trade} ->
        if strategy.paper_mode do
          # Paper mode: simulate execution immediately
          Logger.info("[Runner] #{mode_label} Trade simulated: #{trade.id}")
          simulate_trade_execution(strategy, trade, signal)
        else
          # Live mode: execute via Polymarket API
          Logger.info("[Runner] #{mode_label} Trade created: #{trade.id}")
          execute_live_trade(strategy, trade, signal)
        end

        # Broadcast signal for UI
        Phoenix.PubSub.broadcast(
          Polyx.PubSub,
          "strategies:#{strategy.id}",
          {:signal, Map.put(signal, :paper_mode, strategy.paper_mode)}
        )

      {:error, changeset} ->
        Logger.error("[Runner] Failed to create trade: #{inspect(changeset.errors)}")
    end
  end

  defp simulate_trade_execution(strategy, trade, signal) do
    # In paper mode, immediately mark trade as filled and update position
    Strategies.update_trade_status(trade, "filled", %{
      order_id: "paper_#{trade.id}_#{System.system_time(:millisecond)}"
    })

    # Update position tracking
    update_position(strategy, signal)

    Strategies.log_event(
      strategy,
      "trade",
      "[PAPER] Trade filled: #{signal.action} #{signal.size} @ #{signal.price}",
      %{
        trade_id: trade.id,
        paper_mode: true
      }
    )

    # Broadcast paper order for UI display
    broadcast_paper_order(strategy.id, %{
      id: trade.id,
      token_id: signal.token_id,
      action: signal.action,
      price: signal.price,
      size: signal.size,
      reason: signal.reason,
      status: :filled,
      paper_mode: true,
      placed_at: DateTime.utc_now(),
      metadata: signal[:metadata] || %{}
    })
  end

  defp execute_live_trade(strategy, trade, signal) do
    alias Polyx.Polymarket.Client

    order_params = %{
      token_id: signal.token_id,
      side: if(signal.action == :buy, do: "BUY", else: "SELL"),
      size: signal.size,
      price: signal.price,
      order_type: signal[:order_type] || "GTC"
    }

    Logger.info("[Runner] [LIVE] Submitting order: #{inspect(order_params)}")

    case Client.place_order(order_params) do
      {:ok, response} ->
        order_id = response["orderID"] || response["id"] || "unknown"

        Strategies.update_trade_status(trade, "submitted", %{order_id: order_id})

        Strategies.log_event(strategy, "trade", "[LIVE] Order submitted successfully", %{
          trade_id: trade.id,
          order_id: order_id,
          token_id: signal.token_id,
          action: signal.action,
          price: signal.price,
          size: signal.size
        })

        # Update position tracking
        update_position(strategy, signal)

        # Broadcast live order for UI display (same format as paper orders)
        broadcast_paper_order(strategy.id, %{
          id: trade.id,
          token_id: signal.token_id,
          action: signal.action,
          price: signal.price,
          size: signal.size,
          reason: signal.reason,
          status: :submitted,
          paper_mode: false,
          order_id: order_id,
          placed_at: DateTime.utc_now(),
          metadata: signal[:metadata] || %{}
        })

        Logger.info("[Runner] [LIVE] Order submitted: #{order_id}")

      {:error, :credentials_not_configured} ->
        Strategies.update_trade_status(trade, "failed", %{
          error: "API credentials not configured"
        })

        Strategies.log_event(
          strategy,
          "error",
          "[LIVE] Order failed: API credentials not configured",
          %{trade_id: trade.id}
        )

        Logger.error("[Runner] [LIVE] Cannot execute trade - credentials not configured")

      {:error, {status, body}} ->
        error_msg = "HTTP #{status}: #{inspect(body)}"

        Strategies.update_trade_status(trade, "failed", %{error: error_msg})

        Strategies.log_event(strategy, "error", "[LIVE] Order failed: #{error_msg}", %{
          trade_id: trade.id,
          status: status
        })

        Logger.error("[Runner] [LIVE] Order failed: #{error_msg}")

      {:error, reason} ->
        error_msg = inspect(reason)

        Strategies.update_trade_status(trade, "failed", %{error: error_msg})

        Strategies.log_event(strategy, "error", "[LIVE] Order failed: #{error_msg}", %{
          trade_id: trade.id
        })

        Logger.error("[Runner] [LIVE] Order failed: #{error_msg}")
    end
  end

  defp broadcast_live_order(strategy_id, order, signals) do
    Logger.debug(
      "[Runner] Broadcasting live order for strategy #{strategy_id}: #{inspect(order[:event_type])}"
    )

    Phoenix.PubSub.broadcast(
      Polyx.PubSub,
      "strategies:#{strategy_id}",
      {:live_order, order, signals}
    )
  end

  defp broadcast_price_update(strategy_id, token_id, price_data) do
    Phoenix.PubSub.broadcast(
      Polyx.PubSub,
      "strategies:#{strategy_id}",
      {:price_update, token_id, price_data}
    )
  end

  defp broadcast_paper_order(strategy_id, order_data) do
    Phoenix.PubSub.broadcast(
      Polyx.PubSub,
      "strategies:#{strategy_id}",
      {:paper_order, order_data}
    )
  end

  defp broadcast_discovered_tokens(strategy_id, token_ids) do
    Phoenix.PubSub.broadcast(
      Polyx.PubSub,
      "strategies:#{strategy_id}",
      {:discovered_tokens, token_ids}
    )
  end

  defp broadcast_removed_tokens(strategy_id, token_ids) do
    Phoenix.PubSub.broadcast(
      Polyx.PubSub,
      "strategies:#{strategy_id}",
      {:removed_tokens, token_ids}
    )
  end

  defp update_position(strategy, signal) do
    # Update or create position for this token
    existing = Strategies.get_position(strategy.id, signal.token_id)

    if existing do
      # Update existing position
      new_size =
        if signal.action == :buy do
          Decimal.add(existing.size, Decimal.from_float(signal.size * 1.0))
        else
          Decimal.sub(existing.size, Decimal.from_float(signal.size * 1.0))
        end

      # Recalculate average price for buys
      new_avg =
        if signal.action == :buy and Decimal.compare(new_size, 0) == :gt do
          old_value = Decimal.mult(existing.size, existing.avg_price)
          new_value = Decimal.from_float(signal.size * signal.price)
          total_value = Decimal.add(old_value, new_value)
          Decimal.div(total_value, new_size)
        else
          existing.avg_price
        end

      Strategies.upsert_position(strategy, %{
        token_id: signal.token_id,
        size: new_size,
        avg_price: new_avg,
        current_price: Decimal.from_float(signal.price)
      })
    else
      # Create new position
      Strategies.upsert_position(strategy, %{
        market_id: signal[:metadata][:market_id] || "unknown",
        token_id: signal.token_id,
        side: if(signal.action == :buy, do: "YES", else: "NO"),
        size: Decimal.from_float(signal.size * 1.0),
        avg_price: Decimal.from_float(signal.price),
        current_price: Decimal.from_float(signal.price)
      })
    end
  end

  # Extract target tokens from strategy config
  defp extract_target_tokens(config) do
    cond do
      # Direct list of token IDs
      is_list(config["target_tokens"]) and config["target_tokens"] != [] ->
        config["target_tokens"]

      # Market IDs (would need to resolve to tokens, for now just use as-is)
      is_list(config["target_markets"]) and config["target_markets"] != [] ->
        config["target_markets"]

      # Watch all tokens (not recommended for production)
      config["watch_all"] == true ->
        :all

      # Default: no filtering (process nothing to avoid flood)
      true ->
        []
    end
  end

  # Check if order should be processed based on target tokens
  # Uses exact matching only to avoid accidentally matching unrelated tokens
  defp should_process_order?(:all, _asset_id), do: true
  defp should_process_order?([], _asset_id), do: false
  defp should_process_order?(_target_tokens, nil), do: false

  defp should_process_order?(target_tokens, asset_id) when is_list(target_tokens) do
    # Exact match only - token IDs should be complete identifiers
    asset_id in target_tokens
  end

  # Extract discovered tokens from strategy state (for auto-discovery mode)
  defp extract_discovered_tokens(%{discovered_tokens: tokens}) when is_struct(tokens, MapSet) do
    tokens
  end

  defp extract_discovered_tokens(_), do: MapSet.new()

  # Process order through strategy with throttled UI broadcast
  defp process_order(order, state) do
    now = System.system_time(:millisecond)

    # Throttle UI broadcasts to avoid flooding
    should_broadcast = now - state.last_broadcast >= @broadcast_throttle_ms

    # Always broadcast price updates for tracked tokens (less throttled)
    asset_id = order[:asset_id] || order["asset_id"]

    # Only broadcast if token is still in discovered set (not resolved)
    discovered_tokens = extract_discovered_tokens(state.state)
    is_active = MapSet.member?(discovered_tokens, asset_id)

    # Track if we broadcasted to update last_broadcast time
    did_broadcast =
      if asset_id && should_broadcast && is_active do
        # Extract price from order - can come from best_bid/best_ask (price_change/book events)
        # or from price field (last_trade_price events)
        best_bid = order[:best_bid] || order["best_bid"]
        best_ask = order[:best_ask] || order["best_ask"]
        trade_price = order[:price] || order["price"]

        # Use trade price as fallback for bid/ask if not present
        effective_bid = best_bid || trade_price
        effective_ask = best_ask || trade_price

        # Only broadcast if we have some price data
        if effective_bid || effective_ask do
          price_data = %{
            best_bid: effective_bid,
            best_ask: effective_ask,
            outcome: order[:outcome] || order["outcome"],
            market_question: order[:market_question] || order["market_question"],
            updated_at: now
          }

          broadcast_price_update(state.strategy_id, asset_id, price_data)
          true
        else
          false
        end
      else
        false
      end

    case state.module.handle_order(order, state.state) do
      {:ok, new_state} ->
        # No signals generated - just update state
        # Update last_broadcast if we broadcasted a price update
        new_last = if did_broadcast, do: now, else: state.last_broadcast
        {:noreply, %{state | state: new_state, last_broadcast: new_last}}

      {:ok, new_state, signals} when is_list(signals) ->
        # Signals generated! Log and broadcast
        if signals != [] do
          Enum.each(signals, fn signal ->
            Logger.info(
              "[Runner] 🎯 SIGNAL: #{signal.action} #{signal.size} @ #{signal.price} | #{signal.reason}"
            )
          end)

          Logger.info(
            "[Runner] 📡 Broadcasting #{length(signals)} signals to strategies:#{state.strategy_id}"
          )

          broadcast_live_order(state.strategy_id, order, signals)
          execute_signals(state.strategy, signals)
        end

        {:noreply, %{state | state: new_state, last_broadcast: now}}

      {:error, reason, new_state} ->
        Logger.error("[Runner] Strategy error: #{inspect(reason)}")
        Strategies.log_event(state.strategy, "error", "Strategy error: #{inspect(reason)}")
        {:noreply, %{state | state: new_state}}
    end
  end

  # Convert raw database config to full strategy config with timeframe defaults
  defp convert_config(config) when is_map(config) do
    alias Polyx.Strategies.Config

    # Convert to Config struct and then to full strategy config
    config
    |> Config.from_map()
    |> Config.to_strategy_config()
  end
end
