defmodule Polyx.Trades.Trade do
  @moduledoc """
  Unified trade schema for both copy trades and strategy trades.

  Trade types:
  - "copy" - Trades copied from tracked users
  - "strategy" - Trades executed by automated strategies
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @type t :: %__MODULE__{
          id: integer(),
          type: String.t(),
          # Common fields
          status: String.t(),
          side: String.t(),
          size: Decimal.t(),
          price: Decimal.t() | nil,
          asset_id: String.t() | nil,
          market_id: String.t() | nil,
          order_id: String.t() | nil,
          pnl: Decimal.t() | nil,
          executed_at: DateTime.t() | nil,
          error_message: String.t() | nil,
          # Market context
          title: String.t() | nil,
          outcome: String.t() | nil,
          event_slug: String.t() | nil,
          # Copy trade fields
          source_address: String.t() | nil,
          original_trade_id: String.t() | nil,
          original_size: Decimal.t() | nil,
          original_price: Decimal.t() | nil,
          # Strategy trade fields
          strategy_id: integer() | nil,
          strategy: Polyx.Strategies.Strategy.t() | nil,
          # Timestamps
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @copy_statuses ~w(pending executed simulated failed)
  @strategy_statuses ~w(pending submitted filled partial_fill cancelled failed simulated)
  @sides ~w(BUY SELL)

  schema "trades" do
    field :type, :string
    field :status, :string, default: "pending"
    field :side, :string
    field :size, :decimal
    field :price, :decimal
    field :asset_id, :string
    field :market_id, :string
    field :order_id, :string
    field :pnl, :decimal
    field :executed_at, :utc_datetime
    field :error_message, :string

    # Market context
    field :title, :string
    field :outcome, :string
    field :event_slug, :string

    # Copy trade specific
    field :source_address, :string
    field :original_trade_id, :string
    field :original_size, :decimal
    field :original_price, :decimal

    # Strategy trade specific
    belongs_to :strategy, Polyx.Strategies.Strategy

    timestamps(type: :utc_datetime)
  end

  # Copy trade changeset
  @copy_required [:source_address, :original_trade_id, :side, :size, :status]
  @copy_optional [
    :market_id,
    :asset_id,
    :original_size,
    :original_price,
    :price,
    :order_id,
    :pnl,
    :executed_at,
    :error_message,
    :title,
    :outcome,
    :event_slug
  ]

  @doc """
  Changeset for copy trades.
  """
  def copy_changeset(trade, attrs) do
    trade
    |> cast(attrs, @copy_required ++ @copy_optional)
    |> put_change(:type, "copy")
    |> validate_required(@copy_required)
    |> validate_inclusion(:status, @copy_statuses)
    |> unique_constraint(:original_trade_id)
  end

  # Strategy trade changeset
  @strategy_required [:market_id, :asset_id, :side, :price, :size]
  @strategy_optional [
    :status,
    :order_id,
    :pnl,
    :title,
    :outcome,
    :event_slug,
    :error_message,
    :executed_at
  ]

  @doc """
  Changeset for strategy trades.
  """
  def strategy_changeset(trade, attrs) do
    trade
    |> cast(attrs, @strategy_required ++ @strategy_optional)
    |> put_change(:type, "strategy")
    |> validate_required(@strategy_required)
    |> validate_inclusion(:status, @strategy_statuses)
    |> validate_inclusion(:side, @sides)
    |> validate_number(:price, greater_than: 0, less_than_or_equal_to: 1)
    |> validate_number(:size, greater_than: 0)
  end

  @doc """
  Changeset for updating trade status.
  """
  def status_changeset(trade, status, attrs \\ %{}) do
    all_statuses = Enum.uniq(@copy_statuses ++ @strategy_statuses)

    trade
    |> cast(Map.put(attrs, :status, status), [
      :status,
      :order_id,
      :pnl,
      :error_message,
      :executed_at
    ])
    |> validate_inclusion(:status, all_statuses)
  end

  # Copy trade queries

  @doc """
  Query for recent copy trades.
  """
  def recent_copy_trades(limit \\ 100) do
    from(t in __MODULE__,
      where: t.type == "copy",
      order_by: [desc: t.inserted_at],
      limit: ^limit
    )
  end

  @doc """
  Query for copy trades by status.
  """
  def copy_trades_by_status(status) do
    from(t in __MODULE__,
      where: t.type == "copy" and t.status == ^status,
      order_by: [desc: t.inserted_at]
    )
  end

  @doc """
  Check if a copy trade with the given original_trade_id already exists.
  """
  def copy_trade_exists?(original_trade_id) do
    from(t in __MODULE__,
      where: t.type == "copy" and t.original_trade_id == ^original_trade_id,
      select: true
    )
  end

  # Strategy trade queries

  @doc """
  Query for strategy trades by strategy_id.
  """
  def for_strategy(strategy_id) do
    from(t in __MODULE__,
      where: t.type == "strategy" and t.strategy_id == ^strategy_id,
      order_by: [desc: t.inserted_at]
    )
  end

  @doc """
  Query for recent strategy trades.
  """
  def recent_strategy_trades(limit \\ 100) do
    from(t in __MODULE__,
      where: t.type == "strategy",
      order_by: [desc: t.inserted_at],
      limit: ^limit
    )
  end

  # Format helpers

  @doc """
  Convert a copy trade to the map format expected by the UI/streams.
  """
  def to_copy_stream_format(%__MODULE__{type: "copy"} = trade) do
    %{
      id: to_string(trade.id),
      source_address: trade.source_address,
      original_trade_id: trade.original_trade_id,
      market: trade.market_id,
      asset_id: trade.asset_id,
      side: trade.side,
      original_size: decimal_to_float(trade.original_size),
      original_price: decimal_to_float(trade.original_price),
      copy_size: decimal_to_float(trade.size),
      status: String.to_existing_atom(trade.status),
      created_at: trade.inserted_at,
      executed_at: trade.executed_at,
      error_message: trade.error_message,
      title: trade.title,
      outcome: trade.outcome,
      event_slug: trade.event_slug
    }
  end

  defp decimal_to_float(nil), do: nil
  defp decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_float(n) when is_number(n), do: n
end
