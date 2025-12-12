defmodule PolyxWeb.ProfileLive do
  use PolyxWeb, :live_view

  require Logger

  alias Polyx.Polymarket.Client

  @impl true
  def mount(%{"address" => address}, _session, socket) do
    address = normalize_address(address)

    socket =
      socket
      |> assign(:page_title, "Profile Analysis")
      |> assign(:address, address)
      |> assign(:loading, true)
      |> assign(:loading_status, "Connecting to Polymarket API...")
      |> assign(:error, nil)
      |> assign(:trades, [])
      |> assign(:chart_data, nil)
      |> assign(:chart_data_raw, nil)
      |> assign(:stats, %{})
      |> assign(:selected_market, nil)
      |> assign(:markets, [])
      |> assign(:aggregation, "auto")
      |> assign(:tag_distribution, [])
      |> assign(:data_truncated, false)
      |> assign(:fetch_pid, nil)

    if connected?(socket) do
      send(self(), :fetch_trades)
    end

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    # Cancel in-progress fetch when leaving the page
    # The spawn_link will automatically die when LiveView dies,
    # but we log for visibility
    fetch_pid = Map.get(socket.assigns, :fetch_pid)

    if fetch_pid && Process.alive?(fetch_pid) do
      Logger.info("[Profile] Stopping fetch - user left page")
    end

    :ok
  end

  @impl true
  def handle_info(:fetch_trades, socket) do
    address = socket.assigns.address
    parent = self()

    Logger.info("[Profile] Starting data fetch for #{short_address(address)}")

    # Spawn a linked process to do the fetching
    # This allows us to kill it when the LiveView terminates
    fetch_pid =
      spawn_link(fn ->
        start_time = System.monotonic_time(:millisecond)
        max_activities = 100_000

        # Retry helper with exponential backoff
        fetch_with_retry = fn fetch_fn, label, max_retries ->
          Enum.reduce_while(1..max_retries, {:error, :no_attempts}, fn attempt, _acc ->
            t0 = System.monotonic_time(:millisecond)
            result = fetch_fn.()
            elapsed = System.monotonic_time(:millisecond) - t0

            case result do
              {:ok, data} when is_list(data) ->
                Logger.info("[Profile] #{label} completed: #{length(data)} items in #{elapsed}ms")
                {:halt, {:ok, data}}

              {:error, reason} when attempt < max_retries ->
                backoff = :timer.seconds(attempt * 2)

                Logger.warning(
                  "[Profile] #{label} failed (attempt #{attempt}/#{max_retries}): #{inspect(reason)}, retrying in #{div(backoff, 1000)}s"
                )

                Process.sleep(backoff)
                {:cont, {:error, reason}}

              {:error, reason} ->
                Logger.error(
                  "[Profile] #{label} failed after #{max_retries} attempts: #{inspect(reason)}"
                )

                {:halt, {:error, reason}}
            end
          end)
        end

        # Progress callback to update UI
        on_progress = fn progress ->
          send(parent, {:fetch_progress, progress})
        end

        # Fetch all data in parallel with retries
        activities_task =
          Task.async(fn ->
            result =
              fetch_with_retry.(
                fn ->
                  Client.get_activity(address,
                    max_activities: max_activities,
                    on_progress: on_progress
                  )
                end,
                "Activities fetch",
                3
              )

            count =
              case result do
                {:ok, list} -> length(list)
                _ -> 0
              end

            {result, count >= max_activities}
          end)

        positions_task =
          Task.async(fn ->
            fetch_with_retry.(
              fn -> Client.get_positions(address) end,
              "Positions fetch",
              3
            )
          end)

        closed_positions_task =
          Task.async(fn ->
            fetch_with_retry.(
              fn -> Client.get_closed_positions(address) end,
              "Closed positions fetch",
              3
            )
          end)

        # Wait for all tasks (up to 10 minutes for very large accounts)
        activities_result = Task.await(activities_task, 600_000)
        positions_result = Task.await(positions_task, 600_000)
        closed_positions_result = Task.await(closed_positions_task, 600_000)

        total_elapsed = System.monotonic_time(:millisecond) - start_time
        Logger.info("[Profile] All fetches completed in #{total_elapsed}ms")

        # Send results back to LiveView
        send(
          parent,
          {:fetch_complete, activities_result, positions_result, closed_positions_result}
        )
      end)

    {:noreply,
     socket
     |> assign(:loading_status, "Fetching trade history...")
     |> assign(:fetch_pid, fetch_pid)}
  end

  @impl true
  def handle_info(
        {:fetch_progress, %{batch: batch, total_batches: total, activities: count}},
        socket
      ) do
    count_str = format_number_with_commas(count, 0)

    status =
      if total <= 1 do
        "Loaded #{count_str} activities..."
      else
        "Fetching batch #{batch}/#{total} (#{count_str} activities)..."
      end

    {:noreply, assign(socket, :loading_status, status)}
  end

  @impl true
  def handle_info(
        {:fetch_complete, activities_result, positions_result, closed_positions_result},
        socket
      ) do
    # Clear the fetch_pid since fetch is complete
    socket = assign(socket, :fetch_pid, nil)

    case {activities_result, positions_result, closed_positions_result} do
      {{{:ok, activities}, hit_limit}, {:ok, positions}, {:ok, closed_positions}}
      when is_list(activities) ->
        # Parse all activities (TRADE and REDEEM)
        all_activities =
          activities
          |> Enum.map(&parse_activity/1)
          |> Enum.sort_by(& &1.timestamp, :asc)

        # Filter just trades for display
        trades = Enum.filter(all_activities, fn a -> a.type == "TRADE" end)

        # Group trades by market for market filter
        markets =
          trades
          |> Enum.map(& &1.title)
          |> Enum.uniq()
          |> Enum.reject(&is_nil/1)
          |> Enum.sort()

        # Calculate unrealized PnL from open positions (cashPnl field)
        unrealized_pnl =
          Enum.reduce(positions, 0.0, fn p, acc ->
            acc + (p["cashPnl"] || 0)
          end)

        # Calculate realized PnL from closed positions (realizedPnl field)
        realized_pnl =
          Enum.reduce(closed_positions, 0.0, fn p, acc ->
            acc + (p["realizedPnl"] || 0)
          end)

        chart_data_raw = compute_chart_data(all_activities, nil, unrealized_pnl, realized_pnl)
        aggregation = auto_select_aggregation(chart_data_raw)
        chart_data = apply_aggregation(chart_data_raw, aggregation)
        stats = compute_stats(trades)
        tag_distribution = compute_tag_distribution(trades)

        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:data_truncated, hit_limit)
         |> assign(:trades, trades)
         |> assign(:all_activities, all_activities)
         |> assign(:positions, positions)
         |> assign(:closed_positions, closed_positions)
         |> assign(:unrealized_pnl, unrealized_pnl)
         |> assign(:realized_pnl, realized_pnl)
         |> assign(:markets, markets)
         |> assign(:chart_data_raw, chart_data_raw)
         |> assign(:chart_data, chart_data)
         |> assign(:aggregation, aggregation)
         |> assign(:stats, stats)
         |> assign(:tag_distribution, tag_distribution)}

      {{{:ok, activities}, hit_limit}, _, _} when is_list(activities) ->
        # Positions failed but activities worked - use activity-based PnL calculation
        all_activities =
          activities
          |> Enum.map(&parse_activity/1)
          |> Enum.sort_by(& &1.timestamp, :asc)

        trades = Enum.filter(all_activities, fn a -> a.type == "TRADE" end)

        markets =
          trades
          |> Enum.map(& &1.title)
          |> Enum.uniq()
          |> Enum.reject(&is_nil/1)
          |> Enum.sort()

        chart_data_raw = compute_chart_data(all_activities, nil, 0.0, nil)
        aggregation = auto_select_aggregation(chart_data_raw)
        chart_data = apply_aggregation(chart_data_raw, aggregation)
        stats = compute_stats(trades)
        tag_distribution = compute_tag_distribution(trades)

        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:data_truncated, hit_limit)
         |> assign(:trades, trades)
         |> assign(:all_activities, all_activities)
         |> assign(:positions, [])
         |> assign(:closed_positions, [])
         |> assign(:unrealized_pnl, 0.0)
         |> assign(:realized_pnl, 0.0)
         |> assign(:markets, markets)
         |> assign(:chart_data_raw, chart_data_raw)
         |> assign(:chart_data, chart_data)
         |> assign(:aggregation, aggregation)
         |> assign(:stats, stats)
         |> assign(:tag_distribution, tag_distribution)}

      {{{:error, reason}, _}, _, _} ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:error, "Failed to fetch trades: #{inspect(reason)}")}

      _ ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:trades, [])
         |> assign(:chart_data, nil)}
    end
  end

  @impl true
  def handle_event("filter_market", %{"market" => ""}, socket) do
    all_activities = Map.get(socket.assigns, :all_activities, socket.assigns.trades)
    unrealized_pnl = Map.get(socket.assigns, :unrealized_pnl, 0.0)
    realized_pnl = Map.get(socket.assigns, :realized_pnl, nil)
    chart_data_raw = compute_chart_data(all_activities, nil, unrealized_pnl, realized_pnl)
    aggregation = auto_select_aggregation(chart_data_raw)
    chart_data = apply_aggregation(chart_data_raw, aggregation)
    filtered_trades = filter_trades(socket.assigns.trades, nil)
    stats = compute_stats(filtered_trades)
    tag_distribution = compute_tag_distribution(filtered_trades)

    {:noreply,
     socket
     |> assign(:selected_market, nil)
     |> assign(:chart_data_raw, chart_data_raw)
     |> assign(:chart_data, chart_data)
     |> assign(:aggregation, aggregation)
     |> assign(:stats, stats)
     |> assign(:tag_distribution, tag_distribution)}
  end

  @impl true
  def handle_event("filter_market", %{"market" => market}, socket) do
    all_activities = Map.get(socket.assigns, :all_activities, socket.assigns.trades)
    unrealized_pnl = Map.get(socket.assigns, :unrealized_pnl, 0.0)
    # When filtering by market, use activity-based PnL (realized_pnl from API is for all markets)
    chart_data_raw = compute_chart_data(all_activities, market, unrealized_pnl, nil)
    aggregation = auto_select_aggregation(chart_data_raw)
    chart_data = apply_aggregation(chart_data_raw, aggregation)
    filtered_trades = filter_trades(socket.assigns.trades, market)
    stats = compute_stats(filtered_trades)
    tag_distribution = compute_tag_distribution(filtered_trades)

    {:noreply,
     socket
     |> assign(:selected_market, market)
     |> assign(:chart_data_raw, chart_data_raw)
     |> assign(:chart_data, chart_data)
     |> assign(:aggregation, aggregation)
     |> assign(:stats, stats)
     |> assign(:tag_distribution, tag_distribution)}
  end

  @impl true
  def handle_event("set_aggregation", %{"period" => period}, socket) do
    chart_data_raw = socket.assigns.chart_data_raw

    if chart_data_raw do
      chart_data = apply_aggregation(chart_data_raw, period)

      Logger.debug(
        "Aggregation changed to #{period}: trade_points #{length(chart_data_raw.trade_points)} -> #{length(chart_data.trade_points)}"
      )

      {:noreply,
       socket
       |> assign(:chart_data, chart_data)
       |> assign(:aggregation, period)}
    else
      {:noreply, socket}
    end
  end

  defp parse_activity(act) do
    timestamp = parse_timestamp(act["timestamp"])
    size = parse_float(act["size"])
    price = parse_float(act["price"])
    usdc_size = parse_float(act["usdcSize"])

    %{
      type: act["type"],
      id: act["transactionHash"],
      title: act["title"],
      outcome: act["outcome"],
      side: act["side"],
      size: size,
      price: price,
      usdc_size: usdc_size,
      timestamp: timestamp,
      event_slug: act["eventSlug"],
      asset_id: act["asset"],
      condition_id: act["conditionId"]
    }
  end

  defp filter_trades(trades, nil), do: trades

  defp filter_trades(trades, market) do
    Enum.filter(trades, fn t -> t.title == market end)
  end

  defp filter_activities(activities, nil), do: activities

  defp filter_activities(activities, market) do
    Enum.filter(activities, fn a -> a.title == market end)
  end

  # realized_pnl_from_api: when not nil, use the API's closed-positions total instead of activity-based calculation
  defp compute_chart_data(activities, market_filter, unrealized_pnl, realized_pnl_from_api) do
    filtered_activities = filter_activities(activities, market_filter)
    # Only show trades in scatter chart, but process all activities for PnL
    filtered_trades = Enum.filter(filtered_activities, fn a -> a.type == "TRADE" end)

    if filtered_trades == [] do
      nil
    else
      # positions tracks per conditionId+outcome: %{"conditionId:outcome" => %{shares: x, cost: y}}
      initial_state = %{
        yes_shares: 0.0,
        no_shares: 0.0,
        yes_cost: 0.0,
        no_cost: 0.0,
        realized_pnl: 0.0,
        positions: %{}
      }

      {trade_points, final_cumulative, cumulative_data} =
        filtered_activities
        |> Enum.reduce(
          {[], initial_state, []},
          fn activity, {points, cumulative, cumulative_points} ->
            case activity.type do
              "TRADE" ->
                process_trade(activity, points, cumulative, cumulative_points)

              "REDEEM" ->
                process_redeem(activity, points, cumulative, cumulative_points)

              _ ->
                {points, cumulative, cumulative_points}
            end
          end
        )

      cumulative_reversed = Enum.reverse(cumulative_data)

      # Build exposure data from cumulative
      exposure_data =
        Enum.map(cumulative_reversed, fn c ->
          %{
            x: c.x,
            yes_exposure: c.yes_cost,
            no_exposure: c.no_cost,
            net_exposure: c.yes_cost + c.no_cost
          }
        end)

      # Build PnL data from cumulative using exposure-based calculation
      # PnL = potential_value - cost_spent
      # Potential value assumes current market prices from open positions
      # For historical points, we estimate based on shares held
      pnl_data =
        Enum.map(cumulative_reversed, fn c ->
          # Estimate position value: shares * estimated_price
          # Use 0.5 as default price estimate, but this gets adjusted later with API data
          yes_value = c.yes_shares * 0.5
          no_value = c.no_shares * 0.5
          potential_value = yes_value + no_value
          cost_spent = c.yes_cost + c.no_cost
          # Add any realized PnL from closed positions
          estimated_pnl = potential_value - cost_spent + c.realized_pnl

          %{
            x: c.x,
            realized_pnl: estimated_pnl
          }
        end)

      last_cumulative =
        if cumulative_reversed == [],
          do: initial_state,
          else: List.last(cumulative_reversed)

      # Debug: log cumulative values to understand PnL calculation
      if pnl_data != [] do
        last_pnl_point = List.last(pnl_data)

        Logger.debug(
          "[PnL Debug] Final cumulative: yes_shares=#{Float.round(last_cumulative.yes_shares, 2)}, " <>
            "no_shares=#{Float.round(last_cumulative.no_shares, 2)}, " <>
            "yes_cost=$#{Float.round(last_cumulative.yes_cost, 2)}, " <>
            "no_cost=$#{Float.round(last_cumulative.no_cost, 2)}, " <>
            "realized_pnl=$#{Float.round(last_cumulative.realized_pnl, 2)}"
        )

        Logger.debug(
          "[PnL Debug] Estimated PnL calc: potential=#{Float.round(last_cumulative.yes_shares * 0.5 + last_cumulative.no_shares * 0.5, 2)}, " <>
            "cost_spent=#{Float.round(last_cumulative.yes_cost + last_cumulative.no_cost, 2)}, " <>
            "estimated=$#{Float.round(last_pnl_point.realized_pnl, 2)}"
        )
      end

      # Use API-provided realized PnL if available (more accurate for large accounts)
      # Falls back to activity-based calculation when API data not available
      final_realized_pnl =
        if is_number(realized_pnl_from_api) do
          realized_pnl_from_api
        else
          last_cumulative.realized_pnl
        end

      # Total PnL = realized (from closed positions) + unrealized (from open positions)
      total_pnl = final_realized_pnl + unrealized_pnl

      # Adjust PnL data to match API's total PnL (realized + unrealized)
      # Scale the curve so the final point matches the API value
      adjusted_pnl_data =
        if pnl_data != [] do
          last_estimated_pnl = List.last(pnl_data).realized_pnl

          # Use API total PnL as target if available
          target_pnl = total_pnl

          if abs(last_estimated_pnl) > 0.01 do
            # Scale to match target
            scale = target_pnl / last_estimated_pnl

            # Log warning if scaling factor indicates significant data mismatch
            cond do
              scale > 2.0 or scale < 0.5 ->
                Logger.warning(
                  "[Profile] Large PnL scaling factor: #{Float.round(scale, 2)}x " <>
                    "(estimated: $#{Float.round(last_estimated_pnl, 2)}, target: $#{Float.round(target_pnl, 2)})"
                )

              scale > 1.1 or scale < 0.9 ->
                Logger.debug(
                  "[Profile] PnL scaling adjustment: #{Float.round(scale, 2)}x " <>
                    "(estimated: $#{Float.round(last_estimated_pnl, 2)}, target: $#{Float.round(target_pnl, 2)})"
                )

              true ->
                :ok
            end

            Enum.map(pnl_data, fn point ->
              %{point | realized_pnl: point.realized_pnl * scale}
            end)
          else
            # Can't scale from zero, use linear interpolation
            first_time = List.first(pnl_data).x
            last_time = List.last(pnl_data).x
            time_range = max(last_time - first_time, 1)

            Enum.map(pnl_data, fn point ->
              progress = (point.x - first_time) / time_range
              %{point | realized_pnl: target_pnl * progress}
            end)
          end
        else
          pnl_data
        end

      %{
        trade_points: Enum.reverse(trade_points),
        cumulative: cumulative_reversed,
        exposure: exposure_data,
        pnl: adjusted_pnl_data,
        final_state: %{
          yes_shares: final_cumulative.yes_shares,
          no_shares: final_cumulative.no_shares,
          yes_cost: final_cumulative.yes_cost,
          no_cost: final_cumulative.no_cost,
          total_cost: final_cumulative.yes_cost + final_cumulative.no_cost,
          realized_pnl: final_realized_pnl,
          unrealized_pnl: unrealized_pnl,
          total_pnl: total_pnl
        },
        total_points: length(cumulative_reversed)
      }
    end
  end

  # Auto-select aggregation based on number of data points AND time span
  defp auto_select_aggregation(nil), do: "all"

  defp auto_select_aggregation(chart_data) do
    total_points = Map.get(chart_data, :total_points, 0)
    pnl = Map.get(chart_data, :pnl, [])

    # Calculate time span to avoid collapsing all data into 1 point
    time_span_days =
      if length(pnl) >= 2 do
        first_x = List.first(pnl).x
        last_x = List.last(pnl).x
        (last_x - first_x) / (24 * 60 * 60 * 1000)
      else
        0
      end

    Logger.debug(
      "[Profile] Auto-select aggregation: #{total_points} points, #{Float.round(time_span_days, 1)} days span"
    )

    cond do
      # Not enough data for meaningful aggregation
      total_points < 100 -> "all"
      # Short time span - don't aggregate too aggressively
      time_span_days < 7 -> "all"
      time_span_days < 30 -> "daily"
      time_span_days < 180 -> "weekly"
      # Long history with many points
      total_points > 5000 -> "weekly"
      total_points > 1000 -> "daily"
      true -> "all"
    end
  end

  # Apply aggregation to chart data
  defp apply_aggregation(nil, _period), do: nil
  defp apply_aggregation(chart_data, "all"), do: chart_data

  defp apply_aggregation(chart_data, period) do
    aggregate_chart_data(chart_data, period)
  end

  # Aggregate chart data by time period to reduce points for large datasets
  # Uses calendar-aware bucketing (actual days/weeks/months, not fixed intervals)
  defp aggregate_chart_data(chart_data, period) when period in ["daily", "weekly", "monthly"] do
    # Debug: log timestamp range before aggregation
    if chart_data.trade_points != [] do
      timestamps = Enum.map(chart_data.trade_points, fn t -> t[:x] || t.x end)
      min_ts = Enum.min(timestamps)
      max_ts = Enum.max(timestamps)
      min_date = DateTime.from_unix!(min_ts, :millisecond)
      max_date = DateTime.from_unix!(max_ts, :millisecond)

      Logger.debug(
        "[Aggregation] period=#{period}, points=#{length(chart_data.trade_points)}, " <>
          "min_ts=#{min_ts} (#{min_date}), max_ts=#{max_ts} (#{max_date})"
      )
    end

    aggregated = %{
      chart_data
      | trade_points: aggregate_trades(chart_data.trade_points, period),
        cumulative: aggregate_cumulative(chart_data.cumulative, period),
        exposure: aggregate_exposure(chart_data.exposure, period),
        pnl: aggregate_pnl(chart_data.pnl, period)
    }

    Logger.debug(
      "[Aggregation] result: trade_points=#{length(aggregated.trade_points)}, " <>
        "cumulative=#{length(aggregated.cumulative)}, pnl=#{length(aggregated.pnl)}"
    )

    aggregated
  end

  defp aggregate_chart_data(chart_data, _period), do: chart_data

  # Calendar-aware bucket key - groups by actual date/week/month boundaries
  defp bucket_key(timestamp_ms, "daily") do
    timestamp_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  defp bucket_key(timestamp_ms, "weekly") do
    date =
      timestamp_ms
      |> DateTime.from_unix!(:millisecond)
      |> DateTime.to_date()

    # Get start of week (Monday)
    day_of_week = Date.day_of_week(date)
    days_to_monday = day_of_week - 1
    week_start = Date.add(date, -days_to_monday)
    Date.to_iso8601(week_start)
  end

  defp bucket_key(timestamp_ms, "monthly") do
    dt = DateTime.from_unix!(timestamp_ms, :millisecond)
    "#{dt.year}-#{String.pad_leading(Integer.to_string(dt.month), 2, "0")}"
  end

  defp bucket_key(timestamp_ms, _period), do: timestamp_ms

  # Aggregate trade points - group by calendar bucket, outcome, and side
  # Uses weighted average price (weighted by shares) for more accurate representation
  defp aggregate_trades(trades, period) do
    trades
    |> Enum.group_by(fn t ->
      # Group by calendar bucket, outcome, and side
      {bucket_key(t[:x] || t.x, period), t[:outcome], t[:side]}
    end)
    |> Enum.map(fn {{_bucket, outcome, side}, bucket_trades} ->
      # Calculate weighted average price (weighted by shares)
      total_shares = bucket_trades |> Enum.map(fn t -> t[:shares] || 0 end) |> Enum.sum()
      total_cost = bucket_trades |> Enum.map(fn t -> t[:cost] || 0 end) |> Enum.sum()

      # Use midpoint timestamp for the bucket
      timestamps = Enum.map(bucket_trades, fn t -> t[:x] || t.x end)
      avg_x = div(Enum.sum(timestamps), length(timestamps))

      # Weighted average price - if no shares, fall back to simple average
      avg_y =
        if total_shares > 0 do
          weighted_sum =
            bucket_trades
            |> Enum.map(fn t -> (t[:y] || t.y) * (t[:shares] || 1) end)
            |> Enum.sum()

          weighted_sum / total_shares
        else
          bucket_trades
          |> Enum.map(fn t -> t[:y] || t.y end)
          |> Enum.sum()
          |> Kernel./(length(bucket_trades))
        end

      %{
        x: avg_x,
        y: avg_y,
        outcome: outcome,
        side: side,
        shares: total_shares,
        cost: total_cost
      }
    end)
    |> Enum.sort_by(fn t -> t[:x] || t.x end)
  end

  # Aggregate cumulative data - take last value per calendar bucket
  defp aggregate_cumulative(cumulative, period) do
    cumulative
    |> Enum.group_by(fn c -> bucket_key(c.x, period) end)
    |> Enum.map(fn {_bucket, bucket_data} ->
      List.last(Enum.sort_by(bucket_data, & &1.x))
    end)
    |> Enum.sort_by(& &1.x)
  end

  # Aggregate exposure data - take last value per calendar bucket
  defp aggregate_exposure(exposure, period) do
    exposure
    |> Enum.group_by(fn e -> bucket_key(e.x, period) end)
    |> Enum.map(fn {_bucket, bucket_data} ->
      List.last(Enum.sort_by(bucket_data, & &1.x))
    end)
    |> Enum.sort_by(& &1.x)
  end

  # Aggregate PnL data - take last value per calendar bucket
  defp aggregate_pnl(pnl, period) do
    pnl
    |> Enum.group_by(fn p -> bucket_key(p.x, period) end)
    |> Enum.map(fn {_bucket, bucket_data} ->
      List.last(Enum.sort_by(bucket_data, & &1.x))
    end)
    |> Enum.sort_by(& &1.x)
  end

  defp process_trade(trade, points, cumulative, cumulative_points) do
    is_yes = trade.outcome in ["Yes", "yes", "YES"]
    is_buy = trade.side in ["BUY", "YES"]

    shares = trade.size
    cost = trade.usdc_size
    # Use conditionId + outcome for unique position tracking
    position_key = "#{trade.condition_id}:#{trade.outcome}"

    current_position =
      Map.get(cumulative.positions, position_key, %{shares: 0.0, cost: 0.0})

    {new_position, pnl_delta, shares_delta, cost_delta} =
      if is_buy do
        new_pos = %{
          shares: current_position.shares + shares,
          cost: current_position.cost + cost
        }

        {new_pos, 0.0, shares, cost}
      else
        # Selling - realize PnL
        avg_price =
          if current_position.shares > 0,
            do: current_position.cost / current_position.shares,
            else: 0.0

        sell_value = cost
        cost_basis = shares * avg_price
        pnl = sell_value - cost_basis

        new_shares = max(0, current_position.shares - shares)
        new_cost = max(0, current_position.cost - cost_basis)
        new_pos = %{shares: new_shares, cost: new_cost}

        {new_pos, pnl, -shares, -cost_basis}
      end

    new_positions = Map.put(cumulative.positions, position_key, new_position)

    {yes_shares_delta, yes_cost_delta, no_shares_delta, no_cost_delta} =
      if is_yes do
        {shares_delta, cost_delta, 0.0, 0.0}
      else
        {0.0, 0.0, shares_delta, cost_delta}
      end

    new_cumulative = %{
      cumulative
      | yes_shares: max(0, cumulative.yes_shares + yes_shares_delta),
        yes_cost: max(0, cumulative.yes_cost + yes_cost_delta),
        no_shares: max(0, cumulative.no_shares + no_shares_delta),
        no_cost: max(0, cumulative.no_cost + no_cost_delta),
        realized_pnl: cumulative.realized_pnl + pnl_delta,
        positions: new_positions
    }

    # Trade point for scatter chart
    point = %{
      x: trade.timestamp * 1000,
      y: trade.price * 100,
      side: trade.side,
      outcome: trade.outcome,
      shares: shares,
      cost: cost,
      title: trade.title
    }

    cumulative_point = %{
      x: trade.timestamp * 1000,
      yes_shares: new_cumulative.yes_shares,
      no_shares: new_cumulative.no_shares,
      yes_cost: new_cumulative.yes_cost,
      no_cost: new_cumulative.no_cost,
      realized_pnl: new_cumulative.realized_pnl
    }

    {[point | points], new_cumulative, [cumulative_point | cumulative_points]}
  end

  defp process_redeem(activity, points, cumulative, cumulative_points) do
    # REDEEM = market resolution. Find ALL matching positions by conditionId
    # (handles multi-outcome markets and partial redeems)
    condition_id = activity.condition_id
    usdc_received = activity.usdc_size

    # Find all positions matching this conditionId with shares > 0
    matching_positions =
      cumulative.positions
      |> Enum.filter(fn {k, v} ->
        String.starts_with?(k, condition_id) && v.shares > 0
      end)

    case matching_positions do
      [] ->
        # No matching position found
        {points, cumulative, cumulative_points}

      positions ->
        # Process all matching positions
        # Calculate total cost basis from all matching positions
        total_cost = Enum.reduce(positions, 0.0, fn {_k, v}, acc -> acc + v.cost end)

        # PnL = amount received - total cost basis
        pnl = usdc_received - total_cost

        # Aggregate share/cost deltas for all positions
        {yes_shares_delta, yes_cost_delta, no_shares_delta, no_cost_delta, new_positions} =
          Enum.reduce(positions, {0.0, 0.0, 0.0, 0.0, cumulative.positions}, fn
            {pos_key, pos}, {yes_s, yes_c, no_s, no_c, positions_acc} ->
              is_yes =
                String.contains?(pos_key, ":Yes") ||
                  String.contains?(pos_key, ":yes") ||
                  String.contains?(pos_key, ":YES")

              # Clear the position
              updated_positions = Map.put(positions_acc, pos_key, %{shares: 0.0, cost: 0.0})

              if is_yes do
                {yes_s - pos.shares, yes_c - pos.cost, no_s, no_c, updated_positions}
              else
                {yes_s, yes_c, no_s - pos.shares, no_c - pos.cost, updated_positions}
              end
          end)

        new_cumulative = %{
          cumulative
          | yes_shares: max(0, cumulative.yes_shares + yes_shares_delta),
            yes_cost: max(0, cumulative.yes_cost + yes_cost_delta),
            no_shares: max(0, cumulative.no_shares + no_shares_delta),
            no_cost: max(0, cumulative.no_cost + no_cost_delta),
            realized_pnl: cumulative.realized_pnl + pnl,
            positions: new_positions
        }

        # Add cumulative point for PnL chart (no trade point for scatter)
        cumulative_point = %{
          x: activity.timestamp * 1000,
          yes_shares: new_cumulative.yes_shares,
          no_shares: new_cumulative.no_shares,
          yes_cost: new_cumulative.yes_cost,
          no_cost: new_cumulative.no_cost,
          realized_pnl: new_cumulative.realized_pnl
        }

        {points, new_cumulative, [cumulative_point | cumulative_points]}
    end
  end

  defp compute_stats(trades) do
    if trades == [] do
      %{
        total_trades: 0,
        total_volume: 0.0,
        yes_buys: 0,
        no_buys: 0,
        unique_markets: 0
      }
    else
      yes_buys =
        Enum.count(trades, fn t ->
          t.outcome in ["Yes", "yes", "YES"] && t.side in ["BUY", "YES"]
        end)

      no_buys =
        Enum.count(trades, fn t ->
          t.outcome in ["No", "no", "NO"] && t.side in ["BUY", "NO"]
        end)

      total_volume = Enum.sum(Enum.map(trades, & &1.usdc_size))
      unique_markets = trades |> Enum.map(& &1.title) |> Enum.uniq() |> length()

      %{
        total_trades: length(trades),
        total_volume: total_volume,
        yes_buys: yes_buys,
        no_buys: no_buys,
        unique_markets: unique_markets
      }
    end
  end

  # Compute market tag distribution from trades
  # Tags are extracted from event_slug (e.g., "us-presidential-election-2024" -> "Politics")
  defp compute_tag_distribution(trades) do
    trades
    |> Enum.map(fn t -> categorize_market(t.event_slug || t.title || "unknown") end)
    |> Enum.frequencies()
    |> Enum.map(fn {tag, count} -> %{tag: tag, count: count} end)
    |> Enum.sort_by(& &1.count, :desc)
    |> Enum.take(10)
  end

  # Categorize a market based on event_slug keywords
  defp categorize_market(slug) when is_binary(slug) do
    slug_lower = String.downcase(slug)

    cond do
      # Politics & Elections
      String.contains?(slug_lower, [
        "trump",
        "biden",
        "harris",
        "desantis",
        "election",
        "president",
        "congress",
        "senate",
        "governor",
        "vote",
        "primary",
        "democrat",
        "republican",
        "gop",
        "poll",
        "nominee",
        "vance",
        "walz",
        "cabinet",
        "impeach"
      ]) ->
        "Politics"

      # Crypto & Blockchain
      String.contains?(slug_lower, [
        "bitcoin",
        "btc",
        "ethereum",
        "eth",
        "crypto",
        "solana",
        "sol",
        "token",
        "defi",
        "nft",
        "blockchain",
        "coinbase",
        "binance",
        "altcoin",
        "memecoin",
        "doge",
        "xrp",
        "cardano"
      ]) ->
        "Crypto"

      # Sports
      String.contains?(slug_lower, [
        "nfl",
        "nba",
        "mlb",
        "nhl",
        "mls",
        "ufc",
        "boxing",
        "soccer",
        "football",
        "basketball",
        "baseball",
        "hockey",
        "sports",
        "playoff",
        "championship",
        "super-bowl",
        "superbowl",
        "world-cup",
        "worldcup",
        "olympics",
        "f1",
        "formula",
        "nascar",
        "tennis",
        "golf",
        "pga",
        "premier-league",
        "champions-league",
        "world-series",
        "stanley-cup",
        "mvp",
        "finals"
      ]) ->
        "Sports"

      # Tech & AI
      String.contains?(slug_lower, [
        "ai",
        "openai",
        "gpt",
        "chatgpt",
        "claude",
        "anthropic",
        "tech",
        "apple",
        "google",
        "microsoft",
        "meta",
        "amazon",
        "nvidia",
        "tesla",
        "spacex",
        "iphone",
        "android",
        "software",
        "startup",
        "ipo"
      ]) ->
        "Tech"

      # Geopolitics & International
      String.contains?(slug_lower, [
        "war",
        "ukraine",
        "russia",
        "china",
        "conflict",
        "military",
        "nato",
        "israel",
        "gaza",
        "palestine",
        "iran",
        "korea",
        "taiwan",
        "invasion",
        "ceasefire",
        "sanctions"
      ]) ->
        "Geopolitics"

      # Economy & Finance
      String.contains?(slug_lower, [
        "fed",
        "federal-reserve",
        "interest",
        "inflation",
        "gdp",
        "unemployment",
        "recession",
        "cpi",
        "jobs",
        "payroll",
        "treasury",
        "debt",
        "deficit",
        "tariff"
      ]) ->
        "Economy"

      # Stock Markets
      String.contains?(slug_lower, [
        "stock",
        "s&p",
        "sp500",
        "dow",
        "nasdaq",
        "spy",
        "qqq",
        "earnings",
        "shares",
        "nyse",
        "market-cap"
      ]) ->
        "Markets"

      # Entertainment & Pop Culture
      String.contains?(slug_lower, [
        "twitter",
        "x-",
        "tiktok",
        "youtube",
        "social",
        "viral",
        "celebrity",
        "elon",
        "musk",
        "kanye",
        "taylor",
        "kardashian",
        "oscar",
        "grammy",
        "emmy",
        "movie",
        "film",
        "netflix",
        "disney",
        "streaming",
        "box-office",
        "album",
        "music",
        "concert",
        "tour"
      ]) ->
        "Entertainment"

      # Science & Space
      String.contains?(slug_lower, [
        "space",
        "nasa",
        "rocket",
        "mars",
        "moon",
        "asteroid",
        "launch",
        "orbit",
        "satellite",
        "starship",
        "artemis",
        "webb"
      ]) ->
        "Science"

      # Health & Medicine
      String.contains?(slug_lower, [
        "covid",
        "vaccine",
        "fda",
        "drug",
        "health",
        "disease",
        "virus",
        "pandemic",
        "cdc",
        "pfizer",
        "moderna",
        "treatment",
        "trial",
        "approval"
      ]) ->
        "Health"

      # Legal & Courts
      String.contains?(slug_lower, [
        "court",
        "supreme",
        "lawsuit",
        "trial",
        "judge",
        "ruling",
        "verdict",
        "indictment",
        "convicted",
        "guilty",
        "appeal",
        "scotus",
        "prosecution"
      ]) ->
        "Legal"

      # Weather & Climate
      String.contains?(slug_lower, [
        "weather",
        "climate",
        "hurricane",
        "earthquake",
        "disaster",
        "storm",
        "flood",
        "wildfire",
        "tornado",
        "temperature"
      ]) ->
        "Weather"

      # Regulation & Policy
      String.contains?(slug_lower, [
        "sec",
        "regulation",
        "ban",
        "law",
        "bill",
        "policy",
        "ftc",
        "antitrust",
        "legislation"
      ]) ->
        "Regulation"

      # Gaming & Esports
      String.contains?(slug_lower, [
        "esports",
        "gaming",
        "league-of-legends",
        "dota",
        "valorant",
        "twitch",
        "streamer",
        "video-game"
      ]) ->
        "Gaming"

      true ->
        "Other"
    end
  end

  defp categorize_market(_), do: "Other"

  defp parse_timestamp(nil), do: 0
  defp parse_timestamp(ts) when is_integer(ts), do: ts

  defp parse_timestamp(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_timestamp(_), do: 0

  defp parse_float(nil), do: 0.0

  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float(val) when is_number(val), do: val * 1.0
  defp parse_float(_), do: 0.0

  defp normalize_address(address) do
    address
    |> String.trim()
    |> String.downcase()
  end

  defp short_address(address) when is_binary(address) do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
  end

  defp short_address(_), do: "unknown"

  defp format_currency(amount) when is_number(amount) do
    amount
    |> abs()
    |> format_number_with_commas(2)
  end

  defp format_currency(_), do: "0.00"

  defp format_shares(shares) when is_number(shares) do
    cond do
      shares >= 1_000_000 -> format_number_with_commas(shares / 1_000_000, 1) <> "M"
      shares >= 1_000 -> format_number_with_commas(shares / 1_000, 1) <> "k"
      shares >= 1 -> format_number_with_commas(shares, 1)
      true -> format_number_with_commas(shares, 2)
    end
  end

  defp format_shares(_), do: "0"

  # Format integer with thousand separators (commas)
  defp format_integer(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> add_thousand_separators()
  end

  defp format_integer(number) when is_number(number) do
    number
    |> trunc()
    |> Integer.to_string()
    |> add_thousand_separators()
  end

  defp format_integer(_), do: "0"

  # Format number with thousand separators (commas)
  defp format_number_with_commas(number, decimals) do
    (number * 1.0)
    |> :erlang.float_to_binary(decimals: decimals)
    |> add_thousand_separators()
  end

  defp add_thousand_separators(number_str) do
    case String.split(number_str, ".") do
      [int_part, dec_part] ->
        formatted_int =
          int_part
          |> String.graphemes()
          |> Enum.reverse()
          |> Enum.chunk_every(3)
          |> Enum.map(&Enum.join/1)
          |> Enum.join(",")
          |> String.reverse()

        "#{formatted_int}.#{dec_part}"

      [int_part] ->
        int_part
        |> String.graphemes()
        |> Enum.reverse()
        |> Enum.chunk_every(3)
        |> Enum.map(&Enum.join/1)
        |> Enum.join(",")
        |> String.reverse()
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="min-h-screen">
        <%!-- Header --%>
        <div class="border-b border-base-300 bg-base-100/80 backdrop-blur-sm sticky top-0 z-10">
          <div class="max-w-7xl mx-auto px-4 py-4">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-4">
                <.link
                  navigate={~p"/"}
                  class="p-2 rounded-xl bg-base-200 hover:bg-base-300 transition-colors"
                >
                  <.icon name="hero-arrow-left" class="size-5" />
                </.link>
                <div>
                  <h1 class="text-xl font-bold tracking-tight">Profile Analysis</h1>
                  <div class="flex items-center gap-2 mt-0.5">
                    <span class="text-sm text-base-content/60 font-mono">
                      {short_address(@address)}
                    </span>
                    <a
                      href={"https://polymarket.com/profile/#{@address}"}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="text-primary hover:text-primary/80 transition-colors"
                    >
                      <.icon name="hero-arrow-top-right-on-square" class="size-4" />
                    </a>
                  </div>
                </div>
              </div>

              <div class="flex items-center gap-3">
                <%!-- Aggregation Period --%>
                <div :if={@chart_data_raw} class="flex items-center gap-2">
                  <span class="text-xs text-base-content/50">
                    {length(@chart_data.pnl)} pts
                  </span>
                  <div class="flex items-center gap-1 bg-base-200 rounded-lg p-1">
                    <button
                      :for={
                        {label, value} <- [
                          {"Daily", "daily"},
                          {"Weekly", "weekly"},
                          {"Monthly", "monthly"},
                          {"All", "all"}
                        ]
                      }
                      type="button"
                      phx-click="set_aggregation"
                      phx-value-period={value}
                      class={[
                        "px-3 py-1 text-xs font-medium rounded-md transition-colors",
                        @aggregation == value && "bg-primary text-primary-content",
                        @aggregation != value && "hover:bg-base-300"
                      ]}
                    >
                      {label}
                    </button>
                  </div>
                </div>

                <%!-- Market Filter --%>
                <div :if={@markets != []} class="relative">
                  <select
                    phx-change="filter_market"
                    name="market"
                    class="select select-bordered select-sm bg-base-200 min-w-[200px] max-w-[300px]"
                  >
                    <option value="">All Markets ({length(@markets)})</option>
                    <option
                      :for={market <- @markets}
                      value={market}
                      selected={@selected_market == market}
                    >
                      {String.slice(market || "", 0, 40)}{if String.length(market || "") > 40,
                        do: "...",
                        else: ""}
                    </option>
                  </select>
                </div>

                <%!-- Theme Toggle --%>
                <button
                  type="button"
                  id="profile-theme-toggle"
                  phx-click={JS.dispatch("phx:toggle-theme")}
                  class="p-2.5 rounded-xl bg-base-300/50 hover:bg-base-300 transition-colors"
                  title="Toggle theme"
                >
                  <.icon
                    name="hero-sun"
                    class="size-5 text-warning hidden [[data-theme=dark]_&]:block"
                  />
                  <.icon
                    name="hero-moon"
                    class="size-5 text-primary block [[data-theme=dark]_&]:hidden"
                  />
                </button>
              </div>
            </div>
          </div>
        </div>

        <%!-- Main Content --%>
        <div class="max-w-7xl mx-auto px-4 py-6">
          <%!-- Loading State --%>
          <div :if={@loading} class="flex items-center justify-center py-20">
            <div class="text-center">
              <span class="loading loading-spinner loading-lg text-primary"></span>
              <p class="mt-4 text-base-content/60">{@loading_status}</p>
              <p class="mt-2 text-xs text-base-content/40">
                Please wait - refreshing will restart the fetch
              </p>
            </div>
          </div>

          <%!-- Error State --%>
          <div :if={@error} class="alert alert-error">
            <.icon name="hero-exclamation-circle" class="size-5" />
            <span>{@error}</span>
          </div>

          <%!-- Data Truncated Warning --%>
          <div
            :if={@data_truncated}
            class="mb-4 p-3 rounded-xl bg-warning/10 border border-warning/20 flex items-center gap-3"
          >
            <.icon name="hero-exclamation-triangle" class="size-5 text-warning flex-shrink-0" />
            <p class="text-sm text-warning">
              This profile has more activity than we could fetch. Showing the most recent 100,000 activities.
            </p>
          </div>

          <%!-- Stats Cards --%>
          <div :if={!@loading && @chart_data} class="grid grid-cols-2 md:grid-cols-5 gap-4 mb-6">
            <div class="rounded-xl bg-base-200/50 border border-base-300 p-4">
              <p class="text-xs text-base-content/60 uppercase tracking-wide">Total Trades</p>
              <p class="text-2xl font-bold mt-1">{format_integer(@stats.total_trades)}</p>
            </div>
            <div class="rounded-xl bg-base-200/50 border border-base-300 p-4">
              <p class="text-xs text-base-content/60 uppercase tracking-wide">Volume</p>
              <p class="text-2xl font-bold mt-1">${format_currency(@stats.total_volume)}</p>
            </div>
            <div class="rounded-xl bg-success/10 border border-success/20 p-4">
              <p class="text-xs text-success uppercase tracking-wide">YES Buys</p>
              <p class="text-2xl font-bold mt-1 text-success">{format_integer(@stats.yes_buys)}</p>
            </div>
            <div class="rounded-xl bg-error/10 border border-error/20 p-4">
              <p class="text-xs text-error uppercase tracking-wide">NO Buys</p>
              <p class="text-2xl font-bold mt-1 text-error">{format_integer(@stats.no_buys)}</p>
            </div>
            <div class="rounded-xl bg-base-200/50 border border-base-300 p-4">
              <p class="text-xs text-base-content/60 uppercase tracking-wide">Markets</p>
              <p class="text-2xl font-bold mt-1">{format_integer(@stats.unique_markets)}</p>
            </div>
          </div>

          <%!-- Final Position Summary --%>
          <div
            :if={@chart_data}
            class="mb-6 p-4 rounded-xl bg-gradient-to-r from-primary/5 to-secondary/5 border border-primary/10"
          >
            <div class="flex items-center justify-between flex-wrap gap-4">
              <div class="flex items-center gap-6">
                <div>
                  <p class="text-xs text-base-content/60">YES Position</p>
                  <p class="text-lg font-semibold text-success">
                    {format_shares(@chart_data.final_state.yes_shares)} shares
                    <span class="text-sm text-base-content/50">
                      (${format_currency(@chart_data.final_state.yes_cost)})
                    </span>
                  </p>
                </div>
                <div>
                  <p class="text-xs text-base-content/60">NO Position</p>
                  <p class="text-lg font-semibold text-error">
                    {format_shares(@chart_data.final_state.no_shares)} shares
                    <span class="text-sm text-base-content/50">
                      (${format_currency(@chart_data.final_state.no_cost)})
                    </span>
                  </p>
                </div>
              </div>
              <div class="text-right">
                <p class="text-xs text-base-content/60">Total Exposure</p>
                <p class="text-xl font-bold">
                  ${format_currency(@chart_data.final_state.total_cost)}
                </p>
              </div>
            </div>
          </div>

          <%!-- Charts Grid --%>
          <div
            :if={@chart_data}
            id={"charts-grid-#{@aggregation}"}
            class="grid grid-cols-1 lg:grid-cols-2 gap-6"
          >
            <%!-- Trade Dots Chart --%>
            <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
              <div class="px-5 py-4 border-b border-base-300">
                <div class="flex items-center gap-2">
                  <.icon name="hero-chart-bar" class="size-5 text-primary" />
                  <h2 class="font-semibold">Trade History</h2>
                </div>
                <p class="text-xs text-base-content/50 mt-1">
                  Individual trade entries (price over time)
                </p>
              </div>
              <div class="p-4">
                <div
                  id="trade-dots-chart"
                  phx-hook="TradeDotsChart"
                  data-trades={Jason.encode!(@chart_data.trade_points)}
                  class="h-[300px]"
                >
                </div>
              </div>
            </div>

            <%!-- Market Tags Chart --%>
            <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
              <div class="px-5 py-4 border-b border-base-300">
                <div class="flex items-center gap-2">
                  <.icon name="hero-tag" class="size-5 text-violet-500" />
                  <h2 class="font-semibold">Market Categories</h2>
                </div>
                <p class="text-xs text-base-content/50 mt-1">
                  Distribution of trades by market category
                </p>
              </div>
              <div class="p-4">
                <div
                  id="market-tags-chart"
                  phx-hook="MarketTagsChart"
                  data-tags={Jason.encode!(@tag_distribution)}
                  class="h-[300px]"
                >
                </div>
              </div>
            </div>

            <%!-- Cumulative Shares Chart --%>
            <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
              <div class="px-5 py-4 border-b border-base-300">
                <div class="flex items-center gap-2">
                  <.icon name="hero-arrow-trending-up" class="size-5 text-info" />
                  <h2 class="font-semibold">Cumulative Shares</h2>
                </div>
                <p class="text-xs text-base-content/50 mt-1">
                  Running total of YES and NO shares held
                </p>
              </div>
              <div class="p-4">
                <div
                  id="cumulative-shares-chart"
                  phx-hook="CumulativeSharesChart"
                  data-cumulative={Jason.encode!(@chart_data.cumulative)}
                  class="h-[300px]"
                >
                </div>
              </div>
            </div>

            <%!-- Cumulative Dollars Chart --%>
            <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
              <div class="px-5 py-4 border-b border-base-300">
                <div class="flex items-center gap-2">
                  <.icon name="hero-banknotes" class="size-5 text-warning" />
                  <h2 class="font-semibold">Cumulative Dollars Spent</h2>
                </div>
                <p class="text-xs text-base-content/50 mt-1">Total cost basis over time</p>
              </div>
              <div class="p-4">
                <div
                  id="cumulative-dollars-chart"
                  phx-hook="CumulativeDollarsChart"
                  data-cumulative={Jason.encode!(@chart_data.cumulative)}
                  class="h-[300px]"
                >
                </div>
              </div>
            </div>

            <%!-- Exposure Chart --%>
            <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
              <div class="px-5 py-4 border-b border-base-300">
                <div class="flex items-center gap-2">
                  <.icon name="hero-scale" class="size-5 text-secondary" />
                  <h2 class="font-semibold">Dollar Exposure</h2>
                </div>
                <p class="text-xs text-base-content/50 mt-1">
                  YES/NO exposure and net position over time
                </p>
              </div>
              <div class="p-4">
                <div
                  id="exposure-chart"
                  phx-hook="ExposureChart"
                  data-exposure={Jason.encode!(@chart_data.exposure)}
                  class="h-[300px]"
                >
                </div>
              </div>
            </div>

            <%!-- PnL Chart --%>
            <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
              <div class="px-5 py-4 border-b border-base-300">
                <div class="flex items-center justify-between">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-currency-dollar" class="size-5 text-success" />
                    <h2 class="font-semibold">Profit & Loss</h2>
                  </div>
                  <span class={[
                    "text-lg font-bold",
                    @chart_data.final_state.total_pnl >= 0 && "text-success",
                    @chart_data.final_state.total_pnl < 0 && "text-error"
                  ]}>
                    {if @chart_data.final_state.total_pnl >= 0, do: "+", else: "-"}${format_currency(
                      @chart_data.final_state.total_pnl
                    )}
                  </span>
                </div>
                <p class="text-xs text-base-content/50 mt-1">
                  Realized: {if @chart_data.final_state.realized_pnl >= 0, do: "+", else: "-"}${format_currency(
                    @chart_data.final_state.realized_pnl
                  )} | Unrealized: {if @chart_data.final_state.unrealized_pnl >= 0, do: "+", else: "-"}${format_currency(
                    @chart_data.final_state.unrealized_pnl
                  )}
                </p>
              </div>
              <div class="p-4">
                <div
                  id="pnl-chart"
                  phx-hook="PnLChart"
                  data-pnl={Jason.encode!(@chart_data.pnl)}
                  class="h-[300px]"
                >
                </div>
              </div>
            </div>
          </div>

          <%!-- Empty State --%>
          <div :if={!@loading && !@chart_data && !@error} class="text-center py-20">
            <div class="w-20 h-20 rounded-2xl bg-base-300/50 flex items-center justify-center mx-auto mb-4">
              <.icon name="hero-chart-bar" class="size-10 text-base-content/30" />
            </div>
            <p class="text-xl font-medium text-base-content/60">No trades found</p>
            <p class="text-base-content/40 mt-2">
              This wallet hasn't made any trades on Polymarket yet.
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
