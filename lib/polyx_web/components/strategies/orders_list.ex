defmodule PolyxWeb.Components.Strategies.OrdersList do
  @moduledoc """
  Component for displaying paper/live orders.
  """
  use PolyxWeb, :html

  import PolyxWeb.StrategiesLive.Formatters

  @doc """
  Renders the orders list (paper or live mode).
  """
  attr :paper_orders, :list, required: true
  attr :paper_mode, :boolean, required: true
  attr :running, :boolean, required: true

  def orders_list(assigns) do
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
end
