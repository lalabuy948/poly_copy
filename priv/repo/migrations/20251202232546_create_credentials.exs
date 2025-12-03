defmodule Polyx.Repo.Migrations.CreateCredentials do
  use Ecto.Migration

  def change do
    create table(:credentials) do
      add :key, :string, default: "default"

      # Polymarket API credentials
      add :api_key, :string
      add :api_secret, :string
      add :api_passphrase, :string

      # Wallet configuration
      add :wallet_address, :string
      add :signer_address, :string
      add :private_key, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:credentials, [:key])
  end
end
