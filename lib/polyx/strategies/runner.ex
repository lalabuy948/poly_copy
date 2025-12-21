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
  alias Polyx.Polymarket.{LiveOrders, Client}
  alias PolyxWeb.StrategiesLive.PriceUtils

  @tick_interval 5_000
  # Minimal throttle - let LiveView handle batching for better responsiveness
  @broadcast_throttle_ms 250
  # Discovery interval - check for new/expired markets every 2 minutes
  @discovery_interval 120_000

  defstruct [
    :strategy_id,
    :strategy,
    :module,
    :state,
    :tick_ref,
    :discovery_ref,
    :target_tokens,
    :last_broadcast,
    # Tokens we're tracking - map of token_id => market_info
    discovered_tokens: %{},
    # Cached prices from WebSocket - map of token_id => price_data
    token_prices: %{},
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
  Get discovered token IDs from a running strategy.
  Returns {:ok, list_of_token_ids}.
  """
  def get_discovered_tokens(strategy_id) do
    try do
      tokens = GenServer.call(via_tuple(strategy_id), :get_discovered_tokens, 5_000)
      {:ok, tokens}
    catch
      :exit, _ -> {:ok, []}
    end
  end

  @doc """
  Get discovered tokens with market info from a running strategy.
  Returns {:ok, map} where map is %{token_id => %{market_question: ..., end_date: ..., ...}}.
  """
  def get_discovered_tokens_with_info(strategy_id) do
    try do
      tokens = GenServer.call(via_tuple(strategy_id), :get_discovered_tokens_with_info, 5_000)
      {:ok, tokens}
    catch
      :exit, _ -> {:ok, %{}}
    end
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

        Logger.info(
          "[Runner] Module: #{module}, timeframe: #{full_config["market_timeframe"]}, max_minutes: #{full_config["max_minutes_to_resolution"]}"
        )

        case module.init(full_config) do
          {:ok, strategy_state} ->
            # Subscribe to live orders
            LiveOrders.subscribe()

            # Update strategy status
            Strategies.update_strategy_status(strategy, "running")
            mode = if strategy.paper_mode, do: "paper", else: "live"

            # Extract target tokens from config (list of token IDs to watch)
            target_tokens = extract_target_tokens(strategy.config)

            Strategies.log_event(strategy, "info", "Strategy started (#{mode} mode)")

            # Schedule periodic tick for signal processing
            tick_ref = Process.send_after(self(), :tick, @tick_interval)

            state = %__MODULE__{
              strategy_id: strategy_id,
              strategy: strategy,
              module: module,
              state: strategy_state,
              tick_ref: tick_ref,
              discovery_ref: nil,
              target_tokens: target_tokens,
              last_broadcast: 0,
              discovered_tokens: %{}
            }

            state = prime_target_tokens(state)

            # Run initial discovery immediately (don't block init)
            send(self(), :discover)

            Logger.info("[Runner] Started strategy #{strategy.name} (#{strategy.type}, #{mode})")

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
  def handle_call(:get_discovered_tokens, _from, state) do
    # Return tokens directly from Runner state
    {:reply, Map.keys(state.discovered_tokens), state}
  end

  @impl true
  def handle_call(:get_discovered_tokens_with_info, _from, state) do
    # Return full token info merged with cached prices for UI
    tokens_with_prices =
      Enum.reduce(state.discovered_tokens, %{}, fn {token_id, info}, acc ->
        cached_price = Map.get(state.token_prices, token_id, %{})

        merged = %{
          market_question: info[:market_question] || cached_price[:market_question],
          event_title: info[:event_title],
          outcome: info[:outcome] || cached_price[:outcome],
          end_date: info[:end_date],
          best_bid: cached_price[:best_bid],
          best_ask: cached_price[:best_ask],
          updated_at: info[:updated_at]
        }

        Map.put(acc, token_id, merged)
      end)

    {:reply, tokens_with_prices, state}
  end

  @impl true
  def handle_info({:new_order, order}, state) do
    if not state.paused do
      asset_id = order[:asset_id] || order["asset_id"]

      # Check if this token is in our discovered list (simple map key check)
      is_discovered = Map.has_key?(state.discovered_tokens, asset_id)

      if is_discovered do
        process_order(order, state)
      else
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
  def handle_info(:discover, state) do
    Logger.info("[Runner] Running discovery for strategy #{state.strategy_id}")

    new_state =
      if function_exported?(state.module, :discover_crypto_markets, 1) do
        case state.module.discover_crypto_markets(state.state) do
          {:ok, new_strategy_state} ->
            sync_discovered_tokens(state, new_strategy_state)

          {:ok, new_strategy_state, _signals} ->
            sync_discovered_tokens(state, new_strategy_state)

          other ->
            Logger.error("[Runner] Discovery failed: #{inspect(other)}")
            state
        end
      else
        state
      end

    # Schedule next discovery in 2 minutes
    discovery_ref = Process.send_after(self(), :discover, @discovery_interval)
    {:noreply, %{new_state | discovery_ref: discovery_ref}}
  end

  @impl true
  def handle_info(:tick, state) do
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

    # Schedule next tick
    tick_ref = Process.send_after(self(), :tick, @tick_interval)
    {:noreply, %{new_state | tick_ref: tick_ref}}
  end

  @impl true
  def handle_info({:new_orders_batch, _orders}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    if state.tick_ref, do: Process.cancel_timer(state.tick_ref)
    if state.discovery_ref, do: Process.cancel_timer(state.discovery_ref)

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

  # Sync Runner's discovered_tokens with strategy state
  # Handles: new tokens (add + subscribe), expired tokens (remove + unsubscribe), same tokens (no-op)
  defp sync_discovered_tokens(runner_state, strategy_state) do
    strategy_id = runner_state.strategy_id
    market_cache = Map.get(strategy_state, :market_cache, %{})

    # Get token IDs from strategy's discovered_tokens MapSet
    new_token_ids =
      case Map.get(strategy_state, :discovered_tokens) do
        %MapSet{} = set -> MapSet.to_list(set)
        _ -> []
      end
      |> MapSet.new()
      |> MapSet.union(MapSet.new(target_token_list(runner_state)))
      |> MapSet.to_list()

    current_token_ids = Map.keys(runner_state.discovered_tokens)

    # Find what changed
    new_set = MapSet.new(new_token_ids)
    current_set = MapSet.new(current_token_ids)
    added = MapSet.difference(new_set, current_set) |> MapSet.to_list()
    removed = MapSet.difference(current_set, new_set) |> MapSet.to_list()

    # Build new discovered_tokens map with market info
    new_discovered_tokens =
      Enum.reduce(new_token_ids, %{}, fn token_id, acc ->
        info =
          case Map.get(market_cache, token_id) do
            nil ->
              %{updated_at: System.system_time(:millisecond)}

            market_info ->
              %{
                market_question: market_info[:question],
                event_title: market_info[:event_title],
                outcome: market_info[:outcome],
                end_date: market_info[:end_date],
                updated_at: System.system_time(:millisecond)
              }
          end

        Map.put(acc, token_id, info)
      end)

    # Handle added tokens
    {runner_state, new_discovered_tokens} =
      if added != [] do
        Logger.info("[Runner] Discovered #{length(added)} new tokens, subscribing to WebSocket")

        # Log each token being subscribed
        Enum.each(added, fn token_id ->
          token_info = new_discovered_tokens[token_id]

          Logger.info(
            "[Runner]   → Subscribing: #{token_info[:outcome] || "?"} - #{token_info[:market_question] || "unknown"}"
          )
        end)

        LiveOrders.subscribe_to_markets(added)

        # Seed initial prices from orderbooks so UI shows bid/ask before WS ticks arrive
        seeded_prices = fetch_initial_prices(added, new_discovered_tokens)
        merged_prices = Map.merge(runner_state.token_prices, seeded_prices)

        Enum.each(seeded_prices, fn {token_id, price_data} ->
          broadcast_price_update(strategy_id, token_id, price_data)
        end)

        # Broadcast new tokens to UI
        tokens_with_info =
          Enum.map(added, fn token_id -> {token_id, new_discovered_tokens[token_id]} end)

        Phoenix.PubSub.broadcast(
          Polyx.PubSub,
          "strategies:#{strategy_id}",
          {:discovered_tokens, tokens_with_info}
        )

        {%{runner_state | token_prices: merged_prices}, new_discovered_tokens}
      else
        {runner_state, new_discovered_tokens}
      end

    # Handle removed tokens
    if removed != [] do
      Logger.info("[Runner] Removing #{length(removed)} expired tokens: #{inspect(removed)}")
      LiveOrders.unsubscribe_from_markets(removed)

      Phoenix.PubSub.broadcast(
        Polyx.PubSub,
        "strategies:#{strategy_id}",
        {:removed_tokens, removed}
      )
    end

    # Log current state
    Logger.info("[Runner] Token sync complete: #{length(new_token_ids)} active tokens")

    %{runner_state | state: strategy_state, discovered_tokens: new_discovered_tokens}
  end

  defp prime_target_tokens(%__MODULE__{} = state) do
    tokens = target_token_list(state)

    if tokens == [] do
      state
    else
      Logger.info("[Runner] Subscribing to #{length(tokens)} configured target tokens")
      LiveOrders.subscribe_to_markets(tokens)

      discovered =
        Enum.reduce(tokens, state.discovered_tokens, fn token_id, acc ->
          Map.put_new(acc, token_id, %{updated_at: System.system_time(:millisecond)})
        end)

      %{state | discovered_tokens: discovered}
    end
  end

  defp target_token_list(%__MODULE__{} = state) do
    case state.target_tokens do
      :all -> []
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

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

  # Seed initial prices via REST orderbook for newly added tokens
  defp fetch_initial_prices(token_ids, discovered_tokens) do
    now = System.system_time(:millisecond)

    token_ids
    |> Task.async_stream(
      fn token_id ->
        case Client.get_orderbook(token_id) do
          {:ok, %{"bids" => bids, "asks" => asks}} ->
            best_bid = get_best_price(bids)
            best_ask = get_best_price(asks)
            mid = PriceUtils.calculate_mid(best_bid, best_ask)
            info = Map.get(discovered_tokens, token_id, %{})

            price_data = %{
              best_bid: best_bid,
              best_ask: best_ask,
              mid: mid,
              market_question: info[:market_question],
              event_title: info[:event_title],
              outcome: info[:outcome],
              end_date: info[:end_date],
              updated_at: now
            }

            {token_id, price_data}

          _ ->
            nil
        end
      end,
      max_concurrency: 5,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {token_id, price_data}}, acc when is_map(price_data) ->
        Map.put(acc, token_id, price_data)

      _other, acc ->
        acc
    end)
  end

  defp get_best_price([%{"price" => price} | _]) when is_binary(price) do
    case Float.parse(price) do
      {val, _} -> val
      :error -> nil
    end
  end

  defp get_best_price([%{"price" => price} | _]) when is_number(price), do: price
  defp get_best_price(_), do: nil

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

  # Process order through strategy with throttled UI broadcast
  defp process_order(order, state) do
    now = System.system_time(:millisecond)
    should_broadcast = now - state.last_broadcast >= @broadcast_throttle_ms
    asset_id = order[:asset_id] || order["asset_id"]

    # Extract price from order - can come from best_bid/best_ask (price_change/book events)
    # or from price field (last_trade_price events)
    best_bid = order[:best_bid] || order["best_bid"]
    best_ask = order[:best_ask] || order["best_ask"]
    trade_price = order[:price] || order["price"]

    # Use trade price as fallback for bid/ask if not present
    effective_bid = best_bid || trade_price
    effective_ask = best_ask || trade_price

    # Always cache prices in state (for new UI subscribers)
    state =
      if asset_id && (effective_bid || effective_ask) do
        price_data = %{
          best_bid: effective_bid,
          best_ask: effective_ask,
          outcome: order[:outcome] || order["outcome"],
          market_question: order[:market_question] || order["market_question"],
          updated_at: now
        }

        updated_prices = Map.put(state.token_prices, asset_id, price_data)
        %{state | token_prices: updated_prices}
      else
        state
      end

    # Broadcast price update if token is active (throttled)
    did_broadcast =
      if asset_id && should_broadcast && (effective_bid || effective_ask) do
        price_data = Map.get(state.token_prices, asset_id)
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

  # Convert raw database config to full strategy config with timeframe defaults
  defp convert_config(config) when is_map(config) do
    alias Polyx.Strategies.Config

    # Convert to Config struct and then to full strategy config
    config
    |> Config.from_map()
    |> Config.to_strategy_config()
  end
end
