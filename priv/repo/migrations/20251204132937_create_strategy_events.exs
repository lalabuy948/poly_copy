defmodule Polyx.Repo.Migrations.CreateStrategyEvents do
  use Ecto.Migration

  def change do
    create table(:strategy_events) do
      add :strategy_id, references(:strategies, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :message, :string, null: false
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:strategy_events, [:strategy_id])
    create index(:strategy_events, [:type])
    create index(:strategy_events, [:inserted_at])
  end
end
