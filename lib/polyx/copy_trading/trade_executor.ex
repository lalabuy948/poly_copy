defmodule Polyx.CopyTrading.TradeExecutor do
  @moduledoc """
  GenServer that executes copy trades based on tracked user activity.
  Supports different sizing modes: fixed, proportional, and percentage.
  Persists trades to the database to prevent duplicates on restart.
  """

  use GenServer
  require Logger

  alias Polyx.Polymarket.Client
  alias Polyx.CopyTrading
  alias Polyx.CopyTrading.{CopyTrade, Settings}
  alias Polyx.Repo

  defstruct settings: %{
              sizing_mode: :fixed,
              fixed_amount: 10.0,
              proportional_factor: 0.1,
              percentage: 5.0,
              enabled: false
            },
            balance: 0.0

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_settings do
    GenServer.call(__MODULE__, :get_settings)
  end

  def update_settings(opts) do
    GenServer.call(__MODULE__, {:update_settings, opts})
  end

  def get_copy_trades do
    # Load from database instead of GenServer state
    CopyTrade.recent(100)
    |> Repo.all()
    |> Enum.map(&CopyTrade.to_stream_format/1)
  end

  def execute_copy_trade(original_trade, opts \\ []) do
    force = Keyword.get(opts, :force, false)
    GenServer.cast(__MODULE__, {:execute_copy_trade, original_trade, force})
  end

  def retry_copy_trade(trade_id) do
    GenServer.call(__MODULE__, {:retry_copy_trade, trade_id})
  end

  def delete_copy_trade(trade_id) do
    GenServer.call(__MODULE__, {:delete_copy_trade, trade_id})
  end

  def delete_all_failed_copy_trades do
    GenServer.call(__MODULE__, :delete_all_failed_copy_trades)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Subscribe to trade events
    CopyTrading.subscribe()

    # Load settings from database
    settings = Settings.get_or_create() |> Settings.to_map()

    {:ok, %__MODULE__{settings: settings}}
  end

  @impl true
  def handle_call(:get_settings, _from, state) do
    {:reply, state.settings, state}
  end

  @impl true
  def handle_call({:update_settings, opts}, _from, state) do
    case Settings.update(opts) do
      {:ok, new_settings} ->
        Logger.info("Updated copy trading settings: #{inspect(new_settings)}")
        CopyTrading.broadcast(:settings_updated, new_settings)
        {:reply, {:ok, new_settings}, %{state | settings: new_settings}}

      {:error, _changeset} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:retry_copy_trade, trade_id}, _from, state) do
    case Repo.get(CopyTrade, trade_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %CopyTrade{status: "failed"} = db_trade ->
        # Retry the trade - apply tick size rounding to price
        price = db_trade.original_price |> decimal_to_float() |> round_to_tick_size()

        {new_status, executed_at, error_msg} =
          case Client.place_order(%{
                 token_id: db_trade.asset_id,
                 side: db_trade.side,
                 size: Decimal.to_float(db_trade.copy_size),
                 price: price
               }) do
            {:ok, _result} ->
              {"executed", DateTime.utc_now(), nil}

            {:error, reason} ->
              {"failed", DateTime.utc_now(), inspect(reason)}
          end

        # Update the database record
        {:ok, updated_trade} =
          db_trade
          |> CopyTrade.changeset(%{
            status: new_status,
            executed_at: executed_at,
            error_message: error_msg
          })
          |> Repo.update()

        stream_trade = CopyTrade.to_stream_format(updated_trade)
        CopyTrading.broadcast(:copy_trade_updated, stream_trade)

        {:reply, {:ok, stream_trade}, state}

      %CopyTrade{} ->
        {:reply, {:error, :not_failed}, state}
    end
  end

  @impl true
  def handle_call({:delete_copy_trade, trade_id}, _from, state) do
    case Repo.get(CopyTrade, trade_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %CopyTrade{status: "failed"} = db_trade ->
        case Repo.delete(db_trade) do
          {:ok, deleted_trade} ->
            stream_trade = CopyTrade.to_stream_format(deleted_trade)
            CopyTrading.broadcast(:copy_trade_deleted, stream_trade)
            {:reply, {:ok, stream_trade}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      %CopyTrade{} ->
        {:reply, {:error, :not_failed}, state}
    end
  end

  @impl true
  def handle_call(:delete_all_failed_copy_trades, _from, state) do
    import Ecto.Query

    failed_trades =
      CopyTrade
      |> where([t], t.status == "failed")
      |> Repo.all()

    if failed_trades == [] do
      {:reply, {:ok, 0}, state}
    else
      # Delete all failed trades and broadcast deletions
      Enum.each(failed_trades, fn db_trade ->
        case Repo.delete(db_trade) do
          {:ok, deleted_trade} ->
            stream_trade = CopyTrade.to_stream_format(deleted_trade)
            CopyTrading.broadcast(:copy_trade_deleted, stream_trade)

          {:error, _reason} ->
            :ok
        end
      end)

      {:reply, {:ok, length(failed_trades)}, state}
    end
  end

  @impl true
  def handle_cast({:execute_copy_trade, %{address: source_address, trade: trade}, force}, state) do
    if force or state.settings.enabled do
      {:noreply, do_execute_copy_trade(state, source_address, trade)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:new_trade, %{address: source_address, trade: trade}}, state) do
    if state.settings.enabled do
      {:noreply, do_execute_copy_trade(state, source_address, trade)}
    else
      Logger.debug("Copy trading disabled, ignoring trade from #{source_address}")
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:user_tracked, _user_info}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:user_untracked, _user_info}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:user_deleted, _user_info}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:settings_updated, _settings}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:copy_trade_executed, _trade}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:copy_trade_updated, _trade}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:copy_trade_deleted, _trade}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:trades_updated, _payload}, state) do
    {:noreply, state}
  end

  # Private functions

  defp do_execute_copy_trade(state, source_address, original_trade) do
    original_trade_id = original_trade["id"]

    # Check if we already copied this trade (prevent duplicates)
    if Repo.exists?(CopyTrade.exists?(original_trade_id)) do
      Logger.info("Trade #{original_trade_id} already copied, skipping duplicate")
      state
    else
      price = parse_price(original_trade["price"])
      size = calculate_size(state.settings, original_trade, price)

      Logger.info(
        "Copying trade: #{original_trade["side"]} #{size} shares @ #{price} " <>
          "(original: #{original_trade["size"]} shares)"
      )

      # Execute the trade
      {status, executed_at, error_msg} =
        case Client.place_order(%{
               token_id: original_trade["asset_id"],
               side: original_trade["side"],
               size: size,
               price: price
             }) do
          {:ok, _result} ->
            {"executed", DateTime.utc_now(), nil}

          {:error, reason} ->
            Logger.error("Failed to execute copy trade: #{inspect(reason)}")
            {"failed", DateTime.utc_now(), inspect(reason)}
        end

      # Save to database
      attrs = %{
        source_address: source_address,
        original_trade_id: original_trade_id,
        market: original_trade["market"],
        asset_id: original_trade["asset_id"],
        side: original_trade["side"],
        original_size: parse_size(original_trade["size"]),
        original_price: parse_price(original_trade["price"]),
        copy_size: size,
        status: status,
        executed_at: executed_at,
        error_message: error_msg,
        title: original_trade["title"],
        outcome: original_trade["outcome"],
        event_slug: original_trade["event_slug"]
      }

      case %CopyTrade{} |> CopyTrade.changeset(attrs) |> Repo.insert() do
        {:ok, db_trade} ->
          stream_trade = CopyTrade.to_stream_format(db_trade)
          CopyTrading.broadcast(:copy_trade_executed, stream_trade)
          state

        {:error, changeset} ->
          Logger.error("Failed to save copy trade: #{inspect(changeset.errors)}")
          state
      end
    end
  end

  # Polymarket minimum order size is 5 SHARES (not dollars)
  # At typical prices, this is roughly $0.50 to $5 depending on price
  @min_order_shares 5.0

  defp calculate_size(settings, original_trade, price) do
    original_size = parse_size(original_trade["size"])

    # Calculate dollar amount based on sizing mode
    dollar_amount =
      case settings.sizing_mode do
        :fixed ->
          settings.fixed_amount

        :proportional ->
          # Original size is in shares, convert to dollars first
          original_dollar_value = original_size * price
          original_dollar_value * settings.proportional_factor

        :percentage ->
          # In a real implementation, we would fetch the actual balance
          # For now, use a placeholder
          balance = 1000.0
          balance * (settings.percentage / 100)
      end

    # Convert dollar amount to shares: shares = dollars / price
    shares = if price > 0, do: dollar_amount / price, else: dollar_amount

    # Enforce minimum of 5 shares (Polymarket API requirement)
    max(shares, @min_order_shares)
  end

  defp parse_size(size) when is_binary(size), do: String.to_float(size)
  defp parse_size(size) when is_number(size), do: size
  defp parse_size(_), do: 0.0

  defp parse_price(price) when is_binary(price) do
    price |> String.to_float() |> round_to_tick_size()
  end

  defp parse_price(price) when is_number(price), do: round_to_tick_size(price)
  defp parse_price(_), do: 0.0

  # Round price to minimum tick size of 0.001 (3 decimal places)
  # Price must be > 0 and < 1, so we floor to avoid rounding up to 1.0
  defp round_to_tick_size(price) do
    rounded = Float.floor(price * 1000) / 1000
    # Ensure price stays within valid bounds (0, 1)
    cond do
      rounded >= 1.0 -> 0.999
      rounded <= 0.0 -> 0.001
      true -> rounded
    end
  end

  defp decimal_to_float(nil), do: nil
  defp decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_float(n) when is_number(n), do: n
end
