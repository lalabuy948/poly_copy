defmodule Polyx.Repo.Migrations.CreateStrategies do
  use Ecto.Migration

  def change do
    create table(:strategies) do
      add :name, :string, null: false
      add :type, :string, null: false
      add :config, :map, null: false, default: %{}
      add :status, :string, null: false, default: "stopped"
      add :paper_mode, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:strategies, [:type])
    create index(:strategies, [:status])
  end
end
