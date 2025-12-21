defmodule PolyxWeb.Components.Strategies.ConfigForm do
  @moduledoc """
  Component for editing strategy configuration.
  """
  use PolyxWeb, :html

  import PolyxWeb.StrategiesLive.Formatters

  alias Polyx.Strategies.Config

  @doc """
  Renders the strategy configuration editing form.
  """
  attr :form, :any, required: true

  def config_form(assigns) do
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
            <span class="text-base-content/60">Shares</span>
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
end
