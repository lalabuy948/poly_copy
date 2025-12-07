defmodule Polyx.Polymarket.LiveOrders do
  @moduledoc """
  WebSocket client for Polymarket CLOB real-time order feed.
  Connects to wss://ws-subscriptions-clob.polymarket.com

  Implements batched broadcasting to reduce PubSub overhead during
  high-volume periods. Orders are accumulated and broadcast in batches
  every 100ms.
  """
  use Fresh

  require Logger

  alias Polyx.Polymarket.Gamma

  @ws_url "wss://ws-subscriptions-clob.polymarket.com/ws/market"

  # PubSub topic for live orders
  @pubsub_topic "polymarket:live_orders"

  # Polymarket requires ping every 10 seconds
  @ping_interval 10_000

  # Batch interval for broadcasting (ms)
  @batch_interval 100

  # Max orders to batch before forcing a flush
  @max_batch_size 50

  @doc """
  Child spec for supervisor. Starts the WebSocket client.
  """
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start:
        {__MODULE__, :start_link,
         [
           [
             uri: @ws_url,
             state: %{subscribed: false, order_batch: [], batch_timer: nil},
             opts: [
               name: {:local, __MODULE__},
               ping_interval: @ping_interval
             ]
           ]
         ]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc """
  Subscribe to live orders updates via PubSub.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(Polyx.PubSub, @pubsub_topic)
  end

  @doc """
  Subscribe to market updates for a specific asset ID.
  """
  def subscribe_to_market(asset_id) when is_binary(asset_id) do
    subscribe_to_markets([asset_id])
  end

  @doc """
  Subscribe to multiple markets by asset IDs.
  """
  def subscribe_to_markets(asset_ids) when is_list(asset_ids) do
    msg =
      Jason.encode!(%{
        assets_ids: asset_ids,
        type: "market"
      })

    Logger.info("[LiveOrders] Subscribing to #{length(asset_ids)} markets")
    Fresh.send(__MODULE__, {:text, msg})
  end

  # Fresh callbacks

  @impl Fresh
  def handle_connect(_status, _headers, state) do
    Logger.info("[LiveOrders] Connected to Polymarket WebSocket")
    broadcast({:connected, true})

    {:ok, %{state | subscribed: false, order_batch: [], batch_timer: nil}}
  end

  @impl Fresh
  def handle_disconnect(_code, _reason, state) do
    Logger.warning("[LiveOrders] Disconnected from Polymarket WebSocket, reconnecting...")
    broadcast({:connected, false})
    # Cancel any pending batch timer
    if state.batch_timer, do: Process.cancel_timer(state.batch_timer)
    {:reconnect, %{state | subscribed: false, order_batch: [], batch_timer: nil}}
  end

  @impl Fresh
  def handle_error(error, _state) do
    Logger.error("[LiveOrders] WebSocket error: #{inspect(error)}")
    broadcast({:connected, false})
    :reconnect
  end

  @impl Fresh
  def handle_in({:text, message}, state) do
    state =
      case Jason.decode(message) do
        {:ok, %{"event_type" => event_type} = data} ->
          handle_event(event_type, data, state)

        {:ok, data} when is_list(data) ->
          # Handle batch messages (initial book snapshots)
          Enum.reduce(data, state, fn item, acc_state ->
            event_type = Map.get(item, "event_type", "unknown")
            handle_event(event_type, item, acc_state)
          end)

        {:ok, %{} = data} when map_size(data) == 0 ->
          # Empty response, likely acknowledgment
          state

        {:ok, "PONG"} ->
          # Ping response
          state

        {:ok, _data} ->
          state

        {:error, _reason} ->
          state
      end

    {:ok, state}
  end

  def handle_in({:binary, _data}, state) do
    {:ok, state}
  end

  @impl Fresh
  def handle_info(:flush_batch, state) do
    state = flush_order_batch(state)
    {:ok, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[LiveOrders] Received info: #{inspect(msg)}")
    {:ok, state}
  end

  defp handle_event("last_trade_price", data, state) do
    # Real-time trade data
    asset_id = data["asset_id"]
    market_info = lookup_market_info(asset_id)

    order = %{
      id: System.unique_integer([:positive, :monotonic]),
      event_type: "trade",
      asset_id: asset_id,
      price: parse_float(data["price"]),
      size: parse_float(data["size"]),
      side: data["side"],
      timestamp: data["timestamp"] || System.system_time(:millisecond),
      fee_rate_bps: data["fee_rate_bps"],
      # Market info from cache
      market_question: market_info[:question],
      event_title: market_info[:event_title],
      outcome: market_info[:outcome]
    }

    add_to_batch(order, state)
  end

  defp handle_event("price_change", data, state) do
    # Price changes from new/cancelled orders
    price_changes = data["price_changes"] || []

    Enum.reduce(price_changes, state, fn change, acc_state ->
      asset_id = change["asset_id"]
      market_info = lookup_market_info(asset_id)

      order = %{
        id: System.unique_integer([:positive, :monotonic]),
        event_type: "price_change",
        asset_id: asset_id,
        price: parse_float(change["price"]),
        size: parse_float(change["size"]),
        side: change["side"],
        best_bid: parse_float(change["best_bid"]),
        best_ask: parse_float(change["best_ask"]),
        timestamp: data["timestamp"] || System.system_time(:millisecond),
        # Market info from cache
        market_question: market_info[:question],
        event_title: market_info[:event_title],
        outcome: market_info[:outcome]
      }

      add_to_batch(order, acc_state)
    end)
  end

  defp handle_event("book", _data, state) do
    # Full orderbook snapshot - don't broadcast these as they're large
    state
  end

  defp handle_event("tick_size_change", data, state) do
    Logger.info(
      "[LiveOrders] Tick size changed: #{data["old_tick_size"]} -> #{data["new_tick_size"]}"
    )

    state
  end

  defp handle_event(_event_type, _data, state) do
    state
  end

  # Batching functions to reduce PubSub overhead

  defp add_to_batch(order, state) do
    new_batch = [order | state.order_batch]

    # Force flush if batch is too large
    if length(new_batch) >= @max_batch_size do
      flush_order_batch(%{state | order_batch: new_batch})
    else
      # Schedule a flush if not already scheduled
      state =
        if is_nil(state.batch_timer) do
          timer = Process.send_after(self(), :flush_batch, @batch_interval)
          %{state | batch_timer: timer}
        else
          state
        end

      %{state | order_batch: new_batch}
    end
  end

  defp flush_order_batch(%{order_batch: []} = state) do
    %{state | batch_timer: nil}
  end

  defp flush_order_batch(state) do
    # Broadcast orders in reverse order (oldest first)
    orders = Enum.reverse(state.order_batch)

    # Broadcast as a batch if multiple orders, or individually if just one
    case orders do
      [single_order] ->
        broadcast({:new_order, single_order})

      multiple_orders ->
        # Broadcast batch for efficiency
        broadcast({:new_orders_batch, multiple_orders})
        # Also broadcast individually for compatibility with existing subscribers
        Enum.each(multiple_orders, &broadcast({:new_order, &1}))
    end

    %{state | order_batch: [], batch_timer: nil}
  end

  # Async lookup of market info - returns cached data or empty map
  defp lookup_market_info(nil), do: %{}

  defp lookup_market_info(asset_id) do
    case Gamma.get_market_by_token(asset_id) do
      {:ok, info} -> info
      _ -> %{}
    end
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Polyx.PubSub, @pubsub_topic, message)
  end

  defp parse_float(nil), do: 0.0

  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float(val) when is_number(val), do: val * 1.0
  defp parse_float(_), do: 0.0
end
