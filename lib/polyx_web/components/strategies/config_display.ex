defmodule PolyxWeb.Components.Strategies.ConfigDisplay do
  @moduledoc """
  Component for displaying strategy configuration (read-only).
  Supports both time_decay and delta_arb strategy types.
  """
  use PolyxWeb, :html

  import PolyxWeb.StrategiesLive.Formatters

  @doc """
  Renders the strategy configuration in read-only mode.
  """
  attr :config, :map, required: true
  attr :strategy_type, :string, default: "time_decay"

  def config_display(assigns) do
    ~H"""
    <div class="p-4 rounded-xl bg-base-100 border border-base-300">
      <div class="space-y-3 text-sm">
        <%= if @strategy_type == "delta_arb" do %>
          <.delta_arb_display config={@config} />
        <% else %>
          <.time_decay_display config={@config} />
        <% end %>
      </div>
    </div>
    """
  end

  defp time_decay_display(assigns) do
    ~H"""
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
    """
  end

  defp delta_arb_display(assigns) do
    ~H"""
    <div class="pb-2 border-b border-base-300 flex gap-2">
      <div>
        <span class="text-base-content/60 text-xs">Market Type</span>
        <div class="mt-1">
          <span class="px-3 py-1 rounded-lg bg-success/10 text-success font-medium text-sm">
            {String.capitalize(@config["market_type"] || "crypto")}
          </span>
        </div>
      </div>
      <div :if={@config["market_type"] != "sports"}>
        <span class="text-base-content/60 text-xs">Timeframe</span>
        <div class="mt-1">
          <span class="px-3 py-1 rounded-lg bg-primary/10 text-primary font-medium text-sm">
            {timeframe_label(@config["market_timeframe"])}
          </span>
        </div>
      </div>
      <div :if={@config["market_type"] == "sports"}>
        <span class="text-base-content/60 text-xs">Mode</span>
        <div class="mt-1">
          <span class="px-3 py-1 rounded-lg bg-info/10 text-info font-medium text-sm">
            All Active
          </span>
        </div>
      </div>
    </div>
    <div class="grid grid-cols-2 gap-3">
      <div class="flex justify-between items-center">
        <span class="text-base-content/60">Min Spread</span>
        <span class="font-medium">{format_spread(@config["min_spread"] || 0.04)}</span>
      </div>
      <div class="flex justify-between items-center">
        <span class="text-base-content/60">Order Size/Leg</span>
        <span class="font-medium">${@config["order_size"] || 10}</span>
      </div>
      <div class="flex justify-between items-center">
        <span class="text-base-content/60">Max Entries</span>
        <span class="font-medium">{@config["max_entries_per_event"] || 3}</span>
      </div>
      <div class="flex justify-between items-center">
        <span class="text-base-content/60">Min Minutes</span>
        <span class="font-medium">{@config["min_minutes"] || 1}</span>
      </div>
      <div class="flex justify-between items-center col-span-2">
        <span class="text-base-content/60">Cooldown</span>
        <span class="font-medium">{@config["cooldown_seconds"] || 60}s</span>
      </div>
    </div>
    <div class="pt-2 border-t border-base-300">
      <div class="p-2 rounded-lg bg-success/5 border border-success/20">
        <p class="text-xs text-base-content/70">
          <span class="font-medium text-success">Strategy</span>:
          Buys both YES + NO when combined cost &lt; ${format_combined_threshold(
            @config["min_spread"]
          )}
        </p>
      </div>
    </div>
    """
  end

  defp format_spread(spread) when is_number(spread), do: "#{Float.round(spread * 100, 1)}%"
  defp format_spread(_), do: "4%"

  defp format_combined_threshold(min_spread) when is_number(min_spread) do
    Float.round(1.0 - min_spread, 2)
  end

  defp format_combined_threshold(_), do: "0.96"
end
