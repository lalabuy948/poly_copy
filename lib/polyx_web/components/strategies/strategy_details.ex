defmodule PolyxWeb.Components.Strategies.StrategyDetails do
  @moduledoc """
  Component for displaying detailed strategy information.
  """
  use PolyxWeb, :html

  import PolyxWeb.StrategiesLive.{Formatters, Helpers}
  import PolyxWeb.Components.Strategies.{ConfigDisplay, ConfigForm, OrdersList, EventsLog}

  alias Polyx.Strategies.Behaviour

  @doc """
  Renders the detailed strategy view with stats, config, and activity.
  """
  attr :selected_strategy, :map, required: true
  attr :editing_config, :boolean, required: true
  attr :config_form, :any, required: true
  attr :paper_orders, :list, required: true
  attr :streams, :map, required: true

  def strategy_details(assigns) do
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
end
