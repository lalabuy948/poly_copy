defmodule PolyxWeb.StrategiesLive do
  use PolyxWeb, :live_view

  require Logger
  alias Polyx.Strategies
  alias Polyx.Strategies.{Engine, Runner, Behaviour, Config}
  alias Polyx.Polymarket.Gamma

  # Batch interval for UI updates (ms) - maximum real-time responsiveness
  @batch_interval 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to strategy updates
      Phoenix.PubSub.subscribe(Polyx.PubSub, "strategies:updates")
      # Refresh strategy states every 30 seconds (reduced from 5s to minimize DB load)
      :timer.send_interval(30_000, self(), :refresh_strategies)
      # Start batch flush timer
      :timer.send_interval(@batch_interval, self(), :flush_ui_batch)
    end

    strategies = Strategies.list_strategies() |> enrich_with_running_state()

    {:ok,
     socket
     |> assign(:page_title, "Trading Strategies")
     |> assign(:strategies, strategies)
     |> assign(:show_new_form, false)
     |> assign(:selected_strategy, nil)
     |> assign(:new_strategy_type, "time_decay")
     |> assign(:new_strategy_name, "")
     |> assign(:editing_config, false)
     |> assign(:config_form, %{})
     # Market browser state
     |> assign(:show_market_browser, false)
     |> assign(:market_search, "")
     |> assign(:market_events, [])
     |> assign(:market_loading, false)
     |> assign(:market_offset, 0)
     |> assign(:market_has_more, true)
     |> assign(:selected_tokens, [])
     |> assign(:market_categories, Gamma.get_categories())
     |> assign(:selected_category, nil)
     |> assign(:expanded_events, MapSet.new())
     # Live price tracking for subscribed tokens: %{token_id => price_data}
     |> assign(:token_prices, %{})
     # Paper orders (in-memory, no persistence): list of order maps
     |> assign(:paper_orders, [])
     # Batched UI updates - accumulate changes and flush every @batch_interval ms
     |> assign(:batch_price_updates, %{})
     |> assign(:batch_signals, [])
     |> assign(:batch_live_orders, [])
     |> assign(:batch_paper_orders, [])
     # Price update tracking for visual feedback
     |> assign(:price_update_count, 0)
     |> assign(:last_price_update_at, nil)
     |> stream(:events, [])
     |> stream(:live_orders, [])}
  end

  @impl true
  def handle_event("toggle_new_form", _params, socket) do
    {:noreply, assign(socket, :show_new_form, !socket.assigns.show_new_form)}
  end

  @impl true
  def handle_event("select_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :new_strategy_type, type)}
  end

  @impl true
  def handle_event("update_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :new_strategy_name, name)}
  end

  @impl true
  def handle_event("create_strategy", _params, socket) do
    type = socket.assigns.new_strategy_type
    name = socket.assigns.new_strategy_name
    name = if name == "", do: Behaviour.display_name(type), else: name

    attrs = %{
      name: name,
      type: type,
      config: Behaviour.default_config(type),
      status: "stopped"
    }

    case Strategies.create_strategy(attrs) do
      {:ok, strategy} ->
        strategies = [strategy | socket.assigns.strategies]

        {:noreply,
         socket
         |> assign(:strategies, strategies)
         |> assign(:show_new_form, false)
         |> assign(:new_strategy_name, "")
         |> put_flash(:info, "Strategy created")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create strategy")}
    end
  end

  @impl true
  def handle_event("toggle_live", %{"id" => id}, socket) do
    id = String.to_integer(id)
    is_running = Engine.running?(id)

    # Simple toggle: if running -> stop, if stopped -> start
    {result, action} =
      if is_running do
        {Engine.stop_strategy(id), "stopped"}
      else
        {Engine.start_strategy(id), "started"}
      end

    case result do
      {:ok, _pid} ->
        refresh_strategies(socket, id, action)

      :ok ->
        refresh_strategies(socket, id, action)

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("delete_strategy", %{"id" => id}, socket) do
    id = String.to_integer(id)
    strategy = Strategies.get_strategy!(id)

    # Stop if running
    Engine.stop_strategy(id)

    case Strategies.delete_strategy(strategy) do
      {:ok, _} ->
        strategies = Enum.reject(socket.assigns.strategies, &(&1.id == id))

        {:noreply,
         socket |> assign(:strategies, strategies) |> put_flash(:info, "Strategy deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete strategy")}
    end
  end

  @impl true
  def handle_event("select_strategy", %{"id" => id}, socket) do
    id = String.to_integer(id)
    strategy = Strategies.get_strategy!(id)
    events = Strategies.list_events(id, limit: 50)
    stats = Strategies.get_strategy_stats(id)

    # Unsubscribe from previous strategy if any
    if socket.assigns.selected_strategy do
      Phoenix.PubSub.unsubscribe(
        Polyx.PubSub,
        "strategies:#{socket.assigns.selected_strategy.strategy.id}"
      )
    end

    # Subscribe to this strategy's updates
    Phoenix.PubSub.subscribe(Polyx.PubSub, "strategies:#{id}")

    # Fetch initial prices for target tokens asynchronously
    target_tokens = strategy.config["target_tokens"] || []

    if target_tokens != [] do
      send(self(), {:fetch_initial_prices, target_tokens})
    end

    # For auto-discovery mode, fetch discovered tokens asynchronously
    # Time decay strategy uses auto-discovery by default (hardcoded in init/1)
    auto_discover =
      strategy.config["auto_discover_crypto"] == true or strategy.type == "time_decay"

    is_running = Engine.running?(id)

    # Auto-recover crashed strategy: if DB says "running" but Runner is dead, restart it
    is_running =
      if strategy.status == "running" and not is_running do
        require Logger

        Logger.warning(
          "[StrategiesLive] Strategy #{id} marked running but Runner dead, restarting..."
        )

        case Engine.start_strategy(id) do
          {:ok, _pid} ->
            Logger.info("[StrategiesLive] ✅ Strategy #{id} auto-recovered")
            true

          {:error, reason} ->
            Logger.error(
              "[StrategiesLive] ❌ Failed to restart strategy #{id}: #{inspect(reason)}"
            )

            false
        end
      else
        is_running
      end

    if auto_discover and is_running do
      send(self(), {:fetch_runner_discovered_tokens, id})
    end

    # Enrich strategy with actual running state (Registry is source of truth)
    enriched_strategy = %{strategy | status: if(is_running, do: "running", else: "stopped")}

    # Load existing trades from database
    existing_trades = Strategies.list_trades(id, limit: 50)
    paper_orders = Enum.map(existing_trades, &trade_to_paper_order/1)

    {:noreply,
     socket
     |> assign(:selected_strategy, %{strategy: enriched_strategy, stats: stats})
     |> assign(:token_prices, %{})
     |> assign(:paper_orders, paper_orders)
     # Reset batch state
     |> assign(:batch_price_updates, %{})
     |> assign(:batch_signals, [])
     |> assign(:batch_live_orders, [])
     |> assign(:batch_paper_orders, [])
     |> stream(:events, events, reset: true)
     |> stream(:live_orders, [], reset: true)}
  end

  @impl true
  def handle_event("close_details", _params, socket) do
    if socket.assigns.selected_strategy do
      Phoenix.PubSub.unsubscribe(
        Polyx.PubSub,
        "strategies:#{socket.assigns.selected_strategy.strategy.id}"
      )
    end

    {:noreply, assign(socket, :selected_strategy, nil)}
  end

  @impl true
  def handle_event("clear_activity_log", _params, socket) do
    {:noreply, stream(socket, :events, [], reset: true)}
  end

  @impl true
  def handle_event("clear_trades", _params, socket) do
    if socket.assigns.selected_strategy do
      strategy_id = socket.assigns.selected_strategy.strategy.id
      {count, _} = Strategies.delete_trades(strategy_id)

      {:noreply,
       socket
       |> assign(:paper_orders, [])
       |> put_flash(:info, "Deleted #{count} trades")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_paper_mode", %{"id" => id}, socket) do
    id = String.to_integer(id)
    strategy = Strategies.get_strategy!(id)
    new_paper_mode = !strategy.paper_mode

    case Strategies.update_strategy(strategy, %{paper_mode: new_paper_mode}) do
      {:ok, updated} ->
        strategies =
          Enum.map(socket.assigns.strategies, fn s ->
            if s.id == id, do: updated, else: s
          end)

        selected =
          if socket.assigns.selected_strategy &&
               socket.assigns.selected_strategy.strategy.id == id do
            %{socket.assigns.selected_strategy | strategy: updated}
          else
            socket.assigns.selected_strategy
          end

        mode_label = if new_paper_mode, do: "Paper", else: "Live"

        {:noreply,
         socket
         |> assign(:strategies, strategies)
         |> assign(:selected_strategy, selected)
         |> put_flash(:info, "Switched to #{mode_label} mode")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle paper mode")}
    end
  end

  @impl true
  def handle_event("edit_config", _params, socket) do
    config_map = socket.assigns.selected_strategy.strategy.config
    config = Config.from_map(config_map)
    changeset = Config.changeset(config, %{})
    form = to_form(changeset, as: :config)
    {:noreply, socket |> assign(:editing_config, true) |> assign(:config_form, form)}
  end

  @impl true
  def handle_event("cancel_edit_config", _params, socket) do
    {:noreply, socket |> assign(:editing_config, false) |> assign(:config_form, nil)}
  end

  @impl true
  def handle_event("validate_config", %{"config" => config_params}, socket) do
    config_map = socket.assigns.selected_strategy.strategy.config
    config = Config.from_map(config_map)

    changeset =
      config
      |> Config.changeset(config_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :config_form, to_form(changeset, as: :config))}
  end

  @impl true
  def handle_event("save_config", %{"config" => config_params}, socket) do
    strategy = socket.assigns.selected_strategy.strategy
    config_map = strategy.config
    config = Config.from_map(config_map)

    changeset = Config.changeset(config, config_params)

    if changeset.valid? do
      # Apply changes and convert to map for storage
      updated_config = Ecto.Changeset.apply_changes(changeset)
      new_config_map = Config.to_map(updated_config)

      case Strategies.update_strategy(strategy, %{config: new_config_map}) do
        {:ok, updated} ->
          # Update selected strategy
          selected = %{socket.assigns.selected_strategy | strategy: updated}

          # Update in list
          strategies =
            Enum.map(socket.assigns.strategies, fn s ->
              if s.id == updated.id, do: updated, else: s
            end)

          {:noreply,
           socket
           |> assign(:selected_strategy, selected)
           |> assign(:strategies, strategies)
           |> assign(:editing_config, false)
           |> assign(:config_form, nil)
           |> put_flash(:info, "Configuration saved")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save configuration")}
      end
    else
      {:noreply, assign(socket, :config_form, to_form(changeset, as: :config))}
    end
  end

  # Market Browser Events

  @impl true
  def handle_event("open_market_browser", _params, socket) do
    # Load initial events when opening browser
    send(self(), {:load_market_events, 0, nil})

    # Get current strategy's tokens to pre-select
    current_tokens = socket.assigns.selected_strategy.strategy.config["target_tokens"] || []

    {:noreply,
     socket
     |> assign(:show_market_browser, true)
     |> assign(:selected_tokens, current_tokens)
     |> assign(:market_events, [])
     |> assign(:market_offset, 0)
     |> assign(:market_has_more, true)
     |> assign(:market_loading, true)
     |> assign(:selected_category, nil)}
  end

  @impl true
  def handle_event("close_market_browser", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_market_browser, false)
     |> assign(:market_events, [])
     |> assign(:market_search, "")}
  end

  @impl true
  def handle_event("market_search", %{"search" => query}, socket) do
    socket =
      socket
      |> assign(:market_search, query)
      |> assign(:market_events, [])
      |> assign(:market_offset, 0)
      |> assign(:market_has_more, true)
      |> assign(:selected_category, nil)

    if String.length(query) >= 2 do
      send(self(), {:search_markets, query})
      {:noreply, assign(socket, :market_loading, true)}
    else
      send(self(), {:load_market_events, 0, nil})
      {:noreply, assign(socket, :market_loading, true)}
    end
  end

  @impl true
  def handle_event("select_category", %{"category-id" => category_id}, socket) do
    # Toggle category selection
    current = socket.assigns.selected_category
    new_category = if current == category_id, do: nil, else: category_id

    # Find category and use its keywords for filtering
    category = Enum.find(socket.assigns.market_categories, &(&1.id == new_category))

    if category do
      # Use first keyword for search
      send(self(), {:filter_by_category, category.keywords})
    else
      send(self(), {:load_market_events, 0, nil})
    end

    {:noreply,
     socket
     |> assign(:selected_category, new_category)
     |> assign(:market_events, [])
     |> assign(:market_offset, 0)
     |> assign(:market_has_more, false)
     |> assign(:market_loading, true)
     |> assign(:market_search, "")}
  end

  @impl true
  def handle_event("load_more_markets", _params, socket) do
    offset = socket.assigns.market_offset
    send(self(), {:load_market_events, offset, nil})
    {:noreply, assign(socket, :market_loading, true)}
  end

  @impl true
  def handle_event("toggle_event_tokens", %{"event-id" => event_id}, socket) do
    event = Enum.find(socket.assigns.market_events, &(&1.id == event_id))

    if event do
      current = socket.assigns.selected_tokens
      event_tokens = event.token_ids

      # Toggle: if all tokens from event are selected, remove them; otherwise add them
      all_selected = Enum.all?(event_tokens, &(&1 in current))

      new_tokens =
        if all_selected do
          Enum.reject(current, &(&1 in event_tokens))
        else
          Enum.uniq(current ++ event_tokens)
        end

      {:noreply, assign(socket, :selected_tokens, new_tokens)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_event_expand", %{"event-id" => event_id}, socket) do
    expanded = socket.assigns.expanded_events

    new_expanded =
      if MapSet.member?(expanded, event_id) do
        MapSet.delete(expanded, event_id)
      else
        MapSet.put(expanded, event_id)
      end

    {:noreply, assign(socket, :expanded_events, new_expanded)}
  end

  @impl true
  def handle_event("toggle_market_token", %{"token-id" => token_id}, socket) do
    current = socket.assigns.selected_tokens

    new_tokens =
      if token_id in current do
        Enum.reject(current, &(&1 == token_id))
      else
        [token_id | current]
      end

    {:noreply, assign(socket, :selected_tokens, new_tokens)}
  end

  @impl true
  def handle_event("apply_market_selection", _params, socket) do
    strategy = socket.assigns.selected_strategy.strategy
    new_config = Map.put(strategy.config, "target_tokens", socket.assigns.selected_tokens)

    case Strategies.update_strategy(strategy, %{config: new_config}) do
      {:ok, updated} ->
        selected = %{socket.assigns.selected_strategy | strategy: updated}

        strategies =
          Enum.map(socket.assigns.strategies, fn s ->
            if s.id == updated.id, do: updated, else: s
          end)

        {:noreply,
         socket
         |> assign(:selected_strategy, selected)
         |> assign(:strategies, strategies)
         |> assign(:show_market_browser, false)
         |> assign(:market_events, [])
         |> assign(:market_search, "")
         |> put_flash(
           :info,
           "Markets updated - #{length(socket.assigns.selected_tokens)} tokens selected"
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update markets")}
    end
  end

  @market_page_size 50

  @impl true
  def handle_info({:load_market_events, offset, _filter}, socket) do
    opts = [limit: @market_page_size, offset: offset]

    case Gamma.fetch_events(opts) do
      {:ok, events} ->
        # Append to existing if loading more, replace if offset is 0
        all_events =
          if offset == 0 do
            events
          else
            socket.assigns.market_events ++ events
          end

        has_more = length(events) >= @market_page_size

        {:noreply,
         socket
         |> assign(:market_events, all_events)
         |> assign(:market_offset, offset + length(events))
         |> assign(:market_has_more, has_more)
         |> assign(:market_loading, false)}

      {:error, _} ->
        {:noreply, socket |> assign(:market_loading, false)}
    end
  end

  @impl true
  def handle_info({:filter_by_category, keywords}, socket) do
    # Fetch more events and filter locally by keywords
    case Gamma.fetch_events(limit: 200) do
      {:ok, events} ->
        # Filter events that match any keyword in title or description
        filtered =
          Enum.filter(events, fn event ->
            text = String.downcase("#{event.title} #{event.description || ""}")
            Enum.any?(keywords, &String.contains?(text, String.downcase(&1)))
          end)

        {:noreply,
         socket
         |> assign(:market_events, filtered)
         |> assign(:market_has_more, false)
         |> assign(:market_loading, false)}

      {:error, _} ->
        {:noreply, socket |> assign(:market_loading, false)}
    end
  end

  @impl true
  def handle_info({:search_markets, query}, socket) do
    # Try search API first, fall back to filtering
    case Gamma.search_events(query, limit: 30) do
      {:ok, events} when events != [] ->
        {:noreply, socket |> assign(:market_events, events) |> assign(:market_loading, false)}

      _ ->
        # Fallback: fetch all and filter locally
        case Gamma.fetch_events(limit: 50, search: query) do
          {:ok, events} ->
            {:noreply, socket |> assign(:market_events, events) |> assign(:market_loading, false)}

          {:error, _} ->
            {:noreply, socket |> assign(:market_loading, false)}
        end
    end
  end

  @impl true
  def handle_info(:refresh_strategies, socket) do
    strategies = Strategies.list_strategies() |> enrich_with_running_state()

    # Update selected strategy from the already-fetched list to avoid extra DB query
    selected =
      if socket.assigns.selected_strategy do
        id = socket.assigns.selected_strategy.strategy.id
        updated = Enum.find(strategies, &(&1.id == id))

        if updated do
          # Only refresh stats occasionally, reuse cached stats most of the time
          %{socket.assigns.selected_strategy | strategy: updated}
        else
          nil
        end
      else
        nil
      end

    {:noreply,
     socket
     |> assign(:strategies, strategies)
     |> assign(:selected_strategy, selected)}
  end

  @impl true
  def handle_info({:signal, signal}, socket) do
    # Batch signal for next UI flush
    event = %{
      id: System.unique_integer([:positive]),
      type: "signal",
      message: signal.reason,
      metadata: signal,
      inserted_at: DateTime.utc_now()
    }

    batch_signals = [event | socket.assigns.batch_signals]
    {:noreply, assign(socket, :batch_signals, batch_signals)}
  end

  @impl true
  def handle_info({:live_order, order, signals}, socket) do
    # Only batch orders that OUR strategy triggered (has signals)
    triggered = signals != nil and signals != []

    if triggered do
      live_order = %{
        id: System.unique_integer([:positive]),
        order: order,
        signals: signals,
        triggered: true,
        timestamp: DateTime.utc_now()
      }

      batch_live_orders = [live_order | socket.assigns.batch_live_orders]
      {:noreply, assign(socket, :batch_live_orders, batch_live_orders)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:price_update, token_id, price_data}, socket) do
    Logger.debug(
      "[StrategiesLive] Received price_update for token #{String.slice(token_id, 0..20)}... | price=#{inspect(price_data[:price])} bid=#{inspect(price_data[:best_bid])} ask=#{inspect(price_data[:best_ask])}"
    )

    # Batch price update - will be merged on flush
    existing = Map.get(socket.assigns.batch_price_updates, token_id, %{})

    best_bid = price_data[:best_bid] || existing[:best_bid]
    best_ask = price_data[:best_ask] || existing[:best_ask]

    # Use trade price if available, otherwise use best_bid
    # Trade price is from actual executed trades (most accurate)
    price = price_data[:price] || existing[:price]

    updated_data =
      Map.merge(existing, %{
        price: price,
        best_bid: best_bid,
        best_ask: best_ask,
        market_question: price_data[:market_question] || existing[:market_question],
        outcome: price_data[:outcome] || existing[:outcome],
        updated_at: price_data[:updated_at] || System.system_time(:millisecond)
      })

    batch_price_updates = Map.put(socket.assigns.batch_price_updates, token_id, updated_data)
    {:noreply, assign(socket, :batch_price_updates, batch_price_updates)}
  end

  @impl true
  def handle_info({:paper_order, order_data}, socket) do
    # Batch paper order for next UI flush
    batch_paper_orders = [order_data | socket.assigns.batch_paper_orders]
    {:noreply, assign(socket, :batch_paper_orders, batch_paper_orders)}
  end

  @impl true
  def handle_info(:flush_ui_batch, socket) do
    # Apply all batched updates in a single render cycle
    socket = flush_batched_updates(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:discovered_tokens, token_ids, tokens_with_metadata}, socket) do
    require Logger
    Logger.info("[StrategiesLive] Received #{length(token_ids)} discovered tokens with metadata")

    # Immediately populate with metadata from strategy cache (no API call needed!)
    new_token_data =
      token_ids
      |> Enum.reject(fn token_id -> Map.has_key?(socket.assigns.token_prices, token_id) end)
      |> Enum.map(fn token_id ->
        metadata = Map.get(tokens_with_metadata, token_id, %{})

        {token_id,
         %{
           best_bid: nil,
           best_ask: nil,
           mid: nil,
           market_question: metadata[:market_question] || "Unknown market",
           outcome: metadata[:outcome],
           event_title: metadata[:event_title],
           end_date: metadata[:end_date],
           updated_at: System.system_time(:millisecond)
         }}
      end)
      |> Map.new()

    token_prices = Map.merge(socket.assigns.token_prices, new_token_data)

    # Prices will come from WebSocket - no need to fetch from API!
    {:noreply, assign(socket, :token_prices, token_prices)}
  end

  # Fallback for old message format (backward compatibility)
  @impl true
  def handle_info({:discovered_tokens, token_ids}, socket) do
    require Logger
    Logger.info("[StrategiesLive] Received #{length(token_ids)} discovered tokens (old format)")

    # Old format without metadata - use placeholders and fetch
    new_placeholders =
      token_ids
      |> Enum.reject(fn token_id -> Map.has_key?(socket.assigns.token_prices, token_id) end)
      |> Enum.map(fn token_id ->
        {token_id,
         %{
           best_bid: nil,
           best_ask: nil,
           mid: nil,
           market_question: "Loading...",
           outcome: nil,
           updated_at: System.system_time(:millisecond)
         }}
      end)
      |> Map.new()

    token_prices = Map.merge(socket.assigns.token_prices, new_placeholders)

    # Fetch market info for newly discovered tokens in background
    send(self(), {:fetch_discovered_prices, token_ids})

    {:noreply, assign(socket, :token_prices, token_prices)}
  end

  @impl true
  def handle_info({:fetch_discovered_prices, token_ids}, socket) do
    # Filter out tokens we already have full data for (not just placeholders)
    tokens_to_fetch =
      token_ids
      |> Enum.reject(fn token_id ->
        case Map.get(socket.assigns.token_prices, token_id) do
          %{market_question: question} when question != "Loading..." and not is_nil(question) ->
            true

          _ ->
            false
        end
      end)
      # Fetch in batches to avoid overwhelming the UI - batch size 50
      |> Enum.take(50)

    if tokens_to_fetch == [] do
      {:noreply, socket}
    else
      # Fetch concurrently in background task, send results back incrementally
      lv_pid = self()

      Task.start(fn ->
        tokens_to_fetch
        |> Task.async_stream(
          fn token_id ->
            case Gamma.get_market_by_token(token_id) do
              {:ok, info} ->
                {token_id,
                 %{
                   best_bid: info[:price],
                   best_ask: info[:price],
                   mid: info[:price],
                   market_question: info[:question],
                   event_title: info[:event_title],
                   event_slug: info[:event_slug],
                   condition_id: info[:condition_id],
                   outcome: info[:outcome],
                   end_date: info[:end_date],
                   updated_at: System.system_time(:millisecond)
                 }}

              _ ->
                nil
            end
          end,
          max_concurrency: 20,
          timeout: 10_000,
          on_timeout: :kill_task
        )
        |> Enum.reduce([], fn
          {:ok, {token_id, data}}, acc when not is_nil(data) -> [{token_id, data} | acc]
          _, acc -> acc
        end)
        |> then(fn results ->
          if results != [] do
            send(lv_pid, {:discovered_prices_batch, Map.new(results)})
          end
        end)
      end)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:discovered_prices_batch, new_prices}, socket) do
    token_prices = Map.merge(socket.assigns.token_prices, new_prices)
    {:noreply, assign(socket, :token_prices, token_prices)}
  end

  @impl true
  def handle_info({:fetch_runner_discovered_tokens, strategy_id}, socket) do
    require Logger
    Logger.info("[StrategiesLive] Fetching discovered tokens for strategy #{strategy_id}")

    case Runner.get_discovered_tokens(strategy_id) do
      {:ok, tokens} when tokens != [] ->
        Logger.info(
          "[StrategiesLive] Got #{length(tokens)} discovered tokens - showing immediately"
        )

        # Try to get market cache and prices from Runner state
        {market_cache, prices} =
          try do
            case Runner.get_state(strategy_id) do
              %{market_cache: cache, prices: prices} when is_map(cache) and is_map(prices) ->
                {cache, prices}

              %{market_cache: cache} when is_map(cache) ->
                {cache, %{}}

              _ ->
                {%{}, %{}}
            end
          catch
            :exit, _ -> {%{}, %{}}
          end

        Logger.info(
          "[StrategiesLive] Got #{map_size(market_cache)} cached markets, #{map_size(prices)} prices"
        )

        # Build token data with metadata and prices from cache
        token_list = tokens

        new_token_data =
          token_list
          |> Enum.reject(fn token_id -> Map.has_key?(socket.assigns.token_prices, token_id) end)
          |> Enum.map(fn token_id ->
            metadata = Map.get(market_cache, token_id, %{})
            price_data = Map.get(prices, token_id, %{})

            # Use the Gamma API price (actual market price) for display
            {token_id,
             %{
               price: price_data[:price],
               best_bid: price_data[:best_bid],
               best_ask: price_data[:best_ask],
               market_question: metadata[:question] || metadata[:market_question] || "Loading...",
               event_title: metadata[:event_title],
               outcome: metadata[:outcome],
               end_date: metadata[:end_date],
               updated_at: price_data[:updated_at] || System.system_time(:millisecond)
             }}
          end)
          |> Map.new()

        # Merge with existing token_prices
        token_prices = Map.merge(socket.assigns.token_prices, new_token_data)

        {:noreply, assign(socket, :token_prices, token_prices)}

      {:ok, []} ->
        Logger.info("[StrategiesLive] No discovered tokens yet")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:removed_tokens, token_ids}, socket) do
    # Remove resolved markets from token_prices
    require Logger
    Logger.info("[StrategiesLive] Removing #{length(token_ids)} resolved tokens from UI")
    token_prices = Map.drop(socket.assigns.token_prices, token_ids)
    {:noreply, assign(socket, :token_prices, token_prices)}
  end

  @impl true
  def handle_info({:fetch_initial_prices, token_ids}, socket) do
    # Fetch initial market info (names, outcomes) from Gamma - prices come from WebSocket
    # Limit to first 100 tokens, fetch in batches to avoid rate limits
    tokens_to_fetch = Enum.take(token_ids, 100)

    # Fetch market info in smaller batches with delays
    initial_prices =
      tokens_to_fetch
      |> Enum.chunk_every(10)
      |> Enum.with_index()
      |> Enum.flat_map(fn {batch, idx} ->
        # Small delay between batches to avoid rate limits
        if idx > 0, do: Process.sleep(100)

        batch
        |> Enum.map(fn token_id ->
          case Gamma.get_market_by_token(token_id) do
            {:ok, info} ->
              {token_id,
               %{
                 best_bid: info[:price],
                 best_ask: info[:price],
                 mid: info[:price],
                 market_question: info[:question],
                 event_title: info[:event_title],
                 event_slug: info[:event_slug],
                 condition_id: info[:condition_id],
                 outcome: info[:outcome],
                 updated_at: System.system_time(:millisecond)
               }}

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
      end)
      |> Map.new()

    {:noreply, assign(socket, :token_prices, initial_prices)}
  end

  @impl true
  def handle_info({:strategy_crashed, %{reason: reason}}, socket) do
    require Logger
    Logger.warning("[StrategiesLive] Strategy crashed: #{reason}")

    # Show flash notification to user
    socket =
      put_flash(
        socket,
        :error,
        "Strategy crashed (auto-restarting): #{String.slice(reason, 0..100)}"
      )

    # Refresh strategy status after a short delay to show "running" after restart
    Process.send_after(self(), :refresh_strategies, 2000)

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Batch flush helper functions
  defp flush_batched_updates(socket) do
    socket
    |> flush_price_updates()
    |> flush_signals()
    |> flush_live_orders()
    |> flush_paper_orders()
  end

  defp flush_price_updates(%{assigns: %{batch_price_updates: updates}} = socket)
       when map_size(updates) == 0 do
    socket
  end

  defp flush_price_updates(%{assigns: %{batch_price_updates: updates}} = socket) do
    # Merge batched price updates into existing token_prices
    token_prices =
      Enum.reduce(updates, socket.assigns.token_prices, fn {token_id, new_data}, acc ->
        existing = Map.get(acc, token_id, %{})

        # Use new price if available, otherwise keep existing
        price = new_data[:price] || existing[:price]
        best_bid = new_data[:best_bid] || existing[:best_bid]
        best_ask = new_data[:best_ask] || existing[:best_ask]

        merged =
          Map.merge(existing, %{
            price: price,
            best_bid: best_bid,
            best_ask: best_ask,
            market_question: new_data[:market_question] || existing[:market_question],
            event_title: existing[:event_title],
            event_slug: existing[:event_slug],
            condition_id: existing[:condition_id],
            outcome: new_data[:outcome] || existing[:outcome],
            updated_at: new_data[:updated_at] || existing[:updated_at]
          })

        Map.put(acc, token_id, merged)
      end)

    update_count = map_size(updates)

    socket
    |> assign(:token_prices, token_prices)
    |> assign(:batch_price_updates, %{})
    |> assign(:price_update_count, socket.assigns.price_update_count + update_count)
    |> assign(:last_price_update_at, System.system_time(:millisecond))
  end

  defp flush_signals(%{assigns: %{batch_signals: []}} = socket), do: socket

  defp flush_signals(%{assigns: %{batch_signals: signals}} = socket) do
    # Insert all batched signals into the events stream (reverse to maintain order)
    socket =
      signals
      |> Enum.reverse()
      |> Enum.reduce(socket, fn event, acc ->
        stream_insert(acc, :events, event, at: 0)
      end)

    assign(socket, :batch_signals, [])
  end

  defp flush_live_orders(%{assigns: %{batch_live_orders: []}} = socket), do: socket

  defp flush_live_orders(%{assigns: %{batch_live_orders: orders}} = socket) do
    # Insert all batched live orders (reverse to maintain order)
    socket =
      orders
      |> Enum.reverse()
      |> Enum.reduce(socket, fn order, acc ->
        stream_insert(acc, :live_orders, order, at: 0, limit: 25)
      end)

    assign(socket, :batch_live_orders, [])
  end

  defp flush_paper_orders(%{assigns: %{batch_paper_orders: []}} = socket), do: socket

  defp flush_paper_orders(%{assigns: %{batch_paper_orders: orders}} = socket) do
    # Merge batched paper orders into existing list (keep last 50)
    paper_orders =
      (Enum.reverse(orders) ++ socket.assigns.paper_orders)
      |> Enum.take(50)

    socket
    |> assign(:paper_orders, paper_orders)
    |> assign(:batch_paper_orders, [])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="min-h-screen">
        <%!-- Header Section --%>
        <div class="border-b border-base-300 bg-base-100/80 backdrop-blur-sm sticky top-0 z-10">
          <div class="max-w-7xl mx-auto px-4 py-4">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-4">
                <div class="flex items-center gap-3">
                  <div class="w-10 h-10 rounded-xl bg-gradient-to-br from-secondary to-accent flex items-center justify-center">
                    <.icon name="hero-cpu-chip" class="size-5 text-white" />
                  </div>
                  <div>
                    <h1 class="text-xl font-bold tracking-tight">Trading Strategies</h1>
                    <p class="text-xs text-base-content/50">Automated trading bots</p>
                  </div>
                </div>
              </div>

              <div class="flex items-center gap-3">
                <%!-- Back to Copy Trading --%>
                <.link
                  navigate={~p"/"}
                  class="px-4 py-2.5 rounded-xl bg-base-300/50 hover:bg-base-300 transition-colors text-sm font-medium flex items-center gap-2"
                >
                  <.icon name="hero-arrow-left" class="size-4" /> Copy Trading
                </.link>

                <%!-- Theme Toggle --%>
                <button
                  type="button"
                  id="navbar-theme-toggle"
                  phx-click={JS.dispatch("phx:toggle-theme")}
                  class="p-2.5 rounded-xl bg-base-300/50 hover:bg-base-300 transition-colors"
                  title="Toggle theme"
                >
                  <.icon
                    name="hero-sun"
                    class="size-5 text-warning hidden [[data-theme=dark]_&]:block"
                  />
                  <.icon
                    name="hero-moon"
                    class="size-5 text-primary block [[data-theme=dark]_&]:hidden"
                  />
                </button>
              </div>
            </div>
          </div>
        </div>

        <%!-- Main Content --%>
        <div class="max-w-7xl mx-auto px-4 py-6">
          <div class="grid grid-cols-1 xl:grid-cols-12 gap-6">
            <%!-- Left Column: Strategies List --%>
            <div class="xl:col-span-5 space-y-6">
              <%!-- Strategies Card --%>
              <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
                <div class="px-5 py-4 border-b border-base-300 flex items-center justify-between">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-rectangle-stack" class="size-5 text-secondary" />
                    <h2 class="font-semibold">Strategies</h2>
                    <span class="px-2 py-0.5 rounded-full bg-base-300 text-xs font-medium">
                      {length(@strategies)}
                    </span>
                  </div>
                  <button
                    type="button"
                    phx-click="toggle_new_form"
                    class="px-3 py-1.5 rounded-lg bg-primary/10 text-primary text-sm font-medium hover:bg-primary hover:text-primary-content transition-colors flex items-center gap-1"
                  >
                    <.icon name="hero-plus" class="size-4" /> New
                  </button>
                </div>

                <%!-- New Strategy Form --%>
                <div :if={@show_new_form} class="p-5 border-b border-base-300 bg-base-100/50">
                  <form phx-submit="create_strategy" class="space-y-4">
                    <div>
                      <label class="block text-xs font-medium text-base-content/60 mb-2">
                        Strategy Type
                      </label>
                      <div class="grid grid-cols-2 gap-2">
                        <button
                          :for={{type, name, desc} <- Behaviour.available_types()}
                          type="button"
                          phx-click="select_type"
                          phx-value-type={type}
                          class={[
                            "p-3 rounded-xl border text-left transition-all",
                            @new_strategy_type == type && "border-primary bg-primary/5",
                            @new_strategy_type != type &&
                              "border-base-300 hover:border-base-content/20"
                          ]}
                        >
                          <p class="text-sm font-medium">{name}</p>
                          <p class="text-xs text-base-content/50 mt-0.5">{desc}</p>
                        </button>
                      </div>
                    </div>
                    <div>
                      <label class="block text-xs font-medium text-base-content/60 mb-1">
                        Name (optional)
                      </label>
                      <input
                        type="text"
                        name="name"
                        value={@new_strategy_name}
                        phx-change="update_name"
                        placeholder={Behaviour.display_name(@new_strategy_type)}
                        class="w-full px-3 py-2 rounded-lg bg-base-100 border border-base-300 text-sm placeholder:text-base-content/40 focus:outline-none focus:ring-2 focus:ring-primary/20 focus:border-primary"
                      />
                    </div>
                    <div class="flex gap-2">
                      <button
                        type="submit"
                        class="flex-1 px-4 py-2 rounded-lg bg-primary text-primary-content font-medium text-sm hover:bg-primary/90 transition-colors"
                      >
                        Create Strategy
                      </button>
                      <button
                        type="button"
                        phx-click="toggle_new_form"
                        class="px-4 py-2 rounded-lg bg-base-300 text-base-content font-medium text-sm hover:bg-base-300/80 transition-colors"
                      >
                        Cancel
                      </button>
                    </div>
                  </form>
                </div>

                <div class="p-5">
                  <%!-- Empty State --%>
                  <div
                    :if={@strategies == []}
                    class="py-12 text-center"
                  >
                    <div class="w-16 h-16 rounded-2xl bg-base-300/50 flex items-center justify-center mx-auto mb-4">
                      <.icon name="hero-cpu-chip" class="size-8 text-base-content/30" />
                    </div>
                    <p class="text-base-content/50 font-medium">No strategies yet</p>
                    <p class="text-sm text-base-content/40 mt-1">
                      Create a strategy to start automated trading
                    </p>
                  </div>

                  <%!-- Strategies List --%>
                  <div class="space-y-2">
                    <div
                      :for={strategy <- @strategies}
                      class={[
                        "group flex items-center justify-between p-3 rounded-xl border transition-colors cursor-pointer",
                        @selected_strategy && @selected_strategy.strategy.id == strategy.id &&
                          "bg-primary/5 border-primary/30",
                        (!@selected_strategy || @selected_strategy.strategy.id != strategy.id) &&
                          "bg-base-100 border-base-300/50 hover:border-base-300"
                      ]}
                      phx-click="select_strategy"
                      phx-value-id={strategy.id}
                    >
                      <div class="flex items-center gap-3">
                        <div class={[
                          "w-10 h-10 rounded-xl flex items-center justify-center",
                          status_bg_class(strategy.status)
                        ]}>
                          <.icon name={strategy_icon(strategy.type)} class="size-5" />
                        </div>
                        <div>
                          <p class="font-medium text-sm">{strategy.name}</p>
                          <p class="text-xs text-base-content/50">
                            {Behaviour.display_name(strategy.type)}
                          </p>
                        </div>
                      </div>
                      <div class="flex items-center gap-2">
                        <span
                          :if={strategy.paper_mode}
                          class="px-2 py-0.5 rounded text-xs font-medium bg-warning/10 text-warning"
                          title="Paper trading mode - no real orders"
                        >
                          PAPER
                        </span>
                        <span
                          :if={!strategy.paper_mode}
                          class="px-2 py-0.5 rounded text-xs font-medium bg-error/10 text-error"
                          title="Live trading mode - real orders"
                        >
                          LIVE
                        </span>
                        <span class={[
                          "px-2 py-0.5 rounded text-xs font-medium",
                          status_badge_class(strategy.status)
                        ]}>
                          {status_display(strategy.status)}
                        </span>
                        <%!-- Live/Paused Toggle --%>
                        <button
                          type="button"
                          phx-click="toggle_live"
                          phx-value-id={strategy.id}
                          class={[
                            "relative inline-flex h-6 w-10 items-center rounded-full transition-colors",
                            strategy.status == "running" && "bg-success",
                            strategy.status != "running" && "bg-base-300"
                          ]}
                          title={
                            if strategy.status == "running",
                              do: "Pause strategy",
                              else: "Start strategy"
                          }
                        >
                          <span class={[
                            "inline-block h-4 w-4 transform rounded-full bg-white transition-transform shadow-sm",
                            strategy.status == "running" && "translate-x-5",
                            strategy.status != "running" && "translate-x-1"
                          ]} />
                        </button>
                        <button
                          type="button"
                          phx-click="delete_strategy"
                          phx-value-id={strategy.id}
                          data-confirm="Delete this strategy? This cannot be undone."
                          class="p-1.5 rounded-lg text-error hover:bg-error/10 transition-colors opacity-0 group-hover:opacity-100"
                          title="Delete"
                        >
                          <.icon name="hero-trash" class="size-4" />
                        </button>
                      </div>
                    </div>
                  </div>
                </div>
              </div>

              <%!-- Strategy Types Info --%>
              <div class="rounded-2xl bg-gradient-to-br from-secondary/5 to-accent/5 border border-secondary/10 p-5">
                <div class="flex items-start gap-3">
                  <div class="w-8 h-8 rounded-lg bg-secondary/10 flex items-center justify-center shrink-0">
                    <.icon name="hero-light-bulb" class="size-4 text-secondary" />
                  </div>
                  <div>
                    <p class="text-sm font-medium">Time Decay Strategy</p>
                    <p class="text-xs text-base-content/60 mt-2">
                      Captures the final price movement near event resolution.
                    </p>
                    <ul class="text-xs text-base-content/60 mt-2 space-y-1">
                      <li>
                        <strong>High price</strong> - When bid &gt; 80%, place order at 99¢
                      </li>
                      <li>
                        <strong>Low price</strong> - When bid &lt; 20%, place order at 1¢
                      </li>
                      <li>
                        <strong>Win condition</strong> - Market resolves to 0 or 100%
                      </li>
                    </ul>
                  </div>
                </div>
              </div>

              <%!-- Strategy Signals --%>
              <div
                :if={@selected_strategy && @selected_strategy.strategy.status == "running"}
                class="rounded-2xl bg-base-200/50 border border-success/30 overflow-hidden"
              >
                <div class="px-5 py-4 border-b border-success/20 bg-success/5">
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-2">
                      <.icon name="hero-bolt-solid" class="size-5 text-success" />
                      <h2 class="font-semibold">Strategy Signals</h2>
                      <span class="px-2 py-0.5 rounded-full bg-success/10 text-success text-xs font-medium">
                        {(@selected_strategy.strategy.paper_mode && "PAPER") || "LIVE"}
                      </span>
                    </div>
                    <p class="text-xs text-base-content/50">Orders triggered by strategy</p>
                  </div>
                </div>

                <div
                  id="live-orders-feed"
                  phx-update="stream"
                  class="divide-y divide-base-300/50 max-h-[350px] overflow-y-auto font-mono text-xs"
                >
                  <div
                    id="live-orders-empty"
                    class="hidden only:block py-8 text-center"
                  >
                    <div class="w-12 h-12 rounded-xl bg-success/10 flex items-center justify-center mx-auto mb-3">
                      <.icon name="hero-bolt" class="size-6 text-success/50" />
                    </div>
                    <p class="text-base-content/50 text-sm font-sans">No signals yet</p>
                    <p class="text-base-content/40 text-xs mt-1 font-sans">
                      Signals appear when price reaches 0.99 or 0.01
                    </p>
                  </div>

                  <div
                    :for={{id, live_order} <- @streams.live_orders}
                    id={id}
                    class="px-4 py-3 bg-success/5 border-l-2 border-success transition-colors"
                  >
                    <div class="flex items-start justify-between gap-3">
                      <div class="flex-1 min-w-0">
                        <%!-- Event/Market Title --%>
                        <div class="flex items-center gap-2 mb-1">
                          <span class={[
                            "px-1.5 py-0.5 rounded text-[10px] font-semibold shrink-0",
                            order_event_class(live_order.order[:event_type])
                          ]}>
                            {String.upcase(live_order.order[:event_type] || "order")}
                          </span>
                          <%= if live_order.order[:outcome] do %>
                            <span class={[
                              "px-1.5 py-0.5 rounded text-[10px] font-semibold",
                              outcome_class(live_order.order[:outcome])
                            ]}>
                              {live_order.order[:outcome]}
                            </span>
                          <% end %>
                        </div>

                        <%!-- Market Question or Event Title --%>
                        <p class="text-sm text-base-content/80 truncate leading-tight">
                          {live_order.order[:market_question] || live_order.order[:event_title] ||
                            short_token_id(
                              live_order.order[:asset_id] || live_order.order["asset_id"]
                            )}
                        </p>

                        <%!-- Trade Details --%>
                        <div class="flex items-center gap-3 mt-1.5 text-xs">
                          <%= if live_order.order[:side] || live_order.order["side"] do %>
                            <span class={[
                              "font-semibold",
                              order_side_class(live_order.order[:side] || live_order.order["side"])
                            ]}>
                              {live_order.order[:side] || live_order.order["side"]}
                            </span>
                          <% end %>
                          <%= if live_order.order[:price] || live_order.order["price"] do %>
                            <span class="text-base-content/60">
                              <span class="text-base-content/40">Price:</span>
                              <span class="font-medium text-base-content/80">
                                {format_price_percent(
                                  live_order.order[:price] || live_order.order["price"]
                                )}
                              </span>
                            </span>
                          <% end %>
                          <%= if live_order.order[:size] || live_order.order["size"] do %>
                            <span class="text-base-content/60">
                              <span class="text-base-content/40">Size:</span>
                              <span class="font-medium text-base-content/80">
                                ${format_size(live_order.order[:size] || live_order.order["size"])}
                              </span>
                            </span>
                          <% end %>
                          <%= if live_order.order[:best_bid] && live_order.order[:best_ask] do %>
                            <span class="text-base-content/40">
                              Spread: {format_price_percent(live_order.order[:best_bid])}/{format_price_percent(
                                live_order.order[:best_ask]
                              )}
                            </span>
                          <% end %>
                        </div>
                      </div>
                      <div class="flex flex-col items-end gap-1 shrink-0">
                        <span class="px-2 py-1 rounded-lg bg-success/10 text-success text-[10px] font-semibold flex items-center gap-1">
                          <.icon name="hero-bolt-solid" class="size-3" /> SIGNAL
                        </span>
                        <span class="text-base-content/30 text-[10px]">
                          {format_time(live_order.timestamp)}
                        </span>
                      </div>
                    </div>
                    <%= if live_order.signals do %>
                      <div class="mt-2 pl-2 border-l border-success/30">
                        <div
                          :for={signal <- live_order.signals}
                          class="text-success text-[11px] font-mono"
                        >
                          {signal.action |> to_string() |> String.upcase()}: {if signal[:metadata][
                                                                                   :shares
                                                                                 ],
                                                                                 do:
                                                                                   "#{signal.metadata.shares} shares",
                                                                                 else:
                                                                                   "$#{Float.round(signal.size, 2)}"} @ {Float.round(
                            signal.price * 100,
                            1
                          )}¢
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>

              <%!-- Watched Tokens - Current Prices --%>
              <div
                :if={@selected_strategy && @selected_strategy.strategy.status == "running"}
                class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden"
              >
                <div class="px-4 py-3 border-b border-base-300">
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-2">
                      <.icon name="hero-eye" class="size-4 text-info" />
                      <h3 class="font-medium text-sm">Watched Tokens</h3>
                      <span class="px-1.5 py-0.5 rounded-full bg-info/10 text-info text-[10px] font-medium">
                        {map_size(@token_prices)}
                      </span>
                    </div>
                    <div class="flex items-center gap-3">
                      <%!-- Price Update Counter --%>
                      <%= if @price_update_count > 0 do %>
                        <div class="flex items-center gap-1.5">
                          <.icon name="hero-arrow-path" class="size-3 text-success/60" />
                          <span class="text-[9px] text-base-content/50">
                            {format_number(@price_update_count)} updates
                          </span>
                        </div>
                      <% end %>
                      <%!-- Last Update Time --%>
                      <%= if @last_price_update_at do %>
                        <div class="flex items-center gap-1.5">
                          <div class={[
                            "w-1.5 h-1.5 rounded-full bg-success",
                            if(
                              System.system_time(:millisecond) - @last_price_update_at < 1000,
                              do: "animate-pulse",
                              else: ""
                            )
                          ]}>
                          </div>
                          <span class="text-[9px] text-base-content/40 font-mono">
                            {format_time_ago(@last_price_update_at)}
                          </span>
                        </div>
                      <% else %>
                        <div class="flex items-center gap-1.5">
                          <div class="w-1.5 h-1.5 rounded-full bg-success animate-pulse"></div>
                          <span class="text-[9px] text-base-content/40">Live</span>
                        </div>
                      <% end %>
                      <div class="flex items-center gap-1.5">
                        <span class="text-[10px] text-base-content/50">Signal @</span>
                        <span class="px-2 py-0.5 rounded-full bg-warning/10 text-warning text-[10px] font-mono font-semibold">
                          {format_percent(
                            @selected_strategy.strategy.config["signal_threshold"] || 0.8
                          )}
                        </span>
                      </div>
                    </div>
                  </div>
                </div>

                <div class="p-2 max-h-[500px] overflow-y-auto">
                  <%= if map_size(@token_prices) == 0 do %>
                    <div class="py-6 text-center">
                      <span class="loading loading-spinner loading-sm text-primary"></span>
                      <p class="text-base-content/50 text-xs mt-2">Discovering markets...</p>
                    </div>
                  <% else %>
                    <div class="space-y-1">
                      <div
                        :for={
                          {token_id, price_data} <-
                            sort_by_target_proximity(
                              @token_prices,
                              @selected_strategy.strategy.config
                            )
                        }
                        id={"token-#{token_id}"}
                        data-token-id={token_id}
                        phx-hook="PriceFlash"
                        class={[
                          "p-2 rounded-lg border text-xs transition-colors duration-200",
                          price_row_class(price_data[:best_bid], @selected_strategy.strategy.config)
                        ]}
                      >
                        <div class="flex items-center justify-between gap-2">
                          <div class="flex-1 min-w-0">
                            <a
                              href={polymarket_url(price_data)}
                              target="_blank"
                              class="font-medium truncate text-xs hover:text-primary group/link flex items-center gap-1"
                            >
                              <span class="truncate group-hover/link:underline">
                                {price_data[:event_title] || price_data[:market_question] ||
                                  short_token_id(token_id)}
                              </span>
                              <.icon
                                name="hero-arrow-top-right-on-square"
                                class="size-3 shrink-0 opacity-50 group-hover/link:opacity-100"
                              />
                            </a>
                            <div class="flex items-center gap-1 mt-0.5">
                              <span
                                :if={price_data[:outcome]}
                                class={[
                                  "px-1 py-0.5 rounded text-[9px] font-semibold",
                                  outcome_class(price_data[:outcome])
                                ]}
                              >
                                {price_data[:outcome]}
                              </span>
                            </div>
                          </div>
                          <div class="text-right shrink-0">
                            <p class="font-mono font-semibold text-sm">
                              {format_price_percent(price_data[:price] || price_data[:best_bid])}
                            </p>
                            <p class={[
                              "text-[9px] font-semibold mt-0.5",
                              price_status_text_class(
                                price_data[:best_bid],
                                @selected_strategy.strategy.config
                              )
                            ]}>
                              {price_status_label(
                                price_data[:best_bid],
                                @selected_strategy.strategy.config
                              )}
                            </p>
                            <%= if price_data[:updated_at] do %>
                              <p class="text-[8px] text-base-content/30 mt-0.5">
                                {format_time_ago(price_data[:updated_at])}
                              </p>
                            <% end %>
                          </div>
                        </div>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>

            <%!-- Right Column: Strategy Details --%>
            <div class="xl:col-span-7 space-y-6">
              <%= if @selected_strategy do %>
                <%!-- Strategy Details Card --%>
                <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
                  <div class="px-5 py-4 border-b border-base-300 flex items-center justify-between">
                    <div class="flex items-center gap-3">
                      <div class={[
                        "w-10 h-10 rounded-xl flex items-center justify-center",
                        status_bg_class(@selected_strategy.strategy.status)
                      ]}>
                        <.icon
                          name={strategy_icon(@selected_strategy.strategy.type)}
                          class="size-5"
                        />
                      </div>
                      <div>
                        <h2 class="font-semibold">{@selected_strategy.strategy.name}</h2>
                        <p class="text-xs text-base-content/50">
                          {Behaviour.display_name(@selected_strategy.strategy.type)}
                        </p>
                      </div>
                    </div>
                    <button
                      type="button"
                      phx-click="close_details"
                      class="p-2 rounded-lg text-base-content/50 hover:text-base-content hover:bg-base-300 transition-colors"
                    >
                      <.icon name="hero-x-mark" class="size-5" />
                    </button>
                  </div>

                  <div class="p-5 space-y-6">
                    <%!-- Stats Grid --%>
                    <div class="grid grid-cols-3 gap-4">
                      <div class="p-4 rounded-xl bg-base-100 border border-base-300">
                        <p class="text-xs text-base-content/50">Total Trades</p>
                        <p class="text-2xl font-bold mt-1">
                          {@selected_strategy.stats.total_trades}
                        </p>
                      </div>
                      <div class="p-4 rounded-xl bg-base-100 border border-base-300">
                        <p class="text-xs text-base-content/50">Filled</p>
                        <p class="text-2xl font-bold mt-1">
                          {@selected_strategy.stats.filled_trades}
                        </p>
                      </div>
                      <div class="p-4 rounded-xl bg-base-100 border border-base-300">
                        <p class="text-xs text-base-content/50">Total PnL</p>
                        <p class={[
                          "text-2xl font-bold mt-1",
                          Decimal.compare(@selected_strategy.stats.total_pnl, 0) == :gt &&
                            "text-success",
                          Decimal.compare(@selected_strategy.stats.total_pnl, 0) == :lt &&
                            "text-error"
                        ]}>
                          ${Decimal.to_string(@selected_strategy.stats.total_pnl)}
                        </p>
                      </div>
                    </div>

                    <%!-- Configuration --%>
                    <div>
                      <div class="flex items-center justify-between mb-3">
                        <h3 class="text-sm font-medium">Configuration</h3>
                        <button
                          :if={!@editing_config}
                          type="button"
                          phx-click="edit_config"
                          class="px-2 py-1 rounded-lg text-xs font-medium text-primary hover:bg-primary/10 transition-colors flex items-center gap-1"
                        >
                          <.icon name="hero-pencil" class="size-3" /> Edit
                        </button>
                      </div>

                      <%!-- View Mode - Simplified config display --%>
                      <div
                        :if={!@editing_config}
                        class="p-4 rounded-xl bg-base-100 border border-base-300"
                      >
                        <div class="space-y-3 text-sm">
                          <div class="grid grid-cols-2 gap-3">
                            <div class="flex justify-between items-center">
                              <span class="text-base-content/60">Signal Threshold</span>
                              <span class="font-medium w-20 text-right">
                                {format_percent(
                                  @selected_strategy.strategy.config["signal_threshold"] || 0.8
                                )}
                              </span>
                            </div>
                            <div class="flex justify-between items-center">
                              <span class="text-base-content/60">Order Size</span>
                              <span class="font-medium w-20 text-right">
                                {@selected_strategy.strategy.config["order_size"] || 10} shares
                              </span>
                            </div>
                            <div class="flex justify-between items-center">
                              <span class="text-base-content/60">Min Minutes</span>
                              <span class="font-medium w-20 text-right">
                                {@selected_strategy.strategy.config["min_minutes"] || 1}
                              </span>
                            </div>
                            <div class="flex justify-between items-center">
                              <span class="text-base-content/60">Cooldown</span>
                              <span class="font-medium w-20 text-right">
                                {@selected_strategy.strategy.config["cooldown_seconds"] || 60}s
                              </span>
                            </div>
                            <div class={[
                              "flex justify-between items-center",
                              @selected_strategy.strategy.config["use_limit_order"] == false &&
                                "col-span-2"
                            ]}>
                              <span class="text-base-content/60">Order Type</span>
                              <span class={[
                                "font-medium w-20 text-right px-2 py-1 rounded",
                                @selected_strategy.strategy.config["use_limit_order"] != false &&
                                  "bg-primary/10 text-primary",
                                @selected_strategy.strategy.config["use_limit_order"] == false &&
                                  "bg-success/10 text-success"
                              ]}>
                                <%= if @selected_strategy.strategy.config["use_limit_order"] != false do %>
                                  Limit
                                <% else %>
                                  Market
                                <% end %>
                              </span>
                            </div>
                            <div
                              :if={@selected_strategy.strategy.config["use_limit_order"] != false}
                              class="flex justify-between items-center"
                            >
                              <span class="text-base-content/60">Limit Price</span>
                              <span class="font-medium font-mono w-20 text-right">
                                {format_price_precise(
                                  @selected_strategy.strategy.config["limit_price"] || 0.99
                                )}
                              </span>
                            </div>
                          </div>
                          <%!-- Strategy Behavior Summary --%>
                          <div class="mt-3 pt-3 border-t border-base-300">
                            <p class="text-xs text-base-content/70 leading-relaxed">
                              <span class="font-semibold text-base-content">Strategy:</span>
                              When price reaches
                              <span class="font-mono font-semibold text-warning">
                                {format_percent(
                                  @selected_strategy.strategy.config["signal_threshold"] || 0.8
                                )}
                              </span>
                              (within
                              <span class="font-semibold">
                                {@selected_strategy.strategy.config["min_minutes"] || 1} min
                              </span>
                              of resolution),
                              <%= if @selected_strategy.strategy.config["use_limit_order"] != false do %>
                                place limit order for
                                <span class="font-semibold text-primary">
                                  {@selected_strategy.strategy.config["order_size"] || 10} shares
                                </span>
                                @
                                <span class="font-mono font-semibold text-primary">
                                  {format_price_precise(
                                    @selected_strategy.strategy.config["limit_price"] || 0.99
                                  )}
                                </span>
                              <% else %>
                                buy
                                <span class="font-semibold text-success">
                                  {@selected_strategy.strategy.config["order_size"] || 10} shares
                                </span>
                                at market price
                              <% end %>
                            </p>
                          </div>
                        </div>
                      </div>

                      <%!-- Edit Mode - Compact inline form matching view style --%>
                      <.form
                        :if={@editing_config}
                        for={@config_form}
                        phx-change="validate_config"
                        phx-submit="save_config"
                        id="strategy-config-form"
                        class="p-4 rounded-xl bg-base-100 border border-primary/30"
                      >
                        <div class="space-y-3 text-sm">
                          <div class="grid grid-cols-2 gap-3">
                            <%!-- Signal Threshold --%>
                            <div class="flex justify-between items-center">
                              <span class="text-base-content/60">Signal Threshold</span>
                              <input
                                type="number"
                                name={@config_form[:signal_threshold].name}
                                value={Phoenix.HTML.Form.input_value(@config_form, :signal_threshold)}
                                step="0.01"
                                min="0.50"
                                max="0.99"
                                class="w-20 px-2 py-1 text-right font-medium rounded border border-base-300 bg-base-200 focus:border-primary focus:outline-none text-sm"
                              />
                            </div>
                            <%!-- Order Size --%>
                            <div class="flex justify-between items-center">
                              <span class="text-base-content/60">Order Size</span>
                              <input
                                type="number"
                                name={@config_form[:order_size].name}
                                value={Phoenix.HTML.Form.input_value(@config_form, :order_size)}
                                step="1"
                                min="1"
                                class="w-20 px-2 py-1 text-right font-medium rounded border border-base-300 bg-base-200 focus:border-primary focus:outline-none text-sm"
                              />
                            </div>
                            <%!-- Min Minutes --%>
                            <div class="flex justify-between items-center">
                              <span class="text-base-content/60">Min Minutes</span>
                              <input
                                type="number"
                                name={@config_form[:min_minutes].name}
                                value={Phoenix.HTML.Form.input_value(@config_form, :min_minutes)}
                                step="0.5"
                                min="0"
                                class="w-20 px-2 py-1 text-right font-medium rounded border border-base-300 bg-base-200 focus:border-primary focus:outline-none text-sm"
                              />
                            </div>
                            <%!-- Cooldown --%>
                            <div class="flex justify-between items-center">
                              <span class="text-base-content/60">Cooldown (s)</span>
                              <input
                                type="number"
                                name={@config_form[:cooldown_seconds].name}
                                value={Phoenix.HTML.Form.input_value(@config_form, :cooldown_seconds)}
                                step="1"
                                min="0"
                                class="w-20 px-2 py-1 text-right font-medium rounded border border-base-300 bg-base-200 focus:border-primary focus:outline-none text-sm"
                              />
                            </div>
                            <%!-- Use Limit Order --%>
                            <div class="flex justify-between items-center">
                              <span class="text-base-content/60">Order Type</span>
                              <div class="flex items-center gap-2">
                                <label class="flex items-center gap-1.5 cursor-pointer">
                                  <input
                                    type="radio"
                                    name={@config_form[:use_limit_order].name}
                                    value="false"
                                    checked={
                                      !Phoenix.HTML.Form.input_value(@config_form, :use_limit_order)
                                    }
                                    class="radio radio-primary radio-sm"
                                  />
                                  <span class="text-xs">Market</span>
                                </label>
                                <label class="flex items-center gap-1.5 cursor-pointer">
                                  <input
                                    type="radio"
                                    name={@config_form[:use_limit_order].name}
                                    value="true"
                                    checked={
                                      Phoenix.HTML.Form.input_value(@config_form, :use_limit_order)
                                    }
                                    class="radio radio-primary radio-sm"
                                  />
                                  <span class="text-xs">Limit</span>
                                </label>
                              </div>
                            </div>
                            <%!-- Limit Price (shown when limit order enabled) --%>
                            <div
                              :if={Phoenix.HTML.Form.input_value(@config_form, :use_limit_order)}
                              class="flex justify-between items-center"
                            >
                              <span class="text-base-content/60">Limit Price</span>
                              <input
                                type="number"
                                name={@config_form[:limit_price].name}
                                value={Phoenix.HTML.Form.input_value(@config_form, :limit_price)}
                                step="0.0001"
                                min="0.90"
                                max="1.0"
                                class="w-24 px-2 py-1 text-right font-mono font-medium rounded border border-base-300 bg-base-200 focus:border-primary focus:outline-none text-sm"
                              />
                            </div>
                          </div>
                          <%!-- Actions --%>
                          <div class="flex gap-2 pt-3 border-t border-base-300">
                            <button
                              type="submit"
                              class="flex-1 px-3 py-1.5 rounded-lg bg-primary text-primary-content font-medium text-xs hover:bg-primary/90 transition-colors"
                            >
                              Save
                            </button>
                            <button
                              type="button"
                              phx-click="cancel_edit_config"
                              class="px-3 py-1.5 rounded-lg bg-base-300 text-base-content font-medium text-xs hover:bg-base-300/80 transition-colors"
                            >
                              Cancel
                            </button>
                          </div>
                        </div>
                      </.form>
                    </div>

                    <%!-- Trading Mode Toggle (Paper/Live) --%>
                    <div>
                      <h3 class="text-sm font-medium mb-3">Trading Mode</h3>
                      <div class={[
                        "p-4 rounded-xl border",
                        @selected_strategy.strategy.paper_mode && "bg-base-100 border-base-300",
                        !@selected_strategy.strategy.paper_mode && "bg-error/5 border-error/30"
                      ]}>
                        <div class="flex items-center justify-between">
                          <div>
                            <p class="text-sm font-medium">
                              {if @selected_strategy.strategy.paper_mode,
                                do: "Paper Trading",
                                else: "Live Trading"}
                            </p>
                            <p class="text-xs text-base-content/50 mt-0.5">
                              {if @selected_strategy.strategy.paper_mode,
                                do: "Simulated orders - no real money",
                                else: "Real orders on Polymarket"}
                            </p>
                          </div>
                          <button
                            type="button"
                            phx-click="toggle_paper_mode"
                            phx-value-id={@selected_strategy.strategy.id}
                            class={[
                              "relative inline-flex h-7 w-12 items-center rounded-full transition-colors",
                              @selected_strategy.strategy.paper_mode && "bg-warning",
                              !@selected_strategy.strategy.paper_mode && "bg-error"
                            ]}
                          >
                            <span class={[
                              "inline-block h-5 w-5 transform rounded-full bg-white transition-transform shadow-sm",
                              @selected_strategy.strategy.paper_mode && "translate-x-1",
                              !@selected_strategy.strategy.paper_mode && "translate-x-6"
                            ]} />
                          </button>
                        </div>
                        <div
                          :if={!@selected_strategy.strategy.paper_mode}
                          class="mt-3 p-2 rounded-lg bg-error/10 border border-error/20"
                        >
                          <p class="text-xs text-error flex items-center gap-1">
                            <.icon name="hero-exclamation-triangle" class="size-3" />
                            Live mode will place real orders on Polymarket
                          </p>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>

                <%!-- Strategy Orders (Paper & Live) --%>
                <div
                  :if={@selected_strategy.strategy.status == "running"}
                  class={[
                    "rounded-2xl bg-base-200/50 overflow-hidden",
                    @selected_strategy.strategy.paper_mode && "border border-warning/30",
                    !@selected_strategy.strategy.paper_mode && "border border-error/30"
                  ]}
                >
                  <div class={[
                    "px-5 py-4 border-b",
                    @selected_strategy.strategy.paper_mode && "border-warning/20 bg-warning/5",
                    !@selected_strategy.strategy.paper_mode && "border-error/20 bg-error/5"
                  ]}>
                    <div class="flex items-center justify-between">
                      <div class="flex items-center gap-2">
                        <.icon
                          name={
                            if @selected_strategy.strategy.paper_mode,
                              do: "hero-document-text",
                              else: "hero-bolt-solid"
                          }
                          class={
                            if @selected_strategy.strategy.paper_mode,
                              do: "size-5 text-warning",
                              else: "size-5 text-error"
                          }
                        />
                        <h2 class="font-semibold">
                          {if @selected_strategy.strategy.paper_mode,
                            do: "Paper Orders",
                            else: "Live Orders"}
                        </h2>
                        <span class={[
                          "px-2 py-0.5 rounded-full text-xs font-medium",
                          @selected_strategy.strategy.paper_mode && "bg-warning/10 text-warning",
                          !@selected_strategy.strategy.paper_mode && "bg-error/10 text-error"
                        ]}>
                          {if @selected_strategy.strategy.paper_mode,
                            do: "SIMULATED",
                            else: "REAL MONEY"}
                        </span>
                      </div>
                      <div class="flex items-center gap-3">
                        <p class="text-xs text-base-content/50">{length(@paper_orders)} orders</p>
                        <%= if @paper_orders != [] do %>
                          <button
                            phx-click="clear_trades"
                            data-confirm="Delete all trades for this strategy?"
                            class="text-xs text-error/70 hover:text-error transition-colors"
                          >
                            Clear all
                          </button>
                        <% end %>
                      </div>
                    </div>
                  </div>

                  <div class="divide-y divide-base-300/50 max-h-[300px] overflow-y-auto">
                    <%= if @paper_orders == [] do %>
                      <div class="py-8 text-center">
                        <div class={[
                          "w-12 h-12 rounded-xl flex items-center justify-center mx-auto mb-3",
                          @selected_strategy.strategy.paper_mode && "bg-warning/10",
                          !@selected_strategy.strategy.paper_mode && "bg-error/10"
                        ]}>
                          <.icon
                            name={
                              if @selected_strategy.strategy.paper_mode,
                                do: "hero-clipboard-document-list",
                                else: "hero-bolt"
                            }
                            class={
                              if @selected_strategy.strategy.paper_mode,
                                do: "size-6 text-warning/50",
                                else: "size-6 text-error/50"
                            }
                          />
                        </div>
                        <p class="text-base-content/50 text-sm">
                          No {if @selected_strategy.strategy.paper_mode, do: "paper", else: "live"} orders yet
                        </p>
                        <p class="text-base-content/40 text-xs mt-1">
                          Orders will appear when strategy triggers
                        </p>
                      </div>
                    <% else %>
                      <div
                        :for={order <- @paper_orders}
                        class="px-4 py-3 hover:bg-base-100/50 transition-colors"
                      >
                        <div class="flex items-start justify-between gap-3">
                          <div class="flex-1 min-w-0">
                            <div class="flex items-center gap-2 mb-1">
                              <span class={[
                                "px-1.5 py-0.5 rounded text-[10px] font-semibold",
                                order.action == :buy && "bg-success/20 text-success",
                                order.action == :sell && "bg-error/20 text-error"
                              ]}>
                                {order.action |> to_string() |> String.upcase()}
                              </span>
                              <span class={[
                                "px-1.5 py-0.5 rounded text-[10px] font-semibold",
                                order[:paper_mode] != false && "bg-warning/20 text-warning",
                                order[:paper_mode] == false && "bg-error/20 text-error"
                              ]}>
                                {if order[:paper_mode] != false, do: "PAPER", else: "LIVE"}
                              </span>
                            </div>
                            <p class="text-sm text-base-content/80">
                              {order.metadata[:market_question] || order.reason}
                            </p>
                            <div class="flex items-center gap-3 mt-1 text-xs">
                              <span class="text-base-content/60">
                                <span class="text-base-content/40">Price:</span>
                                <span class="font-medium font-mono">
                                  {format_price_precise(order.price)}
                                </span>
                              </span>
                              <span class="text-base-content/60">
                                <span class="text-base-content/40">Shares:</span>
                                <span class="font-medium">
                                  {format_order_shares(order)}
                                </span>
                              </span>
                              <span class="text-base-content/40 font-mono text-[10px]">
                                {short_token_id(order.token_id)}
                              </span>
                            </div>
                          </div>
                          <div class="flex flex-col items-end gap-1 shrink-0">
                            <span class={[
                              "px-2 py-0.5 rounded text-[10px] font-semibold",
                              order.status == :filled && "bg-success/10 text-success",
                              order.status == :submitted && "bg-info/10 text-info",
                              order.status == :pending && "bg-warning/10 text-warning",
                              order.status == :cancelled && "bg-base-300 text-base-content/50"
                            ]}>
                              {order.status |> to_string() |> String.upcase()}
                            </span>
                            <span class="text-base-content/30 text-[10px]">
                              {format_time(order.placed_at)}
                            </span>
                          </div>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>

                <%!-- Events Log --%>
                <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
                  <div class="px-5 py-4 border-b border-base-300">
                    <div class="flex items-center justify-between">
                      <div class="flex items-center gap-2">
                        <.icon name="hero-document-text" class="size-5 text-info" />
                        <h2 class="font-semibold">Activity Log</h2>
                      </div>
                      <button
                        type="button"
                        phx-click="clear_activity_log"
                        class="text-xs text-base-content/50 hover:text-base-content transition-colors"
                      >
                        Clear
                      </button>
                    </div>
                  </div>

                  <div
                    id="events-log"
                    phx-update="stream"
                    class="divide-y divide-base-300/50 max-h-[400px] overflow-y-auto"
                  >
                    <div
                      id="events-empty"
                      class="hidden only:block py-12 text-center"
                    >
                      <div class="w-16 h-16 rounded-2xl bg-base-300/50 flex items-center justify-center mx-auto mb-4">
                        <.icon name="hero-document-text" class="size-8 text-base-content/30" />
                      </div>
                      <p class="text-base-content/50 font-medium">No events yet</p>
                      <p class="text-sm text-base-content/40 mt-1">
                        Events will appear when the strategy is running
                      </p>
                    </div>

                    <div
                      :for={{id, event} <- @streams.events}
                      id={id}
                      class="flex items-start gap-3 px-5 py-3"
                    >
                      <div class={[
                        "w-8 h-8 rounded-lg flex items-center justify-center shrink-0",
                        event_type_class(event.type)
                      ]}>
                        <.icon name={event_type_icon(event.type)} class="size-4" />
                      </div>
                      <div class="flex-1 min-w-0">
                        <p class="text-sm">{event.message}</p>
                        <p class="text-xs text-base-content/40 mt-0.5">
                          {format_datetime(event.inserted_at)}
                        </p>
                      </div>
                    </div>
                  </div>
                </div>
              <% else %>
                <%!-- No Selection Placeholder --%>
                <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
                  <div class="py-20 text-center">
                    <div class="w-20 h-20 rounded-2xl bg-base-300/50 flex items-center justify-center mx-auto mb-4">
                      <.icon name="hero-cursor-arrow-rays" class="size-10 text-base-content/30" />
                    </div>
                    <p class="text-base-content/50 font-medium">Select a strategy</p>
                    <p class="text-sm text-base-content/40 mt-1">
                      Click on a strategy to view details and controls
                    </p>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Market Browser Modal --%>
        <div
          :if={@show_market_browser}
          id="market-browser-backdrop"
          class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/50 backdrop-blur-sm"
        >
          <div
            id="market-browser-modal"
            class="w-full max-w-4xl max-h-[85vh] rounded-2xl bg-base-100 border border-base-300 shadow-2xl flex flex-col"
            phx-click-away="close_market_browser"
          >
            <%!-- Header --%>
            <div class="px-6 py-4 border-b border-base-300 flex items-center justify-between shrink-0">
              <div class="flex items-center gap-3">
                <div class="w-10 h-10 rounded-xl bg-secondary/10 flex items-center justify-center">
                  <.icon name="hero-globe-alt" class="size-5 text-secondary" />
                </div>
                <div>
                  <h2 class="font-semibold text-lg">Browse Markets</h2>
                  <p class="text-xs text-base-content/50">
                    Select events to track with this strategy
                  </p>
                </div>
              </div>
              <button
                type="button"
                phx-click="close_market_browser"
                class="p-2 rounded-lg text-base-content/50 hover:text-base-content hover:bg-base-300 transition-colors"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </button>
            </div>

            <%!-- Search Bar --%>
            <div class="px-6 py-3 border-b border-base-300 shrink-0">
              <form phx-change="market_search" phx-submit="market_search" id="market-search-form">
                <div class="relative">
                  <.icon
                    name="hero-magnifying-glass"
                    class="size-4 absolute left-3 top-1/2 -translate-y-1/2 text-base-content/40"
                  />
                  <input
                    type="text"
                    name="search"
                    value={@market_search}
                    placeholder="Search markets (e.g., bitcoin, trump, election...)"
                    phx-debounce="300"
                    autocomplete="off"
                    class="w-full pl-10 pr-4 py-2.5 rounded-xl bg-base-200 border border-base-300 text-sm placeholder:text-base-content/40 focus:outline-none focus:ring-2 focus:ring-secondary/20 focus:border-secondary"
                  />
                  <div :if={@market_loading} class="absolute right-3 top-1/2 -translate-y-1/2">
                    <span class="loading loading-spinner loading-sm text-secondary"></span>
                  </div>
                </div>
              </form>

              <%!-- Category Filters --%>
              <div class="flex flex-wrap gap-2 mt-3">
                <button
                  :for={cat <- @market_categories}
                  type="button"
                  phx-click="select_category"
                  phx-value-category-id={cat.id}
                  class={[
                    "px-3 py-1.5 rounded-lg text-xs font-medium transition-all",
                    @selected_category == cat.id && "bg-secondary text-secondary-content",
                    @selected_category != cat.id &&
                      "bg-base-200 text-base-content/70 hover:bg-base-300"
                  ]}
                >
                  {cat.label}
                </button>
              </div>

              <div class="flex items-center justify-between mt-2 text-xs text-base-content/50">
                <span>{length(@selected_tokens)} token(s) selected</span>
                <span>{length(@market_events)} events found</span>
              </div>
            </div>

            <%!-- Events List --%>
            <div class="flex-1 overflow-y-auto p-4 space-y-3">
              <div :if={@market_loading and @market_events == []} class="py-12 text-center">
                <span class="loading loading-spinner loading-lg text-secondary"></span>
                <p class="text-base-content/50 mt-4">Loading markets...</p>
              </div>

              <div :if={!@market_loading and @market_events == []} class="py-12 text-center">
                <div class="w-16 h-16 rounded-2xl bg-base-300/50 flex items-center justify-center mx-auto mb-4">
                  <.icon name="hero-globe-alt" class="size-8 text-base-content/30" />
                </div>
                <p class="text-base-content/50 font-medium">No markets found</p>
                <p class="text-sm text-base-content/40 mt-1">Try a different search term</p>
              </div>

              <div
                :for={event <- @market_events}
                class={[
                  "rounded-xl border p-4 transition-all cursor-pointer",
                  event_selected?(@selected_tokens, event) && "border-secondary bg-secondary/5",
                  !event_selected?(@selected_tokens, event) &&
                    "border-base-300 hover:border-base-content/20"
                ]}
                phx-click="toggle_event_tokens"
                phx-value-event-id={event.id}
              >
                <div class="flex items-start gap-4">
                  <div class="w-12 h-12 rounded-lg bg-base-300 overflow-hidden shrink-0">
                    <%= if event.image do %>
                      <img src={event.image} alt="" class="w-full h-full object-cover" />
                    <% else %>
                      <div class="w-full h-full flex items-center justify-center">
                        <.icon name="hero-chart-bar" class="size-6 text-base-content/30" />
                      </div>
                    <% end %>
                  </div>
                  <div class="flex-1 min-w-0">
                    <div class="flex items-start justify-between gap-2">
                      <h3 class="font-medium text-sm leading-tight">{event.title}</h3>
                      <div class={[
                        "w-5 h-5 rounded-md border-2 flex items-center justify-center shrink-0",
                        event_selected?(@selected_tokens, event) && "border-secondary bg-secondary",
                        !event_selected?(@selected_tokens, event) && "border-base-300"
                      ]}>
                        <.icon
                          :if={event_selected?(@selected_tokens, event)}
                          name="hero-check"
                          class="size-3 text-white"
                        />
                      </div>
                    </div>
                    <div class="flex flex-wrap items-center gap-2 mt-2">
                      <span class="text-xs text-base-content/50">
                        ${format_volume(event.volume_24h)} 24h vol
                      </span>
                      <span class="text-xs text-base-content/40">•</span>
                      <span class="text-xs text-base-content/50">
                        {length(event.markets)} market(s)
                      </span>
                      <span
                        :for={tag <- Enum.take(event.tags, 2)}
                        class="px-2 py-0.5 rounded bg-base-300 text-xs"
                      >
                        {tag.label}
                      </span>
                    </div>
                    <%!-- Markets within event (collapsible) --%>
                    <div :if={length(event.markets) > 1} class="mt-3">
                      <button
                        type="button"
                        phx-click="toggle_event_expand"
                        phx-value-event-id={event.id}
                        class="flex items-center gap-1 text-xs text-base-content/60 hover:text-base-content transition-colors mb-2"
                      >
                        <.icon
                          name={
                            if(MapSet.member?(@expanded_events, event.id),
                              do: "hero-chevron-down",
                              else: "hero-chevron-right"
                            )
                          }
                          class="size-3"
                        />
                        <span>
                          <%= if MapSet.member?(@expanded_events, event.id) do %>
                            Hide {length(event.markets)} markets
                          <% else %>
                            Show {length(event.markets)} markets
                          <% end %>
                        </span>
                      </button>
                      <div
                        :if={MapSet.member?(@expanded_events, event.id)}
                        class="space-y-1"
                      >
                        <div
                          :for={market <- event.markets}
                          class="flex items-center justify-between text-xs p-2 rounded-lg bg-base-200/50"
                          phx-click="toggle_market_token"
                          phx-value-token-id={Enum.at(market.token_ids, 0)}
                        >
                          <span class="truncate flex-1">{market.question}</span>
                          <div class="flex items-center gap-2 shrink-0 ml-2">
                            <div :for={outcome <- market.outcomes} class="flex items-center gap-1">
                              <span class={[
                                "font-medium",
                                outcome.name == "Yes" && "text-success",
                                outcome.name == "No" && "text-error"
                              ]}>
                                {outcome.name}: {Float.round(outcome.price * 100, 1)}%
                              </span>
                            </div>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>

              <%!-- Load More Button --%>
              <div
                :if={@market_has_more and @market_events != [] and @market_search == ""}
                class="py-4 text-center"
              >
                <button
                  type="button"
                  phx-click="load_more_markets"
                  disabled={@market_loading}
                  class="px-6 py-2 rounded-xl bg-base-300 text-base-content font-medium text-sm hover:bg-base-300/80 transition-colors disabled:opacity-50"
                >
                  <%= if @market_loading do %>
                    <span class="loading loading-spinner loading-sm"></span> Loading...
                  <% else %>
                    Load More Events
                  <% end %>
                </button>
              </div>
            </div>

            <%!-- Footer --%>
            <div class="px-6 py-4 border-t border-base-300 flex items-center justify-between shrink-0">
              <button
                type="button"
                phx-click="close_market_browser"
                class="px-4 py-2 rounded-xl bg-base-300 text-base-content font-medium text-sm hover:bg-base-300/80 transition-colors"
              >
                Cancel
              </button>
              <button
                type="button"
                phx-click="apply_market_selection"
                class="px-6 py-2 rounded-xl bg-secondary text-secondary-content font-medium text-sm hover:bg-secondary/90 transition-colors flex items-center gap-2"
              >
                <.icon name="hero-check" class="size-4" />
                Apply Selection ({length(@selected_tokens)} tokens)
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Helper functions

  defp refresh_strategies(socket, id, action) do
    # Small delay to let the process start/stop
    Process.sleep(50)

    strategies = Strategies.list_strategies() |> enrich_with_running_state()

    selected =
      if socket.assigns.selected_strategy &&
           socket.assigns.selected_strategy.strategy.id == id do
        updated = Strategies.get_strategy!(id)
        [enriched] = enrich_with_running_state([updated])
        stats = Strategies.get_strategy_stats(id)
        %{strategy: enriched, stats: stats}
      else
        socket.assigns.selected_strategy
      end

    {:noreply,
     socket
     |> assign(:strategies, strategies)
     |> assign(:selected_strategy, selected)
     |> stream(:live_orders, [], reset: true)
     |> put_flash(:info, "Strategy #{action}")}
  end

  # Enrich strategies with actual running state from Registry
  # The Registry is the source of truth - DB status can be stale
  defp enrich_with_running_state(strategies) do
    Enum.map(strategies, fn strategy ->
      actual_status = if Engine.running?(strategy.id), do: "running", else: "stopped"
      %{strategy | status: actual_status}
    end)
  end

  defp status_bg_class("running"), do: "bg-success/10 text-success"
  defp status_bg_class("paused"), do: "bg-warning/10 text-warning"
  defp status_bg_class("error"), do: "bg-error/10 text-error"
  defp status_bg_class(_), do: "bg-base-300 text-base-content/50"

  defp status_badge_class("running"), do: "bg-success/10 text-success"
  defp status_badge_class("paused"), do: "bg-warning/10 text-warning"
  defp status_badge_class("error"), do: "bg-error/10 text-error"
  defp status_badge_class(_), do: "bg-base-300 text-base-content/50"

  defp status_display("running"), do: "LIVE"
  defp status_display("paused"), do: "PAUSED"
  defp status_display("stopped"), do: "OFF"
  defp status_display("error"), do: "ERROR"
  defp status_display(other), do: String.upcase(other)

  defp strategy_icon("time_decay"), do: "hero-clock"
  defp strategy_icon(_), do: "hero-cpu-chip"

  defp event_type_class("info"), do: "bg-info/10 text-info"
  defp event_type_class("signal"), do: "bg-secondary/10 text-secondary"
  defp event_type_class("trade"), do: "bg-success/10 text-success"
  defp event_type_class("error"), do: "bg-error/10 text-error"
  defp event_type_class(_), do: "bg-base-300 text-base-content/50"

  defp event_type_icon("info"), do: "hero-information-circle"
  defp event_type_icon("signal"), do: "hero-bolt"
  defp event_type_icon("trade"), do: "hero-banknotes"
  defp event_type_icon("error"), do: "hero-exclamation-triangle"
  defp event_type_icon(_), do: "hero-document"

  defp format_percent(value) when is_number(value), do: "#{round(value * 100)}%"
  defp format_percent(_), do: "—"

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_datetime(_), do: ""

  # Live orders helpers
  defp order_event_class("price_change"), do: "bg-info/20 text-info"
  defp order_event_class("trade"), do: "bg-success/20 text-success"
  defp order_event_class("placement"), do: "bg-warning/20 text-warning"
  defp order_event_class(_), do: "bg-base-300 text-base-content/60"

  defp order_side_class(side) when side in ["BUY", "buy", :buy], do: "text-success"
  defp order_side_class(side) when side in ["SELL", "sell", :sell], do: "text-error"
  defp order_side_class(_), do: "text-base-content/60"

  defp polymarket_url(%{event_slug: slug}) when is_binary(slug) and slug != "" do
    "https://polymarket.com/event/#{slug}"
  end

  defp polymarket_url(%{condition_id: cid}) when is_binary(cid) and cid != "" do
    "https://polymarket.com/event?id=#{cid}"
  end

  defp polymarket_url(_), do: "https://polymarket.com"

  defp short_token_id(nil), do: "unknown"

  defp short_token_id(token_id) when is_binary(token_id) do
    if String.length(token_id) > 16 do
      String.slice(token_id, 0, 8) <> "..." <> String.slice(token_id, -6, 6)
    else
      token_id
    end
  end

  # Format price as percentage (prices are 0-1, display as 0-100%)
  defp format_price_percent(price) when is_number(price) do
    "#{Float.round(price * 100, 1)}¢"
  end

  defp format_price_percent(price) when is_binary(price) do
    case Float.parse(price) do
      {val, _} -> "#{Float.round(val * 100, 1)}¢"
      :error -> price
    end
  end

  defp format_price_percent(_), do: "-"

  # Format price with high precision (4 decimal places)
  defp format_price_precise(price) when is_number(price),
    do: :erlang.float_to_binary(price * 1.0, decimals: 4)

  defp format_price_precise(_), do: "-"

  # Format shares - use pre-calculated from metadata if available
  defp format_order_shares(%{metadata: %{shares: shares}}) when is_integer(shares) do
    to_string(shares)
  end

  defp format_order_shares(%{metadata: %{shares: shares}}) when is_float(shares) do
    Float.round(shares, 1) |> to_string()
  end

  defp format_order_shares(%{size: size, price: price})
       when is_number(size) and is_number(price) and price > 0 do
    shares = size / price
    Float.round(shares, 1) |> to_string()
  end

  defp format_order_shares(_), do: "-"

  # Outcome styling (Yes/No)
  defp outcome_class("Yes"), do: "bg-success/20 text-success"
  defp outcome_class("No"), do: "bg-error/20 text-error"
  defp outcome_class(_), do: "bg-base-300 text-base-content/60"

  defp format_size(size) when is_number(size), do: Float.round(size * 1.0, 2)

  defp format_size(size) when is_binary(size) do
    case Float.parse(size) do
      {val, _} -> Float.round(val, 2)
      :error -> size
    end
  end

  defp format_size(_), do: "-"

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(_), do: ""

  defp format_time_ago(timestamp_ms) when is_integer(timestamp_ms) do
    now = System.system_time(:millisecond)
    diff_ms = now - timestamp_ms
    diff_sec = div(diff_ms, 1000)

    cond do
      diff_sec < 5 -> "now"
      diff_sec < 60 -> "#{diff_sec}s"
      diff_sec < 3600 -> "#{div(diff_sec, 60)}m"
      true -> "#{div(diff_sec, 3600)}h"
    end
  end

  defp format_time_ago(_), do: ""

  defp format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(_), do: "0"

  # Convert a Trade struct to the paper_order format expected by the UI
  defp trade_to_paper_order(%Polyx.Trades.Trade{} = trade) do
    %{
      id: trade.id,
      token_id: trade.asset_id,
      action: side_to_action(trade.side),
      price: decimal_to_float(trade.price),
      size: decimal_to_float(trade.size),
      reason: trade.title,
      status: String.to_existing_atom(trade.status),
      paper_mode: trade.order_id && String.starts_with?(trade.order_id || "", "paper_"),
      order_id: trade.order_id,
      placed_at: trade.inserted_at,
      metadata: %{
        market_question: trade.title,
        outcome: trade.outcome
      }
    }
  end

  defp side_to_action("BUY"), do: :buy
  defp side_to_action("SELL"), do: :sell
  defp side_to_action(_), do: :buy

  defp decimal_to_float(nil), do: 0.0
  defp decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_float(n) when is_number(n), do: n * 1.0

  # Market browser helpers
  defp event_selected?(selected_tokens, event) do
    Enum.any?(event.token_ids, &(&1 in selected_tokens))
  end

  defp format_volume(volume) when is_number(volume) do
    cond do
      volume >= 1_000_000 -> "#{Float.round(volume / 1_000_000, 1)}M"
      volume >= 1_000 -> "#{Float.round(volume / 1_000, 1)}K"
      true -> "#{Float.round(volume * 1.0, 0)}"
    end
  end

  defp format_volume(_), do: "0"

  # Sort tokens by absolute distance from current price to target price
  # |target - current| - smaller distance = closer to filling = higher priority
  # Limit to top 100 tokens to avoid rendering performance issues
  defp sort_by_target_proximity(token_prices, config) do
    high_threshold = config["signal_threshold"] || config["high_threshold"] || 0.80
    low_threshold = 0.20
    target_high = config["limit_price"] || config["target_high_price"] || 0.99
    target_low = 0.01

    token_prices
    |> Enum.sort_by(fn {_token_id, price_data} ->
      price = price_data[:best_bid] || price_data[:mid] || 0.5

      cond do
        # In high target zone - distance to target_high (e.g., 0.99)
        price > high_threshold ->
          abs(target_high - price)

        # In low target zone - distance to target_low (e.g., 0.01)
        price < low_threshold ->
          abs(target_low - price)

        # Not in target zone - use distance to nearest threshold (will be sorted last)
        true ->
          # Add 1.0 to push these to the bottom of the list
          distance_to_high = high_threshold - price
          distance_to_low = price - low_threshold
          1.0 + min(distance_to_high, distance_to_low)
      end
    end)
    |> Enum.take(100)
  end

  # Price status helpers for Time Decay strategy
  defp price_row_class(price, config) when is_number(price) do
    high_threshold = config["signal_threshold"] || config["high_threshold"] || 0.80

    cond do
      price > high_threshold -> "bg-success/10 border-success/30"
      price < 0.20 -> "bg-error/10 border-error/30"
      true -> "bg-base-100 border-base-300"
    end
  end

  defp price_row_class(_, _), do: "bg-base-100 border-base-300"

  defp price_status_text_class(price, config) when is_number(price) do
    high_threshold = config["signal_threshold"] || config["high_threshold"] || 0.80

    cond do
      price > high_threshold -> "text-success"
      price < 0.20 -> "text-error"
      true -> "text-base-content/40"
    end
  end

  defp price_status_text_class(_, _), do: "text-base-content/40"

  defp price_status_label(price, config) when is_number(price) do
    signal_threshold = config["signal_threshold"] || config["high_threshold"] || 0.80
    use_limit = config["use_limit_order"] != false
    limit_price = config["limit_price"] || config["target_high_price"] || 0.99

    cond do
      price >= signal_threshold && use_limit ->
        "SIGNAL → BUY @ #{Float.round(limit_price * 100, 0)}¢"

      price >= signal_threshold && !use_limit ->
        "SIGNAL → BUY @ MARKET"

      true ->
        "WAIT (signal @ #{Float.round(signal_threshold * 100, 0)}¢)"
    end
  end

  defp price_status_label(_, _), do: "N/A"
end
