defmodule PolyxWeb.StrategiesLive.PriceHandler do
  @moduledoc """
  Handles price updates and token discovery for the StrategiesLive view.

  Manages WebSocket price updates, token discovery retries, and price data transformations.
  """

  alias Polyx.Strategies.Runner
  alias PolyxWeb.StrategiesLive.PriceUtils

  @doc """
  Handles fetching discovered tokens with retry logic.

  Returns {:noreply, socket} with updated token_prices and discovery_retries assigns.
  """
  def handle_fetch_discovered_tokens(socket, strategy_id) do
    case Runner.get_discovered_tokens_with_info(strategy_id) do
      {:ok, tokens_map} when map_size(tokens_map) > 0 ->
        # Convert to UI format - prices come from Runner's WebSocket cache
        token_prices =
          Enum.reduce(tokens_map, %{}, fn {token_id, info}, acc ->
            Map.put(acc, token_id, %{
              best_bid: info[:best_bid],
              best_ask: info[:best_ask],
              mid: PriceUtils.calculate_mid(info[:best_bid], info[:best_ask]),
              market_question: info[:market_question] || "Loading...",
              event_title: info[:event_title],
              outcome: info[:outcome],
              end_date: info[:end_date]
            })
          end)

        {:noreply, Phoenix.Component.assign(socket, :token_prices, token_prices)}

      _ ->
        # No tokens yet, retry in 60 seconds (max 10 retries)
        retries = socket.assigns[:discovery_retries] || 0

        if retries < 10 do
          Process.send_after(self(), {:fetch_discovered_tokens, strategy_id}, 60_000)
          {:noreply, Phoenix.Component.assign(socket, :discovery_retries, retries + 1)}
        else
          {:noreply, Phoenix.Component.assign(socket, :token_prices, :no_markets)}
        end
    end
  end

  @doc """
  Handles discovered tokens message.

  Merges new tokens with existing ones in the token_prices assign.
  """
  def handle_discovered_tokens(socket, tokens_with_info) do
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
              mid: PriceUtils.calculate_mid(info[:best_bid], info[:best_ask]),
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

    {:noreply,
     Phoenix.Component.assign(socket, :token_prices, Map.merge(current_prices, new_prices))}
  end

  @doc """
  Handles removed tokens message.

  Removes specified token IDs from the token_prices assign.
  """
  def handle_removed_tokens(socket, token_ids) do
    current = if is_map(socket.assigns.token_prices), do: socket.assigns.token_prices, else: %{}
    {:noreply, Phoenix.Component.assign(socket, :token_prices, Map.drop(current, token_ids))}
  end

  @doc """
  Handles price update message for a specific token.

  Updates the price data for the token if it exists in current prices.
  """
  def handle_price_update(socket, token_id, price_data) do
    current = if is_map(socket.assigns.token_prices), do: socket.assigns.token_prices, else: %{}

    if Map.has_key?(current, token_id) do
      existing = Map.get(current, token_id, %{})

      updated =
        Map.merge(existing, %{
          best_bid: price_data.best_bid || existing[:best_bid],
          best_ask: price_data.best_ask || existing[:best_ask],
          mid:
            PriceUtils.calculate_mid(price_data.best_bid, price_data.best_ask) ||
              existing[:mid],
          market_question: price_data[:market_question] || existing[:market_question],
          outcome: price_data[:outcome] || existing[:outcome]
        })

      {:noreply,
       Phoenix.Component.assign(socket, :token_prices, Map.put(current, token_id, updated))}
    else
      {:noreply, socket}
    end
  end
end
