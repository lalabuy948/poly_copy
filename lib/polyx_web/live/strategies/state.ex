defmodule PolyxWeb.StrategiesLive.State do
  @moduledoc """
  State management utilities for the StrategiesLive view.

  Handles strategy state enrichment, selection, and data transformations.
  """

  alias Polyx.Strategies
  alias Polyx.Strategies.{Engine, Runner}
  alias PolyxWeb.StrategiesLive.PriceUtils

  @doc """
  Enriches strategies with actual running state from the Engine.

  Updates the status field based on whether the strategy is actually running.
  """
  def enrich_with_running_state(strategies) do
    Enum.map(strategies, fn strategy ->
      actual_status = if Engine.running?(strategy.id), do: "running", else: "stopped"
      %{strategy | status: actual_status}
    end)
  end

  @doc """
  Updates the selected strategy if it matches the given ID.

  Refreshes the strategy data and stats from the database.
  """
  def update_selected_strategy(socket, id) do
    if socket.assigns.selected_strategy &&
         socket.assigns.selected_strategy.strategy.id == id do
      strategy = Strategies.get_strategy!(id)
      [enriched] = enrich_with_running_state([strategy])
      stats = Strategies.get_strategy_stats(id)
      Phoenix.Component.assign(socket, :selected_strategy, %{strategy: enriched, stats: stats})
    else
      socket
    end
  end

  @doc """
  Auto-selects a strategy from URL param if present.

  Returns nil if no strategy_id_param provided or strategy not found.
  """
  def maybe_select_strategy(_strategies, nil), do: nil

  def maybe_select_strategy(strategies, strategy_id_param) do
    strategy_id = String.to_integer(strategy_id_param)
    strategy = Enum.find(strategies, &(&1.id == strategy_id))

    if strategy do
      %{strategy: strategy, stats: Strategies.get_strategy_stats(strategy.id)}
    else
      nil
    end
  end

  @doc """
  Subscribes to a strategy's updates and loads its data.

  Returns the socket with updated assignments for token_prices and paper_orders.
  """
  def subscribe_to_strategy(socket, strategy_id) do
    Phoenix.PubSub.subscribe(Polyx.PubSub, "strategies:#{strategy_id}")

    # Load existing trades
    trades = Strategies.list_trades(strategy_id, limit: 50)
    paper_orders = Enum.map(trades, &trade_to_paper_order/1)

    # Load discovered tokens directly from runner (if running)
    token_prices =
      if Engine.running?(strategy_id) do
        case Runner.get_discovered_tokens_with_info(strategy_id) do
          {:ok, tokens_map} when map_size(tokens_map) > 0 ->
            # Convert to UI format - prices come from Runner's WebSocket cache
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

          _ ->
            # No tokens yet - schedule retry
            Process.send_after(self(), {:fetch_discovered_tokens, strategy_id}, 2_000)
            %{}
        end
      else
        %{}
      end

    socket
    |> Phoenix.Component.assign(:paper_orders, paper_orders)
    |> Phoenix.Component.assign(:token_prices, token_prices)
    |> Phoenix.Component.assign(:discovery_retries, 0)
  end

  @doc """
  Converts a Trade struct to a paper order map for UI display.
  """
  def trade_to_paper_order(%Polyx.Trades.Trade{} = trade) do
    %{
      id: trade.id,
      token_id: trade.asset_id,
      action: if(trade.side == "BUY", do: :buy, else: :sell),
      price: decimal_to_float(trade.price),
      size: decimal_to_float(trade.size),
      reason: trade.title,
      status: String.to_existing_atom(trade.status),
      paper_mode: trade.order_id && String.starts_with?(trade.order_id || "", "paper_"),
      order_id: trade.order_id,
      placed_at: trade.inserted_at,
      metadata: %{
        market_question: trade.title,
        outcome: trade.outcome
      }
    }
  end

  @doc """
  Converts a Decimal or number to float.
  """
  def decimal_to_float(nil), do: 0.0
  def decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  def decimal_to_float(n) when is_number(n), do: n * 1.0
end
