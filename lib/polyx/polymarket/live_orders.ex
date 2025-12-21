defmodule Polyx.Polymarket.LiveOrders do
  @moduledoc """
  WebSocket client for Polymarket CLOB real-time order feed.
  Connects to wss://ws-subscriptions-clob.polymarket.com
  """
  use Fresh

  require Logger

  alias Polyx.Polymarket.Gamma

  @ws_url "wss://ws-subscriptions-clob.polymarket.com/ws/market"
  @pubsub_topic "polymarket:live_orders"
  @ping_interval 10_000
  @batch_interval 50
  @max_batch_size 50

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start:
        {__MODULE__, :start_link,
         [
           [
             uri: @ws_url,
             state: %{
               ws_ready: false,
               order_batch: [],
               batch_timer: nil,
               subscribed_markets: MapSet.new(),
               subscription_retry: %{},
               subscription_stats: %{attempts: 0, retries: 0},
               last_subscription_at: nil,
               last_message_at: nil,
               health_timer: nil
             },
             opts: [
               name: {:local, __MODULE__},
               ping_interval: @ping_interval,
               backoff_initial: 500,
               backoff_max: 5_000
             ]
           ]
         ]},
      restart: :permanent,
      type: :worker
    }
  end

  def subscribe do
    Phoenix.PubSub.subscribe(Polyx.PubSub, @pubsub_topic)
  end

  def subscribe_to_market(asset_id) when is_binary(asset_id) do
    subscribe_to_markets([asset_id])
  end

  def subscribe_to_markets(asset_ids) when is_list(asset_ids) and asset_ids != [] do
    pid = Process.whereis(__MODULE__)
    if pid, do: send(pid, {:subscribe_markets, asset_ids})
  end

  def subscribe_to_markets([]), do: :ok

  def unsubscribe_from_markets(asset_ids) when is_list(asset_ids) and asset_ids != [] do
    pid = Process.whereis(__MODULE__)
    if pid, do: send(pid, {:unsubscribe_markets, asset_ids})
  end

  def unsubscribe_from_markets([]), do: :ok

  # Fresh callbacks

  @impl Fresh
  def handle_connect(_status, _headers, state) do
    Logger.info("[LiveOrders] Connected to Polymarket WebSocket")

    Logger.info(
      "[LiveOrders] Subscription stats so far: attempts=#{state.subscription_stats.attempts}, retries=#{state.subscription_stats.retries}"
    )

    broadcast({:connected, true})

    # Re-subscribe to all markets after reconnect
    markets = MapSet.to_list(state.subscribed_markets)

    if markets != [] do
      Logger.info("[LiveOrders] Re-subscribing to #{length(markets)} markets")
      send(self(), {:send_subscriptions, markets})
    end

    health_timer = Process.send_after(self(), :check_health, 10_000)

    {:ok,
     %{
       state
       | ws_ready: true,
         order_batch: [],
         batch_timer: nil,
         last_message_at: System.system_time(:millisecond),
         health_timer: health_timer
     }}
  end

  @impl Fresh
  def handle_disconnect(_code, _reason, state) do
    Logger.warning("[LiveOrders] Disconnected, reconnecting...")
    broadcast({:connected, false})
    if state.batch_timer, do: Process.cancel_timer(state.batch_timer)
    if state.health_timer, do: Process.cancel_timer(state.health_timer)

    {:reconnect, %{state | ws_ready: false, order_batch: [], batch_timer: nil, health_timer: nil}}
  end

  @impl Fresh
  def handle_error(error, state) do
    Logger.error("[LiveOrders] WebSocket error: #{inspect(error)}")
    broadcast({:connected, false})

    # Reset timers to avoid leaks and ensure clean reconnect
    if state.batch_timer, do: Process.cancel_timer(state.batch_timer)
    if state.health_timer, do: Process.cancel_timer(state.health_timer)

    {:reconnect, %{state | ws_ready: false, order_batch: [], batch_timer: nil, health_timer: nil}}
  end

  @impl Fresh
  def handle_in({:text, message}, state) do
    now = System.system_time(:millisecond)
    st = %{state | last_message_at: now}

    state =
      case message do
        "NO NEW ASSETS" ->
          Logger.info("[LiveOrders] Server responded: NO NEW ASSETS (already subscribed)")
          st

        "INVALID OPERATION" ->
          Logger.error("[LiveOrders] Server responded: INVALID OPERATION")
          st

        _ ->
          case Jason.decode(message) do
            {:ok, %{"event_type" => event_type} = data} ->
              handle_event(event_type, data, st)

            {:ok, data} when is_list(data) ->
              Enum.reduce(data, st, fn item, acc ->
                event_type = Map.get(item, "event_type", "unknown")
                handle_event(event_type, item, acc)
              end)

            {:ok, other} ->
              Logger.warning("[LiveOrders] Unknown message without event_type: #{inspect(other)}")
              st

            {:error, decode_error} ->
              Logger.error("[LiveOrders] Failed to decode message: #{inspect(decode_error)}")
              st
          end
      end

    {:ok, state}
  end

  def handle_in({:binary, _data}, state), do: {:ok, state}

  @impl Fresh
  def handle_info(:flush_batch, state) do
    {:ok, flush_order_batch(state)}
  end

  def handle_info({:subscribe_markets, asset_ids}, state) do
    new_markets = MapSet.new(asset_ids)
    updated = MapSet.union(state.subscribed_markets, new_markets)

    # Send subscription immediately if ready
    if state.ws_ready do
      send(self(), {:send_subscriptions, asset_ids})
    end

    {:ok, %{state | subscribed_markets: updated}}
  end

  def handle_info({:unsubscribe_markets, asset_ids}, state) do
    to_remove = MapSet.new(asset_ids)
    updated = MapSet.difference(state.subscribed_markets, to_remove)
    {:ok, %{state | subscribed_markets: updated}}
  end

  def handle_info({:send_subscriptions, asset_ids}, state) do
    now = System.system_time(:millisecond)
    recent? = state.last_subscription_at && now - state.last_subscription_at < 60_000

    asset_ids = normalize_asset_ids(asset_ids, state)

    cond do
      asset_ids == [] ->
        {:ok, state}

      recent? ->
        {:ok, state}

      state.ws_ready ->
        {state, sent?} = send_subscriptions_now(asset_ids, state)

        state =
          if sent?, do: %{state | last_subscription_at: now}, else: state

        {:ok, state}

      true ->
        Logger.warning("[LiveOrders] Cannot subscribe - WebSocket not ready, will retry")
        Process.send_after(self(), {:send_subscriptions, asset_ids}, 2_000)
        {:ok, state}
    end
  end

  def handle_info({:retry_subscriptions, asset_ids, attempt}, state) do
    now = System.system_time(:millisecond)
    recent? = state.last_subscription_at && now - state.last_subscription_at < 60_000
    asset_ids = normalize_asset_ids(asset_ids, state)

    cond do
      asset_ids == [] ->
        {:ok, state}

      recent? ->
        {:ok, state}

      state.ws_ready and attempt <= 2 ->
        {state, sent?} = send_subscriptions_now(asset_ids, state)

        state =
          if sent? do
            stats =
              state.subscription_stats
              |> Map.update(:retries, 1, &(&1 + 1))

            %{state | subscription_stats: stats, last_subscription_at: now}
          else
            state
          end

        {:ok, state}

      true ->
        {:ok, state}
    end
  end

  def handle_info(:check_health, state) do
    now = System.system_time(:millisecond)
    last = state.last_message_at || now
    age = now - last

    if age > 15_000 do
      markets = MapSet.to_list(state.subscribed_markets)

      if markets != [] do
        Logger.warning(
          "[LiveOrders] No messages for #{div(age, 1000)}s; re-subscribing to #{length(markets)} markets"
        )

        send(self(), {:send_subscriptions, markets})
      end
    end

    health_timer = Process.send_after(self(), :check_health, 10_000)
    {:ok, %{state | health_timer: health_timer}}
  end

  def handle_info(_msg, state), do: {:ok, state}

  # Event handlers

  defp handle_event("last_trade_price", data, state) do
    asset_id = data["asset_id"]
    market_info = lookup_market_info(asset_id)
    price = parse_float(data["price"])

    if asset_id && price do
      order = %{
        id: System.unique_integer([:positive, :monotonic]),
        event_type: "trade",
        asset_id: asset_id,
        price: price,
        size: parse_float(data["size"]),
        side: data["side"],
        timestamp: data["timestamp"] || System.system_time(:millisecond),
        market_question: market_info[:question],
        event_title: market_info[:event_title],
        outcome: market_info[:outcome]
      }

      add_to_batch(order, state)
    else
      state
    end
  end

  defp handle_event("price_change", data, state) do
    price_changes = data["price_changes"] || []

    # if price_changes != [] do
    #   Logger.debug("[LiveOrders] Received price_change for #{length(price_changes)} assets")
    # end

    Enum.reduce(price_changes, state, fn change, acc ->
      asset_id = change["asset_id"]
      market_info = lookup_market_info(asset_id)

      best_bid = parse_float(change["best_bid"])
      best_ask = parse_float(change["best_ask"])
      price = parse_float(change["price"])
      size = parse_float(change["size"])

      # if best_bid || best_ask do
      #   Logger.debug(
      #     "[LiveOrders]   → #{market_info[:outcome] || "?"}: bid=#{best_bid}, ask=#{best_ask}"
      #   )
      # end

      cond do
        is_nil(asset_id) ->
          acc

        is_nil(best_bid) and is_nil(best_ask) and is_nil(price) ->
          # Drop malformed price update
          acc

        true ->
          order = %{
            id: System.unique_integer([:positive, :monotonic]),
            event_type: "price_change",
            asset_id: asset_id,
            price: price,
            size: size,
            side: change["side"],
            best_bid: best_bid,
            best_ask: best_ask,
            timestamp: data["timestamp"] || System.system_time(:millisecond),
            market_question: market_info[:question],
            event_title: market_info[:event_title],
            outcome: market_info[:outcome]
          }

          add_to_batch(order, acc)
      end
    end)
  end

  defp handle_event("book", data, state) do
    asset_id = data["asset_id"]
    bids = data["bids"] || []
    asks = data["asks"] || []

    best_bid = get_best_price(bids)
    best_ask = get_best_price(asks)

    if asset_id && (best_bid || best_ask) do
      market_info = lookup_market_info(asset_id)

      order = %{
        id: System.unique_integer([:positive, :monotonic]),
        event_type: "price_change",
        asset_id: asset_id,
        best_bid: best_bid,
        best_ask: best_ask,
        timestamp: System.system_time(:millisecond),
        market_question: market_info[:question],
        event_title: market_info[:event_title],
        outcome: market_info[:outcome]
      }

      add_to_batch(order, state)
    else
      state
    end
  end

  defp handle_event("tick_size_change", data, state) do
    Logger.info(
      "[LiveOrders] Tick size changed: #{data["old_tick_size"]} -> #{data["new_tick_size"]}"
    )

    state
  end

  defp handle_event(_event_type, _data, state), do: state

  # Helpers

  defp get_best_price([%{"price" => price} | _]) when is_binary(price) do
    case Float.parse(price) do
      {val, _} -> val
      :error -> nil
    end
  end

  defp get_best_price([%{"price" => price} | _]) when is_number(price), do: price
  defp get_best_price(_), do: nil

  defp normalize_asset_ids(asset_ids, state) do
    asset_ids
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.filter(fn id ->
      if MapSet.member?(state.subscribed_markets, id) do
        true
      else
        Logger.debug("[LiveOrders] Dropping unsubscribed asset_id=#{id}")
        false
      end
    end)
  end

  defp send_subscriptions_now(asset_ids, state) do
    # Polymarket WS expects the typo'd key `assets_ids`; send both for safety.
    payload = %{
      operation: "subscribe",
      type: "market",
      assets_ids: asset_ids,
      asset_ids: asset_ids
    }

    msg = Jason.encode!(payload)

    Logger.info("[LiveOrders] Subscribing to #{length(asset_ids)} markets")
    Logger.debug("[LiveOrders] Subscription message: #{msg}")

    Fresh.send(__MODULE__, {:text, msg})

    stats =
      state.subscription_stats
      |> Map.update(:attempts, 1, &(&1 + 1))

    {%{state | subscription_stats: stats}, true}
  rescue
    error ->
      Logger.error("[LiveOrders] Failed to encode subscription payload: #{inspect(error)}")
      {state, false}
  end

  defp add_to_batch(order, state) do
    new_batch = [order | state.order_batch]

    if length(new_batch) >= @max_batch_size do
      flush_order_batch(%{state | order_batch: new_batch})
    else
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

  defp flush_order_batch(%{order_batch: []} = state), do: %{state | batch_timer: nil}

  defp flush_order_batch(state) do
    orders = Enum.reverse(state.order_batch)

    case orders do
      [single_order] ->
        broadcast({:new_order, single_order})

      multiple_orders ->
        broadcast({:new_orders_batch, multiple_orders})
        Enum.each(multiple_orders, &broadcast({:new_order, &1}))
    end

    %{state | order_batch: [], batch_timer: nil}
  end

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

  defp parse_float(nil), do: nil

  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float(val) when is_number(val), do: val * 1.0
  defp parse_float(_), do: nil
end
