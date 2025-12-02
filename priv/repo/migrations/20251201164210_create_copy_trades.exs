defmodule Polyx.Repo.Migrations.CreateCopyTrades do
  use Ecto.Migration

  def change do
    create table(:copy_trades) do
      add :source_address, :string, null: false
      add :original_trade_id, :string, null: false
      add :market, :string
      add :asset_id, :string
      add :side, :string, null: false
      add :original_size, :decimal
      add :original_price, :decimal
      add :copy_size, :decimal, null: false
      add :status, :string, null: false, default: "pending"
      add :demo_mode, :boolean, default: false
      add :executed_at, :utc_datetime
      add :error_message, :string

      timestamps()
    end

    # Index on original_trade_id to prevent duplicates
    create unique_index(:copy_trades, [:original_trade_id])
    # Index for querying by status
    create index(:copy_trades, [:status])
    # Index for querying recent trades
    create index(:copy_trades, [:inserted_at])
  end
end
