defmodule PolyxWeb.Components.Strategies.ConfigDisplay do
  @moduledoc """
  Component for displaying strategy configuration (read-only).
  """
  use PolyxWeb, :html

  import PolyxWeb.StrategiesLive.Formatters

  @doc """
  Renders the strategy configuration in read-only mode.
  """
  attr :config, :map, required: true

  def config_display(assigns) do
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
            <span class="text-base-content/60">Shares</span>
            <span class="font-medium">{@config["order_size"] || 5}</span>
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
end
