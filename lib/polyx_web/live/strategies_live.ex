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
  alias Polyx.Strategies.{Engine, Behaviour, Config}

  # Import utility modules
  alias PolyxWeb.StrategiesLive.{State, PriceHandler}

  # Import components
  import PolyxWeb.Components.Strategies.{
    NoSelection,
    StrategyList,
    StrategyDetails,
    LiveSignals,
    WatchedTokens,
    ArbPairs
  }

  require Logger

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Polyx.PubSub, "strategies:updates")
      :timer.send_interval(30_000, self(), :refresh_strategies)
    end

    strategies = Strategies.list_strategies() |> State.enrich_with_running_state()
    selected = State.maybe_select_strategy(strategies, params["strategy_id"])

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
        State.subscribe_to_strategy(socket, selected.strategy.id)
      else
        socket
      end

    {:ok, socket}
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
        strategies = Strategies.list_strategies() |> State.enrich_with_running_state()
        action = if is_running, do: "stopped", else: "started"

        socket =
          socket
          |> assign(:strategies, strategies)
          |> State.update_selected_strategy(id)
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
        strategies = Strategies.list_strategies() |> State.enrich_with_running_state()

        {:noreply,
         socket
         |> assign(:strategies, strategies)
         |> State.update_selected_strategy(id)
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
    paper_orders = Enum.map(trades, &State.trade_to_paper_order/1)

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
    strategy = socket.assigns.selected_strategy.strategy
    config_mod = config_module_for_type(strategy.type)
    config = config_mod.from_map(strategy.config)
    changeset = config_mod.changeset(config, %{})
    form = to_form(changeset, as: :config)
    {:noreply, socket |> assign(:editing_config, true) |> assign(:config_form, form)}
  end

  @impl true
  def handle_event("cancel_edit_config", _params, socket) do
    {:noreply, socket |> assign(:editing_config, false) |> assign(:config_form, nil)}
  end

  @impl true
  def handle_event("validate_config", %{"config" => config_params}, socket) do
    strategy = socket.assigns.selected_strategy.strategy
    config_mod = config_module_for_type(strategy.type)
    config = config_mod.from_map(strategy.config)

    changeset =
      config
      |> config_mod.changeset(config_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :config_form, to_form(changeset, as: :config))}
  end

  @impl true
  def handle_event("save_config", %{"config" => config_params}, socket) do
    strategy = socket.assigns.selected_strategy.strategy
    config_mod = config_module_for_type(strategy.type)
    config = config_mod.from_map(strategy.config)
    changeset = config_mod.changeset(config, config_params)

    if changeset.valid? do
      updated_config = Ecto.Changeset.apply_changes(changeset)
      new_config_map = config_mod.to_map(updated_config)

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

  defp config_module_for_type("delta_arb"), do: Polyx.Strategies.DeltaArb.Config
  defp config_module_for_type(_), do: Config

  # Message handlers

  @impl true
  def handle_info(:refresh_strategies, socket) do
    strategies = Strategies.list_strategies() |> State.enrich_with_running_state()

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
    PriceHandler.handle_fetch_discovered_tokens(socket, strategy_id)
  end

  @impl true
  def handle_info({:discovered_tokens, tokens_with_info}, socket) do
    PriceHandler.handle_discovered_tokens(socket, tokens_with_info)
  end

  @impl true
  def handle_info({:removed_tokens, token_ids}, socket) do
    PriceHandler.handle_removed_tokens(socket, token_ids)
  end

  @impl true
  def handle_info({:price_update, token_id, price_data}, socket) do
    PriceHandler.handle_price_update(socket, token_id, price_data)
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
                <%= if @selected_strategy.strategy.type == "delta_arb" do %>
                  <.arb_pairs
                    token_prices={@token_prices}
                    config={@selected_strategy.strategy.config}
                  />
                <% else %>
                  <.watched_tokens
                    token_prices={@token_prices}
                    config={@selected_strategy.strategy.config}
                  />
                <% end %>
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
end
