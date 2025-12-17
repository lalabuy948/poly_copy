defmodule PolyxWeb.StrategiesLive do
  @moduledoc """
  LiveView for managing trading strategies.

  Simplified architecture:
  - Registry is source of truth for running state
  - No auto-recovery (supervision handles that)
  - Direct price updates (no batching)
  - No market browser
  """
  use PolyxWeb, :live_view

  alias Polyx.Strategies
  alias Polyx.Strategies.{Engine, Runner, Behaviour, Config}

  require Logger

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Polyx.PubSub, "strategies:updates")
      :timer.send_interval(30_000, self(), :refresh_strategies)
    end

    strategies = Strategies.list_strategies() |> enrich_with_running_state()
    selected = maybe_select_strategy(strategies, params["strategy_id"])

    socket =
      socket
      |> assign(:page_title, "Trading Strategies")
      |> assign(:strategies, strategies)
      |> assign(:selected_strategy, selected)
      |> assign(:show_new_form, false)
      |> assign(:new_strategy_type, "time_decay")
      |> assign(:new_strategy_name, "")
      |> assign(:editing_config, false)
      |> assign(:config_form, nil)
      |> assign(:token_prices, %{})
      |> assign(:paper_orders, [])
      |> stream(:events, [])
      |> stream(:live_orders, [])

    socket =
      if selected do
        subscribe_to_strategy(socket, selected.strategy.id)
      else
        socket
      end

    {:ok, socket}
  end

  # Subscribe to a strategy's updates and load its data
  defp subscribe_to_strategy(socket, strategy_id) do
    Phoenix.PubSub.subscribe(Polyx.PubSub, "strategies:#{strategy_id}")

    # Load existing trades
    trades = Strategies.list_trades(strategy_id, limit: 50)
    paper_orders = Enum.map(trades, &trade_to_paper_order/1)

    # Load discovered tokens directly from runner (if running)
    # Runner now returns cached WebSocket prices in the response
    token_prices =
      if Engine.running?(strategy_id) do
        case Runner.get_discovered_tokens_with_info(strategy_id) do
          {:ok, tokens_map} when map_size(tokens_map) > 0 ->
            # Convert to UI format - prices come from Runner's WebSocket cache
            Enum.reduce(tokens_map, %{}, fn {token_id, info}, acc ->
              Map.put(acc, token_id, %{
                best_bid: info[:best_bid],
                best_ask: info[:best_ask],
                mid: calculate_mid(info[:best_bid], info[:best_ask]),
                market_question: info[:market_question] || "Loading...",
                event_title: info[:event_title],
                outcome: info[:outcome],
                end_date: info[:end_date]
              })
            end)

          _ ->
            # No tokens yet - schedule retry
            Process.send_after(self(), {:fetch_discovered_tokens, strategy_id}, 2_000)
            %{}
        end
      else
        %{}
      end

    socket
    |> assign(:paper_orders, paper_orders)
    |> assign(:token_prices, token_prices)
    |> assign(:discovery_retries, 0)
  end

  # Auto-select strategy from URL param
  defp maybe_select_strategy(_strategies, nil), do: nil

  defp maybe_select_strategy(strategies, strategy_id_param) do
    strategy_id = String.to_integer(strategy_id_param)
    strategy = Enum.find(strategies, &(&1.id == strategy_id))

    if strategy do
      %{strategy: strategy, stats: Strategies.get_strategy_stats(strategy.id)}
    else
      nil
    end
  end

  # Events

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

    result =
      if is_running do
        Engine.stop_strategy(id)
      else
        Engine.start_strategy(id)
      end

    case result do
      {:ok, _pid} ->
        strategies = Strategies.list_strategies() |> enrich_with_running_state()
        action = if is_running, do: "stopped", else: "started"

        socket =
          socket
          |> assign(:strategies, strategies)
          |> update_selected_strategy(id)
          |> put_flash(:info, "Strategy #{action}")

        # If starting, reset state and fetch discovered tokens
        socket =
          if not is_running do
            send(self(), {:fetch_discovered_tokens, id})

            socket
            |> assign(:token_prices, %{})
            |> assign(:discovery_retries, 0)
          else
            socket
          end

        {:noreply, socket}

      :ok ->
        strategies = Strategies.list_strategies() |> enrich_with_running_state()

        {:noreply,
         socket
         |> assign(:strategies, strategies)
         |> update_selected_strategy(id)
         |> put_flash(:info, "Strategy stopped")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("delete_strategy", %{"id" => id}, socket) do
    id = String.to_integer(id)
    strategy = Strategies.get_strategy!(id)

    Engine.stop_strategy(id)

    case Strategies.delete_strategy(strategy) do
      {:ok, _} ->
        strategies = Enum.reject(socket.assigns.strategies, &(&1.id == id))

        selected =
          if socket.assigns.selected_strategy &&
               socket.assigns.selected_strategy.strategy.id == id do
            nil
          else
            socket.assigns.selected_strategy
          end

        {:noreply,
         socket
         |> assign(:strategies, strategies)
         |> assign(:selected_strategy, selected)
         |> put_flash(:info, "Strategy deleted")}

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

    # Unsubscribe from previous
    if socket.assigns.selected_strategy do
      Phoenix.PubSub.unsubscribe(
        Polyx.PubSub,
        "strategies:#{socket.assigns.selected_strategy.strategy.id}"
      )
    end

    # Subscribe to new
    Phoenix.PubSub.subscribe(Polyx.PubSub, "strategies:#{id}")

    # Enrich with actual running state
    is_running = Engine.running?(id)
    enriched = %{strategy | status: if(is_running, do: "running", else: "stopped")}

    # Load trades
    trades = Strategies.list_trades(id, limit: 50)
    paper_orders = Enum.map(trades, &trade_to_paper_order/1)

    # Request discovered tokens if running
    if is_running do
      send(self(), {:fetch_discovered_tokens, id})
    end

    {:noreply,
     socket
     |> assign(:selected_strategy, %{strategy: enriched, stats: stats})
     |> assign(:token_prices, %{})
     |> assign(:discovery_retries, 0)
     |> assign(:paper_orders, paper_orders)
     |> stream(:events, events, reset: true)
     |> stream(:live_orders, [], reset: true)
     |> push_patch(to: ~p"/strategies/#{id}")}
  end

  @impl true
  def handle_event("close_details", _params, socket) do
    if socket.assigns.selected_strategy do
      Phoenix.PubSub.unsubscribe(
        Polyx.PubSub,
        "strategies:#{socket.assigns.selected_strategy.strategy.id}"
      )
    end

    {:noreply,
     socket
     |> assign(:selected_strategy, nil)
     |> push_patch(to: ~p"/strategies")}
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
      updated_config = Ecto.Changeset.apply_changes(changeset)
      new_config_map = Config.to_map(updated_config)

      case Strategies.update_strategy(strategy, %{config: new_config_map}) do
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

  # Message handlers

  @impl true
  def handle_info(:refresh_strategies, socket) do
    strategies = Strategies.list_strategies() |> enrich_with_running_state()

    selected =
      if socket.assigns.selected_strategy do
        id = socket.assigns.selected_strategy.strategy.id
        updated = Enum.find(strategies, &(&1.id == id))

        if updated do
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
  def handle_info({:fetch_discovered_tokens, strategy_id}, socket) do
    case Runner.get_discovered_tokens_with_info(strategy_id) do
      {:ok, tokens_map} when map_size(tokens_map) > 0 ->
        # Convert to UI format - prices come from Runner's WebSocket cache
        token_prices =
          Enum.reduce(tokens_map, %{}, fn {token_id, info}, acc ->
            Map.put(acc, token_id, %{
              best_bid: info[:best_bid],
              best_ask: info[:best_ask],
              mid: calculate_mid(info[:best_bid], info[:best_ask]),
              market_question: info[:market_question] || "Loading...",
              event_title: info[:event_title],
              outcome: info[:outcome],
              end_date: info[:end_date]
            })
          end)

        {:noreply, assign(socket, :token_prices, token_prices)}

      _ ->
        # No tokens yet, retry in 2 seconds (max 10 retries)
        retries = socket.assigns[:discovery_retries] || 0

        if retries < 10 do
          Process.send_after(self(), {:fetch_discovered_tokens, strategy_id}, 2_000)
          {:noreply, assign(socket, :discovery_retries, retries + 1)}
        else
          {:noreply, assign(socket, :token_prices, :no_markets)}
        end
    end
  end

  @impl true
  def handle_info({:discovered_tokens, tokens_with_info}, socket) do
    current_prices =
      if is_map(socket.assigns.token_prices), do: socket.assigns.token_prices, else: %{}

    # Add new tokens with whatever info we have - prices come via WebSocket
    new_prices =
      Enum.reduce(tokens_with_info, %{}, fn item, acc ->
        case item do
          {token_id, info} when is_map(info) ->
            Map.put(acc, token_id, %{
              best_bid: info[:best_bid],
              best_ask: info[:best_ask],
              mid: calculate_mid(info[:best_bid], info[:best_ask]),
              market_question: info[:market_question] || "Loading...",
              event_title: info[:event_title],
              outcome: info[:outcome],
              end_date: info[:end_date]
            })

          token_id when is_binary(token_id) ->
            Map.put(acc, token_id, %{
              best_bid: nil,
              best_ask: nil,
              mid: nil,
              market_question: "Loading...",
              outcome: nil
            })

          _ ->
            acc
        end
      end)

    {:noreply, assign(socket, :token_prices, Map.merge(current_prices, new_prices))}
  end

  @impl true
  def handle_info({:removed_tokens, token_ids}, socket) do
    current = if is_map(socket.assigns.token_prices), do: socket.assigns.token_prices, else: %{}
    {:noreply, assign(socket, :token_prices, Map.drop(current, token_ids))}
  end

  @impl true
  def handle_info({:price_update, token_id, price_data}, socket) do
    current = if is_map(socket.assigns.token_prices), do: socket.assigns.token_prices, else: %{}

    if Map.has_key?(current, token_id) do
      existing = Map.get(current, token_id, %{})

      updated =
        Map.merge(existing, %{
          best_bid: price_data.best_bid || existing[:best_bid],
          best_ask: price_data.best_ask || existing[:best_ask],
          mid: calculate_mid(price_data.best_bid, price_data.best_ask) || existing[:mid],
          market_question: price_data[:market_question] || existing[:market_question],
          outcome: price_data[:outcome] || existing[:outcome]
        })

      {:noreply, assign(socket, :token_prices, Map.put(current, token_id, updated))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:signal, signal}, socket) do
    event = %{
      id: System.unique_integer([:positive]),
      type: "signal",
      message: signal.reason,
      metadata: signal,
      inserted_at: DateTime.utc_now()
    }

    {:noreply, stream_insert(socket, :events, event, at: 0)}
  end

  @impl true
  def handle_info({:live_order, order, signals}, socket) do
    if signals != nil and signals != [] do
      live_order = %{
        id: System.unique_integer([:positive]),
        order: order,
        signals: signals,
        triggered: true,
        timestamp: DateTime.utc_now()
      }

      {:noreply, stream_insert(socket, :live_orders, live_order, at: 0, limit: 25)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:paper_order, order_data}, socket) do
    paper_orders = [order_data | socket.assigns.paper_orders] |> Enum.take(50)
    {:noreply, assign(socket, :paper_orders, paper_orders)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_params(%{"strategy_id" => strategy_id}, _uri, socket) do
    strategy_id = String.to_integer(strategy_id)
    current_id = socket.assigns.selected_strategy && socket.assigns.selected_strategy.strategy.id

    if current_id != strategy_id do
      handle_event("select_strategy", %{"id" => strategy_id}, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # Helpers

  defp enrich_with_running_state(strategies) do
    Enum.map(strategies, fn strategy ->
      actual_status = if Engine.running?(strategy.id), do: "running", else: "stopped"
      %{strategy | status: actual_status}
    end)
  end

  defp update_selected_strategy(socket, id) do
    if socket.assigns.selected_strategy &&
         socket.assigns.selected_strategy.strategy.id == id do
      strategy = Strategies.get_strategy!(id)
      [enriched] = enrich_with_running_state([strategy])
      stats = Strategies.get_strategy_stats(id)
      assign(socket, :selected_strategy, %{strategy: enriched, stats: stats})
    else
      socket
    end
  end

  defp calculate_mid(bid, ask) when is_number(bid) and is_number(ask), do: (bid + ask) / 2
  defp calculate_mid(bid, nil) when is_number(bid), do: bid
  defp calculate_mid(nil, ask) when is_number(ask), do: ask
  defp calculate_mid(_, _), do: nil

  defp trade_to_paper_order(%Polyx.Trades.Trade{} = trade) do
    %{
      id: trade.id,
      token_id: trade.asset_id,
      action: if(trade.side == "BUY", do: :buy, else: :sell),
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

  defp decimal_to_float(nil), do: 0.0
  defp decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_float(n) when is_number(n), do: n * 1.0

  # Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="min-h-screen">
        <%!-- Header --%>
        <div class="border-b border-base-300 bg-base-100/80 backdrop-blur-sm sticky top-0 z-10">
          <div class="max-w-7xl mx-auto px-4 py-4">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <div class="w-10 h-10 rounded-xl bg-gradient-to-br from-secondary to-accent flex items-center justify-center">
                  <.icon name="hero-cpu-chip" class="size-5 text-white" />
                </div>
                <div>
                  <h1 class="text-xl font-bold tracking-tight">Trading Strategies</h1>
                  <p class="text-xs text-base-content/50">Automated trading bots</p>
                </div>
              </div>

              <div class="flex items-center gap-3">
                <.link
                  navigate={~p"/"}
                  class="px-4 py-2.5 rounded-xl bg-base-300/50 hover:bg-base-300 transition-colors text-sm font-medium flex items-center gap-2"
                >
                  <.icon name="hero-arrow-left" class="size-4" /> Back
                </.link>
                <button
                  type="button"
                  phx-click={JS.dispatch("phx:toggle-theme")}
                  class="p-2.5 rounded-xl bg-base-300/50 hover:bg-base-300 transition-colors"
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
            <%!-- Left: Strategies List --%>
            <div class="xl:col-span-5 space-y-6">
              <.strategies_list
                strategies={@strategies}
                selected_strategy={@selected_strategy}
                show_new_form={@show_new_form}
                new_strategy_type={@new_strategy_type}
                new_strategy_name={@new_strategy_name}
              />

              <%= if @selected_strategy && @selected_strategy.strategy.status == "running" do %>
                <.live_signals streams={@streams} />
                <.watched_tokens
                  token_prices={@token_prices}
                  config={@selected_strategy.strategy.config}
                />
              <% end %>
            </div>

            <%!-- Right: Strategy Details --%>
            <div class="xl:col-span-7 space-y-6">
              <%= if @selected_strategy do %>
                <.strategy_details
                  selected_strategy={@selected_strategy}
                  editing_config={@editing_config}
                  config_form={@config_form}
                  paper_orders={@paper_orders}
                  streams={@streams}
                />
              <% else %>
                <.no_selection />
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Components

  defp strategies_list(assigns) do
    ~H"""
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
            <label class="block text-xs font-medium text-base-content/60 mb-2">Strategy Type</label>
            <div class="grid grid-cols-2 gap-2">
              <button
                :for={{type, name, desc} <- Behaviour.available_types()}
                type="button"
                phx-click="select_type"
                phx-value-type={type}
                class={[
                  "p-3 rounded-xl border text-left transition-all",
                  @new_strategy_type == type && "border-primary bg-primary/5",
                  @new_strategy_type != type && "border-base-300 hover:border-base-content/20"
                ]}
              >
                <p class="text-sm font-medium">{name}</p>
                <p class="text-xs text-base-content/50 mt-0.5">{desc}</p>
              </button>
            </div>
          </div>
          <div>
            <label class="block text-xs font-medium text-base-content/60 mb-1">Name (optional)</label>
            <input
              type="text"
              name="name"
              value={@new_strategy_name}
              phx-change="update_name"
              placeholder={Behaviour.display_name(@new_strategy_type)}
              class="w-full px-3 py-2 rounded-lg bg-base-100 border border-base-300 text-sm"
            />
          </div>
          <div class="flex gap-2">
            <button
              type="submit"
              class="flex-1 px-4 py-2 rounded-lg bg-primary text-primary-content font-medium text-sm"
            >
              Create Strategy
            </button>
            <button
              type="button"
              phx-click="toggle_new_form"
              class="px-4 py-2 rounded-lg bg-base-300 text-base-content font-medium text-sm"
            >
              Cancel
            </button>
          </div>
        </form>
      </div>

      <div class="p-5">
        <div :if={@strategies == []} class="py-12 text-center">
          <div class="w-16 h-16 rounded-2xl bg-base-300/50 flex items-center justify-center mx-auto mb-4">
            <.icon name="hero-cpu-chip" class="size-8 text-base-content/30" />
          </div>
          <p class="text-base-content/50 font-medium">No strategies yet</p>
        </div>

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
                <p class="text-xs text-base-content/50">{Behaviour.display_name(strategy.type)}</p>
              </div>
            </div>
            <div class="flex items-center gap-2">
              <span
                :if={strategy.paper_mode}
                class="px-2 py-0.5 rounded text-xs font-medium bg-warning/10 text-warning"
              >
                PAPER
              </span>
              <span
                :if={!strategy.paper_mode}
                class="px-2 py-0.5 rounded text-xs font-medium bg-error/10 text-error"
              >
                LIVE
              </span>
              <span class={[
                "px-2 py-0.5 rounded text-xs font-medium",
                status_badge_class(strategy.status)
              ]}>
                {status_display(strategy.status)}
              </span>
              <button
                type="button"
                phx-click="toggle_live"
                phx-value-id={strategy.id}
                class={[
                  "relative inline-flex h-6 w-10 items-center rounded-full transition-colors",
                  strategy.status == "running" && "bg-success",
                  strategy.status != "running" && "bg-base-300"
                ]}
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
                data-confirm="Delete this strategy?"
                class="p-1.5 rounded-lg text-error hover:bg-error/10 transition-colors opacity-0 group-hover:opacity-100"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp live_signals(assigns) do
    ~H"""
    <div class="rounded-2xl bg-base-200/50 border border-success/30 overflow-hidden">
      <div class="px-5 py-4 border-b border-success/20 bg-success/5">
        <div class="flex items-center gap-2">
          <.icon name="hero-bolt-solid" class="size-5 text-success" />
          <h2 class="font-semibold">Strategy Signals</h2>
        </div>
      </div>

      <div
        id="live-orders-feed"
        phx-update="stream"
        class="divide-y divide-base-300/50 max-h-[350px] overflow-y-auto font-mono text-xs"
      >
        <div id="live-orders-empty" class="hidden only:block py-8 text-center">
          <.icon name="hero-bolt" class="size-6 text-success/50 mx-auto" />
          <p class="text-base-content/50 text-sm font-sans mt-2">No signals yet</p>
        </div>

        <div
          :for={{id, live_order} <- @streams.live_orders}
          id={id}
          class="px-4 py-3 bg-success/5 border-l-2 border-success"
        >
          <div class="flex items-start justify-between gap-3">
            <div class="flex-1 min-w-0">
              <p class="text-sm text-base-content/80 truncate">
                {live_order.order[:market_question] || live_order.order[:event_title] || "Signal"}
              </p>
              <div class="flex items-center gap-3 mt-1 text-xs">
                <%= if live_order.order[:side] do %>
                  <span class={order_side_class(live_order.order[:side])}>
                    {live_order.order[:side]}
                  </span>
                <% end %>
                <%= if live_order.order[:price] do %>
                  <span class="text-base-content/60">
                    Price:
                    <span class="font-medium">{format_price_percent(live_order.order[:price])}</span>
                  </span>
                <% end %>
              </div>
            </div>
            <span class="text-base-content/30 text-[10px]">{format_time(live_order.timestamp)}</span>
          </div>
          <%= if live_order.signals do %>
            <div class="mt-2 pl-2 border-l border-success/30">
              <div :for={signal <- live_order.signals} class="text-success text-[11px]">
                <span class="font-semibold">
                  {signal_outcome_label(signal)}
                </span>
                {signal.size} @ {Float.round(signal.price, 4)} - {signal.reason}
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp watched_tokens(assigns) do
    ~H"""
    <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
      <div class="px-4 py-3 border-b border-base-300">
        <div class="flex items-center gap-2">
          <.icon name="hero-eye" class="size-4 text-info" />
          <h3 class="font-medium text-sm">Watched Tokens</h3>
          <span class="px-1.5 py-0.5 rounded-full bg-info/10 text-info text-[10px] font-medium">
            {token_count(@token_prices)}
          </span>
        </div>
      </div>

      <div class="p-2 max-h-[500px] overflow-y-auto">
        <%= cond do %>
          <% @token_prices == :no_markets -> %>
            <div class="py-6 text-center">
              <.icon name="hero-exclamation-circle" class="size-8 text-warning mx-auto" />
              <p class="text-base-content/60 text-xs mt-2">No markets found</p>
            </div>
          <% !is_map(@token_prices) or map_size(@token_prices) == 0 -> %>
            <div class="py-6 text-center">
              <span class="loading loading-spinner loading-sm text-primary"></span>
              <p class="text-base-content/50 text-xs mt-2">Discovering markets...</p>
            </div>
          <% true -> %>
            <div class="space-y-1">
              <div
                :for={{token_id, price_data} <- sort_tokens(@token_prices, @config)}
                id={"token-#{token_id}"}
                class={[
                  "p-2 rounded-lg border text-xs",
                  price_row_class(price_data[:best_bid], @config)
                ]}
              >
                <div class="flex items-center justify-between gap-2">
                  <div class="flex-1 min-w-0">
                    <a
                      href={polymarket_url(price_data)}
                      target="_blank"
                      class="font-medium truncate text-xs hover:text-primary group flex items-center gap-1"
                    >
                      <span class="truncate group-hover:underline">
                        {price_data[:event_title] || price_data[:market_question] ||
                          short_token(token_id)}
                      </span>
                      <.icon name="hero-arrow-top-right-on-square" class="size-3 shrink-0 opacity-50" />
                    </a>
                    <span
                      :if={price_data[:outcome]}
                      class={[
                        "px-1 py-0.5 rounded text-[9px] font-semibold mt-0.5",
                        outcome_class(price_data[:outcome])
                      ]}
                    >
                      {price_data[:outcome]}
                    </span>
                  </div>
                  <div class="text-right shrink-0">
                    <p class="font-mono font-semibold text-sm">
                      {format_price_percent(price_data[:best_bid] || price_data[:mid])}
                    </p>
                    <p class={[
                      "text-[9px] font-semibold mt-0.5",
                      price_status_class(price_data[:best_bid], @config)
                    ]}>
                      {price_status_label(price_data[:best_bid], @config)}
                    </p>
                  </div>
                </div>
              </div>
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp strategy_details(assigns) do
    ~H"""
    <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
      <div class="px-5 py-4 border-b border-base-300 flex items-center justify-between">
        <div class="flex items-center gap-3">
          <div class={[
            "w-10 h-10 rounded-xl flex items-center justify-center",
            status_bg_class(@selected_strategy.strategy.status)
          ]}>
            <.icon name={strategy_icon(@selected_strategy.strategy.type)} class="size-5" />
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
          class="p-2 rounded-lg text-base-content/50 hover:text-base-content hover:bg-base-300"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>

      <div class="p-5 space-y-6">
        <%!-- Stats --%>
        <div class="grid grid-cols-3 gap-4">
          <div class="p-4 rounded-xl bg-base-100 border border-base-300">
            <p class="text-xs text-base-content/50">Total Trades</p>
            <p class="text-2xl font-bold mt-1">{@selected_strategy.stats.total_trades}</p>
          </div>
          <div class="p-4 rounded-xl bg-base-100 border border-base-300">
            <p class="text-xs text-base-content/50">Filled</p>
            <p class="text-2xl font-bold mt-1">{@selected_strategy.stats.filled_trades}</p>
          </div>
          <div class="p-4 rounded-xl bg-base-100 border border-base-300">
            <p class="text-xs text-base-content/50">Total PnL</p>
            <p class={["text-2xl font-bold mt-1", pnl_class(@selected_strategy.stats.total_pnl)]}>
              ${Decimal.to_string(@selected_strategy.stats.total_pnl)}
            </p>
          </div>
        </div>

        <%!-- Config --%>
        <div>
          <div class="flex items-center justify-between mb-3">
            <h3 class="text-sm font-medium">Configuration</h3>
            <button
              :if={!@editing_config}
              type="button"
              phx-click="edit_config"
              class="px-2 py-1 rounded-lg text-xs font-medium text-primary hover:bg-primary/10 flex items-center gap-1"
            >
              <.icon name="hero-pencil" class="size-3" /> Edit
            </button>
          </div>

          <%= if @editing_config do %>
            <.config_form form={@config_form} />
          <% else %>
            <.config_display config={@selected_strategy.strategy.config} />
          <% end %>
        </div>

        <%!-- Paper Mode Toggle --%>
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
                    do: "Simulated orders",
                    else: "Real orders"}
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
          </div>
        </div>
      </div>
    </div>

    <%!-- Orders --%>
    <.orders_list
      paper_orders={@paper_orders}
      paper_mode={@selected_strategy.strategy.paper_mode}
      running={@selected_strategy.strategy.status == "running"}
    />

    <%!-- Events Log --%>
    <.events_log streams={@streams} />
    """
  end

  defp config_display(assigns) do
    ~H"""
    <div class="p-4 rounded-xl bg-base-100 border border-base-300">
      <div class="space-y-3 text-sm">
        <div class="pb-2 border-b border-base-300">
          <span class="text-base-content/60 text-xs">Market Timeframe</span>
          <div class="mt-1">
            <span class="px-3 py-1 rounded-lg bg-primary/10 text-primary font-medium text-sm">
              {timeframe_label(@config["market_timeframe"])}
            </span>
          </div>
        </div>
        <div class="grid grid-cols-2 gap-3">
          <div class="flex justify-between items-center">
            <span class="text-base-content/60">Signal Threshold</span>
            <span class="font-medium">{format_percent(@config["signal_threshold"] || 0.8)}</span>
          </div>
          <div class="flex justify-between items-center">
            <span class="text-base-content/60">Order Size</span>
            <span class="font-medium">${@config["order_size"] || 5}</span>
          </div>
          <div class="flex justify-between items-center">
            <span class="text-base-content/60">Min Minutes</span>
            <span class="font-medium">{@config["min_minutes"] || 1}</span>
          </div>
          <div class="flex justify-between items-center">
            <span class="text-base-content/60">Cooldown</span>
            <span class="font-medium">{@config["cooldown_seconds"] || 60}s</span>
          </div>
        </div>
        <div class="pt-2 border-t border-base-300">
          <div class="flex justify-between items-center">
            <span class="text-base-content/60">Order Type</span>
            <span class={[
              "px-2 py-0.5 rounded text-xs font-semibold",
              @config["use_limit_order"] != false && "bg-info/10 text-info",
              @config["use_limit_order"] == false && "bg-warning/10 text-warning"
            ]}>
              {if @config["use_limit_order"] != false, do: "LIMIT", else: "MARKET"}
            </span>
          </div>
          <div
            :if={@config["use_limit_order"] != false}
            class="flex justify-between items-center mt-2"
          >
            <span class="text-base-content/60">Limit Price</span>
            <span class="font-medium font-mono">
              {format_price_cents(@config["limit_price"] || 0.99)}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp config_form(assigns) do
    ~H"""
    <.form
      for={@form}
      phx-change="validate_config"
      phx-submit="save_config"
      class="p-4 rounded-xl bg-base-100 border border-primary/30"
    >
      <div class="space-y-3 text-sm">
        <div class="pb-3 border-b border-base-300">
          <span class="text-base-content/60 text-xs block mb-2">Market Timeframe</span>
          <div class="grid grid-cols-4 gap-1">
            <label
              :for={{key, preset} <- Config.timeframe_presets()}
              class={[
                "px-2 py-1.5 rounded text-center text-xs font-medium cursor-pointer transition-colors",
                Phoenix.HTML.Form.input_value(@form, :market_timeframe) == key &&
                  "bg-primary text-primary-content",
                Phoenix.HTML.Form.input_value(@form, :market_timeframe) != key &&
                  "bg-base-200 hover:bg-base-300"
              ]}
            >
              <input
                type="radio"
                name={@form[:market_timeframe].name}
                value={key}
                checked={Phoenix.HTML.Form.input_value(@form, :market_timeframe) == key}
                class="hidden"
              />
              {preset.label}
            </label>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-3">
          <div class="flex justify-between items-center">
            <span class="text-base-content/60">Signal Threshold</span>
            <input
              type="number"
              name={@form[:signal_threshold].name}
              value={Phoenix.HTML.Form.input_value(@form, :signal_threshold)}
              step="0.01"
              min="0.50"
              max="0.99"
              class="w-20 px-2 py-1 text-right font-medium rounded border border-base-300 bg-base-200 text-sm"
            />
          </div>
          <div class="flex justify-between items-center">
            <span class="text-base-content/60">Order Size</span>
            <input
              type="number"
              name={@form[:order_size].name}
              value={Phoenix.HTML.Form.input_value(@form, :order_size)}
              step="1"
              min="1"
              class="w-20 px-2 py-1 text-right font-medium rounded border border-base-300 bg-base-200 text-sm"
            />
          </div>
          <div class="flex justify-between items-center">
            <span class="text-base-content/60">Min Minutes</span>
            <input
              type="number"
              name={@form[:min_minutes].name}
              value={Phoenix.HTML.Form.input_value(@form, :min_minutes)}
              step="0.5"
              min="0"
              class="w-20 px-2 py-1 text-right font-medium rounded border border-base-300 bg-base-200 text-sm"
            />
          </div>
          <div class="flex justify-between items-center">
            <span class="text-base-content/60">Cooldown (s)</span>
            <input
              type="number"
              name={@form[:cooldown_seconds].name}
              value={Phoenix.HTML.Form.input_value(@form, :cooldown_seconds)}
              step="1"
              min="0"
              class="w-20 px-2 py-1 text-right font-medium rounded border border-base-300 bg-base-200 text-sm"
            />
          </div>
        </div>

        <%!-- Order Type Section --%>
        <div class="pt-3 border-t border-base-300">
          <span class="text-base-content/60 text-xs block mb-2">Order Type</span>
          <div class="grid grid-cols-2 gap-2">
            <label class={[
              "p-3 rounded-lg border cursor-pointer transition-all",
              Phoenix.HTML.Form.input_value(@form, :use_limit_order) != false &&
                "border-info bg-info/5",
              Phoenix.HTML.Form.input_value(@form, :use_limit_order) == false &&
                "border-base-300 hover:border-base-content/20"
            ]}>
              <input
                type="radio"
                name={@form[:use_limit_order].name}
                value="true"
                checked={Phoenix.HTML.Form.input_value(@form, :use_limit_order) != false}
                class="hidden"
              />
              <div class="flex items-center gap-2">
                <div class={[
                  "w-4 h-4 rounded-full border-2 flex items-center justify-center",
                  Phoenix.HTML.Form.input_value(@form, :use_limit_order) != false &&
                    "border-info",
                  Phoenix.HTML.Form.input_value(@form, :use_limit_order) == false &&
                    "border-base-300"
                ]}>
                  <div
                    :if={Phoenix.HTML.Form.input_value(@form, :use_limit_order) != false}
                    class="w-2 h-2 rounded-full bg-info"
                  />
                </div>
                <div>
                  <p class="text-xs font-semibold">Limit Order</p>
                  <p class="text-[10px] text-base-content/50">Buy at specific price</p>
                </div>
              </div>
            </label>
            <label class={[
              "p-3 rounded-lg border cursor-pointer transition-all",
              Phoenix.HTML.Form.input_value(@form, :use_limit_order) == false &&
                "border-warning bg-warning/5",
              Phoenix.HTML.Form.input_value(@form, :use_limit_order) != false &&
                "border-base-300 hover:border-base-content/20"
            ]}>
              <input
                type="radio"
                name={@form[:use_limit_order].name}
                value="false"
                checked={Phoenix.HTML.Form.input_value(@form, :use_limit_order) == false}
                class="hidden"
              />
              <div class="flex items-center gap-2">
                <div class={[
                  "w-4 h-4 rounded-full border-2 flex items-center justify-center",
                  Phoenix.HTML.Form.input_value(@form, :use_limit_order) == false &&
                    "border-warning",
                  Phoenix.HTML.Form.input_value(@form, :use_limit_order) != false &&
                    "border-base-300"
                ]}>
                  <div
                    :if={Phoenix.HTML.Form.input_value(@form, :use_limit_order) == false}
                    class="w-2 h-2 rounded-full bg-warning"
                  />
                </div>
                <div>
                  <p class="text-xs font-semibold">Market Order</p>
                  <p class="text-[10px] text-base-content/50">Buy at best ask</p>
                </div>
              </div>
            </label>
          </div>

          <%!-- Limit Price Input (only shown when limit order is selected) --%>
          <div
            :if={Phoenix.HTML.Form.input_value(@form, :use_limit_order) != false}
            class="mt-3 p-3 rounded-lg bg-info/5 border border-info/20"
          >
            <div class="flex justify-between items-center">
              <div>
                <span class="text-xs font-medium">Limit Price</span>
                <p class="text-[10px] text-base-content/50">Max price to pay per share</p>
              </div>
              <div class="flex items-center gap-1">
                <input
                  type="number"
                  name={@form[:limit_price].name}
                  value={Phoenix.HTML.Form.input_value(@form, :limit_price)}
                  step="0.001"
                  min="0.90"
                  max="1.0"
                  class="w-20 px-2 py-1 text-right font-mono font-medium rounded border border-info/30 bg-base-100 text-sm"
                />
                <span class="text-xs text-base-content/50">
                  ({format_price_cents(Phoenix.HTML.Form.input_value(@form, :limit_price) || 0.99)})
                </span>
              </div>
            </div>
          </div>
        </div>

        <div class="flex gap-2 pt-3 border-t border-base-300">
          <button
            type="submit"
            class="flex-1 px-3 py-1.5 rounded-lg bg-primary text-primary-content font-medium text-xs"
          >
            Save
          </button>
          <button
            type="button"
            phx-click="cancel_edit_config"
            class="px-3 py-1.5 rounded-lg bg-base-300 text-base-content font-medium text-xs"
          >
            Cancel
          </button>
        </div>
      </div>
    </.form>
    """
  end

  defp orders_list(assigns) do
    ~H"""
    <div
      :if={@running}
      class={[
        "rounded-2xl bg-base-200/50 overflow-hidden",
        @paper_mode && "border border-warning/30",
        !@paper_mode && "border border-error/30"
      ]}
    >
      <div class={[
        "px-5 py-4 border-b",
        @paper_mode && "border-warning/20 bg-warning/5",
        !@paper_mode && "border-error/20 bg-error/5"
      ]}>
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <.icon
              name={if @paper_mode, do: "hero-document-text", else: "hero-bolt-solid"}
              class={if @paper_mode, do: "size-5 text-warning", else: "size-5 text-error"}
            />
            <h2 class="font-semibold">{if @paper_mode, do: "Paper Orders", else: "Live Orders"}</h2>
          </div>
          <div class="flex items-center gap-3">
            <p class="text-xs text-base-content/50">{length(@paper_orders)} orders</p>
            <%= if @paper_orders != [] do %>
              <button
                phx-click="clear_trades"
                data-confirm="Delete all trades?"
                class="text-xs text-error/70 hover:text-error"
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
            <.icon name="hero-clipboard-document-list" class="size-6 text-warning/50 mx-auto" />
            <p class="text-base-content/50 text-sm mt-2">No orders yet</p>
          </div>
        <% else %>
          <div :for={order <- @paper_orders} class="px-4 py-3 hover:bg-base-100/50">
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
                    Price:
                    <span class="font-medium font-mono">{format_price_precise(order.price)}</span>
                  </span>
                  <span class="text-base-content/60">
                    Size: <span class="font-medium">${order.size}</span>
                  </span>
                </div>
              </div>
              <div class="flex flex-col items-end gap-1 shrink-0">
                <span class={[
                  "px-2 py-0.5 rounded text-[10px] font-semibold",
                  order.status == :filled && "bg-success/10 text-success",
                  order.status == :submitted && "bg-info/10 text-info",
                  order.status == :pending && "bg-warning/10 text-warning"
                ]}>
                  {order.status |> to_string() |> String.upcase()}
                </span>
                <span class="text-base-content/30 text-[10px]">{format_time(order.placed_at)}</span>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp events_log(assigns) do
    ~H"""
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
            class="text-xs text-base-content/50 hover:text-base-content"
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
        <div id="events-empty" class="hidden only:block py-12 text-center">
          <.icon name="hero-document-text" class="size-8 text-base-content/30 mx-auto" />
          <p class="text-base-content/50 font-medium mt-4">No events yet</p>
        </div>

        <div :for={{id, event} <- @streams.events} id={id} class="flex items-start gap-3 px-5 py-3">
          <div class={[
            "w-8 h-8 rounded-lg flex items-center justify-center shrink-0",
            event_type_class(event.type)
          ]}>
            <.icon name={event_type_icon(event.type)} class="size-4" />
          </div>
          <div class="flex-1 min-w-0">
            <p class="text-sm">{event.message}</p>
            <p class="text-xs text-base-content/40 mt-0.5">{format_datetime(event.inserted_at)}</p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp no_selection(assigns) do
    ~H"""
    <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
      <div class="py-20 text-center">
        <div class="w-20 h-20 rounded-2xl bg-base-300/50 flex items-center justify-center mx-auto mb-4">
          <.icon name="hero-cursor-arrow-rays" class="size-10 text-base-content/30" />
        </div>
        <p class="text-base-content/50 font-medium">Select a strategy</p>
        <p class="text-sm text-base-content/40 mt-1">Click on a strategy to view details</p>
      </div>
    </div>
    """
  end

  # Helper functions

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

  defp outcome_class("Yes"), do: "bg-success/20 text-success"
  defp outcome_class("No"), do: "bg-error/20 text-error"
  defp outcome_class(_), do: "bg-base-300 text-base-content/60"

  defp order_side_class(side) when side in ["BUY", "buy", :buy], do: "text-success font-semibold"
  defp order_side_class(side) when side in ["SELL", "sell", :sell], do: "text-error font-semibold"
  defp order_side_class(_), do: "text-base-content/60"

  # Extract outcome (Up/Down) from signal metadata for display
  defp signal_outcome_label(signal) do
    outcome = get_in(signal, [:metadata, :outcome]) || get_in(signal, ["metadata", "outcome"])

    case outcome do
      "Up" -> "↑ UP"
      "Down" -> "↓ DOWN"
      "Yes" -> "YES"
      "No" -> "NO"
      nil -> signal.action |> to_string() |> String.upcase()
      other -> String.upcase(to_string(other))
    end
  end

  defp pnl_class(pnl) do
    cond do
      Decimal.compare(pnl, 0) == :gt -> "text-success"
      Decimal.compare(pnl, 0) == :lt -> "text-error"
      true -> ""
    end
  end

  defp format_percent(value) when is_number(value), do: "#{round(value * 100)}%"
  defp format_percent(_), do: "-"

  defp format_price_percent(price) when is_number(price), do: "#{Float.round(price * 100, 1)}¢"
  defp format_price_percent(_), do: "-"

  defp format_price_precise(price) when is_number(price),
    do: :erlang.float_to_binary(price * 1.0, decimals: 4)

  defp format_price_precise(_), do: "-"

  defp format_price_cents(price) when is_number(price), do: "#{Float.round(price * 100, 1)}¢"
  defp format_price_cents(_), do: "-"

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_datetime(_), do: ""

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(_), do: ""

  defp timeframe_label(timeframe) do
    presets = Config.timeframe_presets()

    case Map.get(presets, timeframe) do
      %{label: label} -> label
      _ -> "15 Minutes"
    end
  end

  defp token_count(:no_markets), do: 0
  defp token_count(prices) when is_map(prices), do: map_size(prices)
  defp token_count(_), do: 0

  defp sort_tokens(:no_markets, _), do: []
  defp sort_tokens(prices, _) when not is_map(prices), do: []

  defp sort_tokens(prices, _config) do
    prices
    |> Enum.sort_by(fn {_, data} -> data[:best_bid] || data[:mid] || 0.5 end, :desc)
  end

  defp price_row_class(price, config) when is_number(price) do
    threshold = config["signal_threshold"] || 0.80

    cond do
      price > threshold -> "bg-success/10 border-success/30"
      price < 0.20 -> "bg-error/10 border-error/30"
      true -> "bg-base-100 border-base-300"
    end
  end

  defp price_row_class(_, _), do: "bg-base-100 border-base-300"

  defp price_status_class(price, config) when is_number(price) do
    threshold = config["signal_threshold"] || 0.80

    cond do
      price > threshold -> "text-success"
      price < 0.20 -> "text-error"
      true -> "text-base-content/40"
    end
  end

  defp price_status_class(_, _), do: "text-base-content/40"

  defp price_status_label(price, config) when is_number(price) do
    threshold = config["signal_threshold"] || 0.80
    target = config["limit_price"] || 0.99

    cond do
      price > threshold -> "TARGET #{Float.round(target * 100, 0)}¢"
      price < 0.20 -> "TARGET 1¢"
      true -> "WAIT"
    end
  end

  defp price_status_label(_, _), do: "N/A"

  defp polymarket_url(%{event_slug: slug}) when is_binary(slug) and slug != "",
    do: "https://polymarket.com/event/#{slug}"

  defp polymarket_url(%{condition_id: cid}) when is_binary(cid) and cid != "",
    do: "https://polymarket.com/event?id=#{cid}"

  defp polymarket_url(_), do: "https://polymarket.com"

  defp short_token(nil), do: "unknown"

  defp short_token(id) when is_binary(id) do
    if String.length(id) > 16, do: String.slice(id, 0, 8) <> "...", else: id
  end
end
