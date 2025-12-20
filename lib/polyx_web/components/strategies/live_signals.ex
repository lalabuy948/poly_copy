defmodule PolyxWeb.Components.Strategies.LiveSignals do
  @moduledoc """
  Component for displaying live strategy signals.
  """
  use PolyxWeb, :html

  import PolyxWeb.StrategiesLive.{Formatters, Helpers}

  @doc """
  Renders the live signals feed with stream-based updates.
  """
  attr :streams, :map, required: true

  def live_signals(assigns) do
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
end
