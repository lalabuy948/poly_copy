defmodule Polyx.Strategies.Position do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer(),
          strategy_id: integer(),
          market_id: String.t(),
          token_id: String.t(),
          side: String.t(),
          size: Decimal.t(),
          avg_price: Decimal.t(),
          current_price: Decimal.t() | nil,
          unrealized_pnl: Decimal.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @sides ~w(YES NO)

  schema "strategy_positions" do
    field :market_id, :string
    field :token_id, :string
    field :side, :string
    field :size, :decimal, default: Decimal.new(0)
    field :avg_price, :decimal, default: Decimal.new(0)
    field :current_price, :decimal
    field :unrealized_pnl, :decimal

    belongs_to :strategy, Polyx.Strategies.Strategy

    timestamps(type: :utc_datetime)
  end

  def changeset(position, attrs) do
    position
    |> cast(attrs, [
      :market_id,
      :token_id,
      :side,
      :size,
      :avg_price,
      :current_price,
      :unrealized_pnl
    ])
    |> validate_required([:market_id, :token_id, :side])
    |> validate_inclusion(:side, @sides)
    |> validate_number(:size, greater_than_or_equal_to: 0)
  end

  def update_changeset(position, attrs) do
    position
    |> cast(attrs, [:size, :avg_price, :current_price, :unrealized_pnl])
    |> validate_number(:size, greater_than_or_equal_to: 0)
  end
end
