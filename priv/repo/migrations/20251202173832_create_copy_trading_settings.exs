defmodule Polyx.Repo.Migrations.CreateCopyTradingSettings do
  use Ecto.Migration

  def change do
    create table(:copy_trading_settings) do
      add :key, :string, null: false
      add :sizing_mode, :string, null: false, default: "fixed"
      add :fixed_amount, :decimal, null: false, default: 10.0
      add :proportional_factor, :decimal, null: false, default: 0.1
      add :percentage, :decimal, null: false, default: 5.0
      add :enabled, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:copy_trading_settings, [:key])
  end
end
