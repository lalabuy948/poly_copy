defmodule PolyxWeb.Components.Strategies.ArbPairs do
  @moduledoc """
  Component for displaying arbitrage pairs with combined YES/NO prices.
  Shows potential arbitrage opportunities for delta-neutral strategy.
  """
  use PolyxWeb, :html

  import PolyxWeb.StrategiesLive.Formatters

  @doc """
  Renders the arb pairs list with live price updates.
  Groups tokens by market and shows combined cost + spread.
  """
  attr :token_prices, :any, required: true
  attr :config, :map, required: true

  def arb_pairs(assigns) do
    pairs = build_pairs(assigns.token_prices)
    min_spread = assigns.config["min_spread"] || 0.04

    # Count tokens with prices vs total
    {with_prices, total} = count_tokens_with_prices(assigns.token_prices)

    assigns =
      assigns
      |> assign(:pairs, pairs)
      |> assign(:min_spread, min_spread)
      |> assign(:tokens_with_prices, with_prices)
      |> assign(:total_tokens, total)

    ~H"""
    <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
      <div class="px-4 py-3 border-b border-base-300">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <.icon name="hero-scale" class="size-4 text-success" />
            <h3 class="font-medium text-sm">Arb Opportunities</h3>
            <span class="px-1.5 py-0.5 rounded-full bg-success/10 text-success text-[10px] font-medium">
              {length(@pairs)} pairs
            </span>
          </div>
          <span
            :if={@total_tokens > 0}
            class="text-[10px] text-base-content/50"
            title="Tokens with prices / Total discovered"
          >
            <span
              :if={@tokens_with_prices < @total_tokens}
              class="loading loading-spinner loading-xs mr-1"
            >
            </span>
            {@tokens_with_prices}/{@total_tokens} tokens
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
          <% @pairs == [] -> %>
            <div class="py-6 text-center">
              <.icon name="hero-clock" class="size-8 text-base-content/30 mx-auto" />
              <p class="text-base-content/50 text-xs mt-2">Waiting for price pairs...</p>
            </div>
          <% true -> %>
            <div class="space-y-2">
              <.pair_row :for={pair <- @pairs} pair={pair} min_spread={@min_spread} />
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp pair_row(assigns) do
    ~H"""
    <div class={[
      "p-3 rounded-lg border text-xs",
      pair_class(@pair.spread, @min_spread)
    ]}>
      <div class="flex items-center justify-between gap-2 mb-2">
        <div class="flex-1 min-w-0">
          <p class="font-medium truncate text-sm">{@pair.question}</p>
          <p class="text-[10px] text-base-content/50 truncate">{@pair.event_title}</p>
        </div>
        <div class="text-right shrink-0">
          <p class={[
            "font-mono font-bold text-lg",
            spread_color(@pair.spread, @min_spread)
          ]}>
            {format_spread(@pair.spread)}
          </p>
          <p class="text-[10px] text-base-content/50">spread</p>
        </div>
      </div>

      <div class="grid grid-cols-3 gap-2 pt-2 border-t border-base-300/50">
        <div class="text-center">
          <p class="text-[10px] text-base-content/50 mb-0.5">YES Ask</p>
          <p class="font-mono font-semibold text-success">
            {format_price_cents(@pair.yes_ask)}
          </p>
        </div>
        <div class="text-center">
          <p class="text-[10px] text-base-content/50 mb-0.5">NO Ask</p>
          <p class="font-mono font-semibold text-error">
            {format_price_cents(@pair.no_ask)}
          </p>
        </div>
        <div class="text-center">
          <p class="text-[10px] text-base-content/50 mb-0.5">Combined</p>
          <p class={[
            "font-mono font-semibold",
            combined_color(@pair.combined)
          ]}>
            {format_price_cents(@pair.combined)}
          </p>
        </div>
      </div>
    </div>
    """
  end

  # Build pairs from token prices by matching YES/NO tokens
  defp build_pairs(token_prices) when is_map(token_prices) do
    # Group tokens by market question
    token_prices
    |> Enum.group_by(fn {_token_id, data} ->
      data[:market_question] || data[:event_title] || "unknown"
    end)
    |> Enum.flat_map(fn {_question, tokens} ->
      # Find YES and NO tokens in this group
      yes_token =
        Enum.find(tokens, fn {_id, data} ->
          outcome = data[:outcome] || ""
          String.downcase(outcome) in ["yes", "up"]
        end)

      no_token =
        Enum.find(tokens, fn {_id, data} ->
          outcome = data[:outcome] || ""
          String.downcase(outcome) in ["no", "down"]
        end)

      case {yes_token, no_token} do
        {{_yes_id, yes_data}, {_no_id, no_data}} ->
          yes_ask = yes_data[:best_ask]
          no_ask = no_data[:best_ask]

          if yes_ask && no_ask do
            combined = yes_ask + no_ask
            spread = 1.0 - combined

            [
              %{
                question: yes_data[:market_question] || "Unknown",
                event_title: yes_data[:event_title],
                yes_ask: yes_ask,
                no_ask: no_ask,
                combined: combined,
                spread: spread
              }
            ]
          else
            []
          end

        _ ->
          []
      end
    end)
    |> Enum.sort_by(& &1.spread, :desc)
    |> Enum.take(50)
  end

  defp build_pairs(_), do: []

  # Count tokens with prices vs total discovered
  defp count_tokens_with_prices(token_prices) when is_map(token_prices) do
    total = map_size(token_prices)

    with_prices =
      Enum.count(token_prices, fn {_id, data} ->
        data[:best_ask] != nil or data[:best_bid] != nil
      end)

    {with_prices, total}
  end

  defp count_tokens_with_prices(_), do: {0, 0}

  defp pair_class(spread, min_spread) when is_number(spread) do
    cond do
      spread >= min_spread -> "bg-success/10 border-success/30"
      spread >= min_spread * 0.75 -> "bg-warning/10 border-warning/30"
      true -> "bg-base-100 border-base-300"
    end
  end

  defp pair_class(_, _), do: "bg-base-100 border-base-300"

  defp spread_color(spread, min_spread) when is_number(spread) do
    cond do
      spread >= min_spread -> "text-success"
      spread >= min_spread * 0.75 -> "text-warning"
      spread > 0 -> "text-base-content"
      true -> "text-error"
    end
  end

  defp spread_color(_, _), do: "text-base-content/50"

  defp combined_color(combined) when is_number(combined) do
    cond do
      combined < 0.96 -> "text-success"
      combined < 1.0 -> "text-warning"
      true -> "text-error"
    end
  end

  defp combined_color(_), do: "text-base-content"

  defp format_spread(spread) when is_number(spread) do
    "#{Float.round(spread * 100, 2)}%"
  end

  defp format_spread(_), do: "—"
end
