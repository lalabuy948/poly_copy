defmodule Polyx.Repo.Migrations.RemoveDemoModeFromCopyTrades do
  use Ecto.Migration

  def change do
    alter table(:copy_trades) do
      remove :demo_mode, :boolean, default: false
    end
  end
end
