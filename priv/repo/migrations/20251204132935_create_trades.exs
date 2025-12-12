defmodule Polyx.Repo.Migrations.CreateTrades do
  use Ecto.Migration

  def change do
    create table(:trades) do
      # Common fields for all trade types
      # "copy" or "strategy"
      add :type, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :side, :string, null: false
      add :size, :decimal, null: false
      add :price, :decimal
      add :asset_id, :string
      add :market_id, :string
      add :order_id, :string
      add :pnl, :decimal
      add :executed_at, :utc_datetime
      add :error_message, :string

      # Market context
      add :title, :string
      add :outcome, :string
      add :event_slug, :string

      # Copy trade specific fields
      add :source_address, :string
      add :original_trade_id, :string
      add :original_size, :decimal
      add :original_price, :decimal

      # Strategy trade specific fields
      add :strategy_id, references(:strategies, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    # Indexes for common queries
    create index(:trades, [:type])
    create index(:trades, [:status])
    create index(:trades, [:inserted_at])
    create index(:trades, [:strategy_id])
    create index(:trades, [:source_address])
    create index(:trades, [:asset_id])

    # Unique constraint for copy trades to prevent duplicates
    create unique_index(:trades, [:original_trade_id], where: "original_trade_id IS NOT NULL")
  end
end
