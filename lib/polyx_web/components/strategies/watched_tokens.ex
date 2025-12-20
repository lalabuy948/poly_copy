defmodule PolyxWeb.Components.Strategies.WatchedTokens do
  @moduledoc """
  Component for displaying watched tokens with live prices.
  """
  use PolyxWeb, :html

  import PolyxWeb.StrategiesLive.{Formatters, Helpers, PriceUtils}

  @doc """
  Renders the watched tokens list with live price updates.
  """
  attr :token_prices, :any, required: true
  attr :config, :map, required: true

  def watched_tokens(assigns) do
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
end
