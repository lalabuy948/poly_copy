defmodule Polyx.Repo.Migrations.AddTitleOutcomeEventSlugToCopyTrades do
  use Ecto.Migration

  def change do
    alter table(:copy_trades) do
      add :title, :string
      add :outcome, :string
      add :event_slug, :string
    end
  end
end
