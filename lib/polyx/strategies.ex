defmodule Polyx.Strategies do
  @moduledoc """
  Context module for managing trading strategies.
  """
  import Ecto.Query
  alias Polyx.Repo
  alias Polyx.Strategies.{Strategy, Position, Event}
  alias Polyx.Trades.Trade

  # Strategy CRUD

  def list_strategies do
    Repo.all(Strategy)
  end

  def list_strategies_by_status(status) do
    Strategy
    |> where([s], s.status == ^status)
    |> Repo.all()
  end

  def get_strategy!(id), do: Repo.get!(Strategy, id)

  def get_strategy(id), do: Repo.get(Strategy, id)

  def create_strategy(attrs) do
    %Strategy{}
    |> Strategy.changeset(attrs)
    |> Repo.insert()
  end

  def update_strategy(%Strategy{} = strategy, attrs) do
    strategy
    |> Strategy.changeset(attrs)
    |> Repo.update()
  end

  def update_strategy_status(%Strategy{} = strategy, status) do
    strategy
    |> Strategy.status_changeset(status)
    |> Repo.update()
  end

  def delete_strategy(%Strategy{} = strategy) do
    Repo.delete(strategy)
  end

  # Trade operations

  def list_trades(strategy_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Trade
    |> where([t], t.type == "strategy" and t.strategy_id == ^strategy_id)
    |> order_by([t], desc: t.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def create_trade(%Strategy{} = strategy, attrs) do
    %Trade{strategy_id: strategy.id}
    |> Trade.strategy_changeset(attrs)
    |> Repo.insert()
  end

  def update_trade_status(%Trade{} = trade, status, attrs \\ %{}) do
    trade
    |> Trade.status_changeset(status, attrs)
    |> Repo.update()
  end

  def delete_trades(strategy_id) do
    Trade
    |> where([t], t.type == "strategy" and t.strategy_id == ^strategy_id)
    |> Repo.delete_all()
  end

  # Position operations

  def list_positions(strategy_id) do
    Position
    |> where([p], p.strategy_id == ^strategy_id)
    |> Repo.all()
  end

  def get_position(strategy_id, token_id) do
    Position
    |> where([p], p.strategy_id == ^strategy_id and p.token_id == ^token_id)
    |> Repo.one()
  end

  def upsert_position(%Strategy{} = strategy, attrs) do
    case get_position(strategy.id, attrs.token_id || attrs["token_id"]) do
      nil ->
        %Position{strategy_id: strategy.id}
        |> Position.changeset(attrs)
        |> Repo.insert()

      position ->
        position
        |> Position.update_changeset(attrs)
        |> Repo.update()
    end
  end

  def delete_position(%Position{} = position) do
    Repo.delete(position)
  end

  # Event logging

  def list_events(strategy_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Event
    |> where([e], e.strategy_id == ^strategy_id)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def log_event(%Strategy{} = strategy, type, message, metadata \\ %{}) do
    %Event{strategy_id: strategy.id}
    |> Event.changeset(%{type: type, message: message, metadata: metadata})
    |> Repo.insert()
  end

  # Strategy statistics

  def get_strategy_stats(strategy_id) do
    trades = Trade |> where([t], t.type == "strategy" and t.strategy_id == ^strategy_id)

    total_trades = Repo.aggregate(trades, :count)

    filled_trades =
      trades
      |> where([t], t.status == "filled")
      |> Repo.aggregate(:count)

    total_pnl =
      trades
      |> where([t], not is_nil(t.pnl))
      |> select([t], sum(t.pnl))
      |> Repo.one() || Decimal.new(0)

    %{
      total_trades: total_trades,
      filled_trades: filled_trades,
      total_pnl: total_pnl
    }
  end
end
