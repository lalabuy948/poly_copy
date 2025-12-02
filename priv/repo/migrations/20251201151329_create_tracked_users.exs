defmodule Polyx.Repo.Migrations.CreateTrackedUsers do
  use Ecto.Migration

  def change do
    create table(:tracked_users) do
      add :address, :string, null: false
      add :label, :string
      add :active, :boolean, default: true, null: false

      timestamps()
    end

    create unique_index(:tracked_users, [:address])
  end
end
