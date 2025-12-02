defmodule Polyx.CopyTrading.CopyTrade do
  @moduledoc """
  Schema for persisting copy trade records.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  schema "copy_trades" do
    field :source_address, :string
    field :original_trade_id, :string
    field :market, :string
    field :asset_id, :string
    field :side, :string
    field :original_size, :decimal
    field :original_price, :decimal
    field :copy_size, :decimal
    field :status, :string, default: "pending"
    field :executed_at, :utc_datetime
    field :error_message, :string
    field :title, :string
    field :outcome, :string
    field :event_slug, :string

    timestamps()
  end

  @required_fields [:source_address, :original_trade_id, :side, :copy_size, :status]
  @optional_fields [
    :market,
    :asset_id,
    :original_size,
    :original_price,
    :executed_at,
    :error_message,
    :title,
    :outcome,
    :event_slug
  ]

  def changeset(copy_trade, attrs) do
    copy_trade
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, ["pending", "executed", "simulated", "failed"])
    |> unique_constraint(:original_trade_id)
  end

  @doc """
  Query for recent copy trades, ordered by insertion time descending.
  """
  def recent(limit \\ 100) do
    from(ct in __MODULE__,
      order_by: [desc: ct.inserted_at],
      limit: ^limit
    )
  end

  @doc """
  Query for copy trades by status.
  """
  def by_status(status) do
    from(ct in __MODULE__,
      where: ct.status == ^status,
      order_by: [desc: ct.inserted_at]
    )
  end

  @doc """
  Check if a trade with the given original_trade_id already exists.
  """
  def exists?(original_trade_id) do
    from(ct in __MODULE__,
      where: ct.original_trade_id == ^original_trade_id,
      select: true
    )
  end

  @doc """
  Convert a database record to the map format expected by the UI/streams.
  """
  def to_stream_format(%__MODULE__{} = trade) do
    %{
      id: to_string(trade.id),
      source_address: trade.source_address,
      original_trade_id: trade.original_trade_id,
      market: trade.market,
      asset_id: trade.asset_id,
      side: trade.side,
      original_size: decimal_to_float(trade.original_size),
      original_price: decimal_to_float(trade.original_price),
      copy_size: decimal_to_float(trade.copy_size),
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
