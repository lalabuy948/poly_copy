defmodule Polyx.Repo.Migrations.CreateStrategyPositions do
  use Ecto.Migration

  def change do
    create table(:strategy_positions) do
      add :strategy_id, references(:strategies, on_delete: :delete_all), null: false
      add :market_id, :string, null: false
      add :token_id, :string, null: false
      add :side, :string, null: false
      add :size, :decimal, null: false, default: 0
      add :avg_price, :decimal, null: false, default: 0
      add :current_price, :decimal, default: 0
      add :unrealized_pnl, :decimal, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:strategy_positions, [:strategy_id])
    create index(:strategy_positions, [:market_id])
    create unique_index(:strategy_positions, [:strategy_id, :token_id])
  end
end
