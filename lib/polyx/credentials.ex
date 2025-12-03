defmodule Polyx.Credentials do
  @moduledoc """
  Schema and functions for managing Polymarket API credentials.
  Credentials are stored in the database instead of .env files.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Polyx.Repo

  schema "credentials" do
    field :key, :string, default: "default"

    # Polymarket API credentials
    field :api_key, :string
    field :api_secret, :string
    field :api_passphrase, :string

    # Wallet configuration
    field :wallet_address, :string
    field :signer_address, :string
    field :private_key, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(credentials, attrs) do
    credentials
    |> cast(attrs, [
      :key,
      :api_key,
      :api_secret,
      :api_passphrase,
      :wallet_address,
      :signer_address,
      :private_key
    ])
    |> validate_required([:key])
    |> unique_constraint(:key)
    |> validate_wallet_address(:wallet_address)
    |> validate_wallet_address(:signer_address)
    |> downcase_wallet_addresses()
  end

  defp validate_wallet_address(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      if is_nil(value) or value == "" or Regex.match?(~r/^0x[a-fA-F0-9]{40}$/, value) do
        []
      else
        [{field, "must be a valid Ethereum address (0x...)"}]
      end
    end)
  end

  defp downcase_wallet_addresses(changeset) do
    changeset
    |> update_change(:wallet_address, &downcase_if_present/1)
    |> update_change(:signer_address, &downcase_if_present/1)
  end

  defp downcase_if_present(nil), do: nil
  defp downcase_if_present(""), do: ""
  defp downcase_if_present(value), do: String.downcase(value)

  @doc """
  Gets the credentials record, creating a default one if it doesn't exist.
  Uses a singleton pattern with key="default".
  """
  def get_or_create do
    case Repo.get_by(__MODULE__, key: "default") do
      nil ->
        %__MODULE__{}
        |> changeset(%{key: "default"})
        |> Repo.insert!()

      credentials ->
        credentials
    end
  end

  @doc """
  Updates credentials with the given attributes.
  """
  def update(attrs) when is_map(attrs) do
    get_or_create()
    |> changeset(attrs)
    |> Repo.update()
  end

  def update(opts) when is_list(opts) do
    update(Map.new(opts))
  end

  @doc """
  Returns credentials as a keyword list for use with the Polymarket client.
  """
  def to_config do
    creds = get_or_create()

    [
      clob_url: "https://clob.polymarket.com",
      api_key: creds.api_key,
      api_secret: creds.api_secret,
      api_passphrase: creds.api_passphrase,
      wallet_address: creds.wallet_address,
      signer_address: creds.signer_address,
      private_key: creds.private_key
    ]
  end

  @doc """
  Checks if all required credentials are configured.
  """
  def configured? do
    creds = get_or_create()

    not is_nil(creds.api_key) and creds.api_key != "" and
      not is_nil(creds.api_secret) and creds.api_secret != "" and
      not is_nil(creds.api_passphrase) and creds.api_passphrase != "" and
      not is_nil(creds.wallet_address) and creds.wallet_address != "" and
      not is_nil(creds.private_key) and creds.private_key != ""
  end

  @doc """
  Returns a map with masked sensitive fields for display.
  """
  def to_masked_map do
    creds = get_or_create()

    %{
      api_key: mask_value(creds.api_key),
      api_secret: mask_value(creds.api_secret),
      api_passphrase: mask_value(creds.api_passphrase),
      wallet_address: creds.wallet_address,
      signer_address: creds.signer_address,
      private_key: mask_value(creds.private_key),
      configured: configured?()
    }
  end

  @doc """
  Returns a map with raw (unmasked) values for form editing.
  """
  def to_raw_map do
    creds = get_or_create()

    %{
      api_key: creds.api_key || "",
      api_secret: creds.api_secret || "",
      api_passphrase: creds.api_passphrase || "",
      wallet_address: creds.wallet_address || "",
      signer_address: creds.signer_address || "",
      private_key: creds.private_key || ""
    }
  end

  defp mask_value(nil), do: nil
  defp mask_value(""), do: ""

  defp mask_value(value) when is_binary(value) do
    len = String.length(value)

    if len <= 8 do
      String.duplicate("•", len)
    else
      String.slice(value, 0, 4) <> String.duplicate("•", len - 8) <> String.slice(value, -4, 4)
    end
  end
end
