defmodule Polyx.CopyTrading do
  @moduledoc """
  Context module for copy trading functionality.
  Provides functions to manage tracked users and view trades.
  """

  alias Polyx.CopyTrading.{TradeWatcher, TradeExecutor}

  @doc """
  Add a user to track for copy trading.
  """
  def track_user(address, opts \\ []) do
    TradeWatcher.track_user(address, opts)
  end

  @doc """
  Remove a user from tracking.
  """
  def untrack_user(address) do
    TradeWatcher.untrack_user(address)
  end

  @doc """
  List all tracked users.
  """
  def list_tracked_users do
    TradeWatcher.list_tracked_users()
  end

  @doc """
  List all archived (inactive) users.
  """
  def list_archived_users do
    TradeWatcher.list_archived_users()
  end

  @doc """
  Restore an archived user to active tracking.
  """
  def restore_user(address) do
    TradeWatcher.restore_user(address)
  end

  @doc """
  Update the label for a tracked user.
  """
  def update_user_label(address, label) do
    TradeWatcher.update_user_label(address, label)
  end

  @doc """
  Get all trades for a tracked user.
  """
  def get_user_trades(address) do
    TradeWatcher.get_user_trades(address)
  end

  @doc """
  Get all copy trades executed.
  """
  def get_copy_trades do
    TradeExecutor.get_copy_trades()
  end

  @doc """
  Get current settings.
  """
  def get_settings do
    TradeExecutor.get_settings()
  end

  @doc """
  Update copy trading settings.

  Options:
    - :sizing_mode - :fixed, :proportional, :percentage
    - :fixed_amount - amount when sizing_mode is :fixed
    - :proportional_factor - factor when sizing_mode is :proportional (e.g., 0.1)
    - :percentage - percentage of balance when sizing_mode is :percentage
    - :enabled - whether to execute copy trades
  """
  def update_settings(opts) do
    TradeExecutor.update_settings(opts)
  end

  @doc """
  Manually copy a specific trade (bypasses enabled check).
  """
  def manual_copy_trade(address, trade) do
    TradeExecutor.execute_copy_trade(%{address: address, trade: trade}, force: true)
  end

  @doc """
  Retry a failed copy trade.
  """
  def retry_copy_trade(trade_id) do
    TradeExecutor.retry_copy_trade(trade_id)
  end

  @doc """
  Delete a failed copy trade.
  """
  def delete_copy_trade(trade_id) do
    TradeExecutor.delete_copy_trade(trade_id)
  end

  @doc """
  Subscribe to trade updates via PubSub.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(Polyx.PubSub, "copy_trading")
  end

  @doc """
  Broadcast a trade update to all subscribers.
  """
  def broadcast(event, payload) do
    Phoenix.PubSub.broadcast(Polyx.PubSub, "copy_trading", {event, payload})
  end
end
