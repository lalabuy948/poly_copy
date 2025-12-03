defmodule Polyx.CopyTrading.Settings do
  @moduledoc """
  Schema for persisting copy trading settings.
  Uses a singleton pattern with a unique key constraint.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Polyx.Repo

  @default_key "default"

  schema "copy_trading_settings" do
    field :key, :string, default: @default_key
    field :sizing_mode, :string, default: "fixed"
    field :fixed_amount, :decimal, default: Decimal.new("10.0")
    field :proportional_factor, :decimal, default: Decimal.new("0.1")
    field :percentage, :decimal, default: Decimal.new("5.0")
    field :enabled, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:sizing_mode, :fixed_amount, :proportional_factor, :percentage, :enabled])
    |> validate_required([
      :sizing_mode,
      :fixed_amount,
      :proportional_factor,
      :percentage,
      :enabled
    ])
    |> validate_inclusion(:sizing_mode, ["fixed", "proportional", "percentage"])
    |> validate_number(:fixed_amount, greater_than: 0)
    |> validate_number(:proportional_factor, greater_than: 0)
    |> validate_number(:percentage, greater_than: 0, less_than_or_equal_to: 100)
  end

  @doc """
  Gets or creates the singleton settings record.
  """
  def get_or_create do
    case Repo.one(from s in __MODULE__, where: s.key == @default_key) do
      nil ->
        %__MODULE__{key: @default_key}
        |> Repo.insert!()

      settings ->
        settings
    end
  end

  @doc """
  Converts the settings record to a map for use in TradeExecutor.
  """
  def to_map(%__MODULE__{} = settings) do
    %{
      sizing_mode: String.to_existing_atom(settings.sizing_mode),
      fixed_amount: Decimal.to_float(settings.fixed_amount),
      proportional_factor: Decimal.to_float(settings.proportional_factor),
      percentage: Decimal.to_float(settings.percentage),
      enabled: settings.enabled
    }
  end

  @doc """
  Updates settings from a keyword list or map.
  """
  def update(opts) when is_list(opts) do
    update(Map.new(opts))
  end

  def update(opts) when is_map(opts) do
    settings = get_or_create()

    # Convert atom keys to string keys and atom values
    attrs =
      opts
      |> Enum.reduce(%{}, fn
        {:sizing_mode, mode}, acc when is_atom(mode) ->
          Map.put(acc, :sizing_mode, Atom.to_string(mode))

        {:sizing_mode, mode}, acc when is_binary(mode) ->
          Map.put(acc, :sizing_mode, mode)

        {key, value}, acc when key in [:fixed_amount, :proportional_factor, :percentage] ->
          Map.put(acc, key, value)

        {:enabled, value}, acc when is_boolean(value) ->
          Map.put(acc, :enabled, value)

        _, acc ->
          acc
      end)

    case settings |> changeset(attrs) |> Repo.update() do
      {:ok, updated} -> {:ok, to_map(updated)}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
