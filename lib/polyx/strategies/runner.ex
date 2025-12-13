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
  # Refresh prices from Gamma API every 2 seconds as fallback
  # WebSocket provides real-time updates when there's activity
  @price_refresh_interval 2_000
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

  @doc """
  Custom child_spec to enable automatic restart on crashes.
  Uses :transient restart - only restarts on abnormal exits (crashes),
  not on normal/shutdown exits (when user stops strategy).
  """
  def child_spec(strategy_id) do
    %{
      id: {__MODULE__, strategy_id},
      start: {__MODULE__, :start_link, [strategy_id]},
      restart: :transient,
      type: :worker
    }
  end

  def stop(strategy_id) do
    GenServer.stop(via_tuple(strategy_id))
  end

  def get_state(strategy_id) do
    GenServer.call(via_tuple(strategy_id), :get_state)
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
        case module.init(strategy.config) do
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
            Logger.info("[Runner] needs_initial_discovery=#{needs_discovery}")

            if needs_discovery do
              Logger.info("[Runner] Scheduling initial discovery...")
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
    Logger.info("[Runner] *** INITIAL DISCOVERY TRIGGERED ***")
    Logger.info("[Runner] Module: #{inspect(state.module)}")

    Logger.info(
      "[Runner] Has discover_crypto_markets?: #{function_exported?(state.module, :discover_crypto_markets, 1)}"
    )

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

          # Broadcast with market metadata from cache
          market_cache = Map.get(new_state.state, :market_cache, %{})
          broadcast_discovered_tokens(state.strategy_id, new_token_list, market_cache)

          # Get resolution times for tracking
          {_priority_tokens, resolution_times} =
            get_priority_tokens_for_subscription(new_state.state)

          # Subscribe ALL new tokens to WebSocket
          Logger.info("[Runner] 🚀 Subscribing #{length(new_token_list)} new tokens to WebSocket")
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
    # Fetch prices from Gamma API for discovered tokens
    # This acts as a fallback when WebSocket has no activity
    discovered_tokens = extract_discovered_tokens(state.state)
    token_count = MapSet.size(discovered_tokens)

    Logger.debug("[Runner] refresh_prices triggered, #{token_count} discovered tokens")

    if token_count > 0 do
      # Spawn async task to avoid blocking the GenServer
      Task.start(fn ->
        Logger.debug("[Runner] Starting price fetch task for #{token_count} tokens")
        fetch_and_broadcast_prices(state.strategy_id, discovered_tokens, state.state)
        Logger.debug("[Runner] Price fetch task completed")
      end)
    end

    price_refresh_ref = Process.send_after(self(), :refresh_prices, @price_refresh_interval)
    {:noreply, %{state | price_refresh_ref: price_refresh_ref}}
  end

  # Fetch prices from Gamma API and broadcast to UI
  defp fetch_and_broadcast_prices(strategy_id, discovered_tokens, strategy_state) do
    alias Polyx.Polymarket.Gamma

    market_cache = Map.get(strategy_state, :market_cache, %{})
    token_list = MapSet.to_list(discovered_tokens)

    # Fetch fresh prices for all tokens (bypasses cache for real-time data)
    # Use Task.async_stream for concurrent fetching with back-pressure
    token_list
    |> Task.async_stream(
      fn token_id ->
        case Gamma.fetch_fresh_price(token_id) do
          {:ok, %{price: price, outcome: outcome}} when not is_nil(price) ->
            metadata = Map.get(market_cache, token_id, %{})

            price_data = %{
              price: price,
              best_bid: price,
              best_ask: price,
              outcome: outcome || metadata[:outcome],
              market_question: metadata[:question],
              updated_at: System.system_time(:millisecond)
            }

            {:ok, {token_id, price_data}}

          _ ->
            :skip
        end
      end,
      max_concurrency: 4,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.each(fn
      {:ok, {:ok, {token_id, price_data}}} ->
        broadcast_price_update(strategy_id, token_id, price_data)

      _ ->
        :ok
    end)
  end

  @impl true
  def handle_info({:discovery_complete, new_strategy_state}, state) do
    Logger.info("[Runner] Async discovery completed successfully")

    # Extract newly discovered tokens
    old_discovered = extract_discovered_tokens(state.state)
    new_discovered = extract_discovered_tokens(new_strategy_state)
    newly_found = MapSet.difference(new_discovered, old_discovered)

    # Update state with discovery results
    new_state = %{state | state: new_strategy_state}

    # Broadcast and subscribe to newly discovered tokens
    new_state =
      if MapSet.size(newly_found) > 0 do
        Logger.info("[Runner] 📡 Broadcasting #{MapSet.size(newly_found)} newly discovered tokens")

        # Get market cache from strategy state
        market_cache = Map.get(new_strategy_state, :market_cache, %{})

        broadcast_discovered_tokens(state.strategy_id, MapSet.to_list(newly_found), market_cache)
        store_discovered_tokens(state.strategy_id, MapSet.to_list(new_discovered))

        # Subscribe to WebSocket for newly discovered tokens
        new_tokens = MapSet.difference(new_discovered, new_state.websocket_subscribed)
        new_token_list = MapSet.to_list(new_tokens)

        if new_token_list != [] do
          # Get resolution times from market cache
          resolution_times =
            new_token_list
            |> Enum.map(fn token_id ->
              case Map.get(market_cache, token_id) do
                %{end_date: end_date} when is_binary(end_date) ->
                  case DateTime.from_iso8601(end_date) do
                    {:ok, dt, _} -> {token_id, DateTime.to_unix(dt)}
                    _ -> {token_id, nil}
                  end

                _ ->
                  {token_id, nil}
              end
            end)
            |> Map.new()

          # Subscribe ALL new tokens to WebSocket
          Logger.info("[Runner] 🚀 Subscribing #{length(new_token_list)} new tokens to WebSocket")
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

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:discovery_failed, state) do
    Logger.warning("[Runner] Async discovery failed, will retry on next tick")
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    # Ignore unknown messages (batch orders, etc.)
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

      :shutdown ->
        Strategies.update_strategy_status(state.strategy, "stopped")
        Strategies.log_event(state.strategy, "info", "Strategy shutdown")

      {:shutdown, _} ->
        Strategies.update_strategy_status(state.strategy, "stopped")
        Strategies.log_event(state.strategy, "info", "Strategy shutdown")

      _ ->
        # Crash - will auto-restart due to :transient restart strategy
        Logger.error(
          "[Runner] Strategy #{state.strategy.id} crashed: #{inspect(reason)} - will auto-restart"
        )

        Strategies.update_strategy_status(state.strategy, "error")

        Strategies.log_event(
          state.strategy,
          "error",
          "Strategy crashed (auto-restarting): #{inspect(reason)}"
        )

        # Broadcast crash to UI
        Phoenix.PubSub.broadcast(
          Polyx.PubSub,
          "strategies:#{state.strategy_id}",
          {:strategy_crashed, %{reason: inspect(reason)}}
        )
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

      # Broadcast with market metadata from cache
      market_cache = Map.get(strategy_state, :market_cache, %{})
      broadcast_discovered_tokens(strategy_id, token_list, market_cache)

      # Get resolution times for tracking
      {_priority_tokens, resolution_times} = get_priority_tokens_for_subscription(strategy_state)

      Logger.info("[Runner] 🚀 Subscribing ALL #{length(token_list)} tokens to WebSocket")
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

    # Round price to tick size (0.001) - Polymarket requirement
    rounded_price = round_to_tick_size(signal.price)

    # Ensure size meets minimums (5 shares AND $1 value)
    validated_size = validate_order_size(signal.size, rounded_price)

    order_params = %{
      token_id: signal.token_id,
      side: if(signal.action == :buy, do: "BUY", else: "SELL"),
      size: validated_size,
      price: rounded_price,
      order_type: signal[:order_type] || "GTC"
    }

    Logger.info(
      "[Runner] [LIVE] Submitting order: #{order_params.side} #{order_params.size} shares @ #{order_params.price}"
    )

    case Client.place_order(order_params) do
      {:ok, response} ->
        order_id = response["orderID"] || response["id"] || "unknown"

        Strategies.update_trade_status(trade, "submitted", %{order_id: order_id})

        Strategies.log_event(strategy, "trade", "[LIVE] Order submitted successfully", %{
          trade_id: trade.id,
          order_id: order_id,
          token_id: signal.token_id,
          action: signal.action,
          price: rounded_price,
          size: validated_size
        })

        # Update position tracking
        update_position(strategy, signal)

        # Broadcast live order for UI display (same format as paper orders)
        broadcast_paper_order(strategy.id, %{
          id: trade.id,
          token_id: signal.token_id,
          action: signal.action,
          price: rounded_price,
          size: validated_size,
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

  defp broadcast_discovered_tokens(strategy_id, token_ids, market_cache) do
    Logger.info(
      "[Runner] Broadcasting #{length(token_ids)} newly discovered tokens with metadata"
    )

    # Build token metadata map from cache
    tokens_with_metadata =
      token_ids
      |> Enum.map(fn token_id ->
        metadata = Map.get(market_cache, token_id, %{})

        {token_id,
         %{
           market_question: metadata[:question] || metadata[:market_question],
           outcome: metadata[:outcome],
           event_title: metadata[:event_title],
           end_date: metadata[:end_date]
         }}
      end)
      |> Map.new()

    Phoenix.PubSub.broadcast(
      Polyx.PubSub,
      "strategies:#{strategy_id}",
      {:discovered_tokens, token_ids, tokens_with_metadata}
    )
  end

  defp broadcast_removed_tokens(strategy_id, token_ids) do
    Logger.info("[Runner] Broadcasting #{length(token_ids)} removed tokens (resolved markets)")

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

    # Debug logging to understand why broadcasts aren't happening
    Logger.debug(
      "[Runner] Price update check: asset_id=#{inspect(asset_id)}, should_broadcast=#{should_broadcast}, is_active=#{is_active}, discovered_count=#{MapSet.size(discovered_tokens)}"
    )

    # Track if we broadcasted to update last_broadcast time
    did_broadcast =
      if asset_id && should_broadcast && is_active do
        # Include trade price if available (from last_trade_price events)
        price_data = %{
          price: order[:price] || order["price"],
          best_bid: order[:best_bid] || order["best_bid"],
          best_ask: order[:best_ask] || order["best_ask"],
          outcome: order[:outcome] || order["outcome"],
          market_question: order[:market_question] || order["market_question"],
          updated_at: now
        }

        Logger.info("[Runner] 📊 Broadcasting price update for #{asset_id}")
        broadcast_price_update(state.strategy_id, asset_id, price_data)
        true
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

  # Order validation helpers (copied from CopyTrading.TradeExecutor)

  # Polymarket minimum requirements:
  # 1. Minimum 5 shares per order
  # 2. Minimum $1 dollar value for marketable orders
  @min_order_shares 5.0
  @min_order_dollars 1.0

  defp validate_order_size(shares, price) when is_number(shares) and is_number(price) do
    # Enforce minimum of 5 shares
    shares = max(shares, @min_order_shares)

    # Also enforce minimum $1 dollar value
    min_shares_for_dollar = if price > 0, do: @min_order_dollars / price, else: @min_order_shares
    max(shares, min_shares_for_dollar)
  end

  defp validate_order_size(shares, _price), do: max(shares, @min_order_shares)

  # Round price to minimum tick size of 0.001 (3 decimal places)
  # Price must be > 0 and < 1, so we floor to avoid rounding up to 1.0
  defp round_to_tick_size(price) when is_number(price) do
    rounded = Float.floor(price * 1000) / 1000

    # Ensure price stays within valid bounds (0, 1)
    cond do
      rounded >= 1.0 -> 0.999
      rounded <= 0.0 -> 0.001
      true -> rounded
    end
  end

  defp round_to_tick_size(price), do: price
end
