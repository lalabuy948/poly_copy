defmodule Polyx.Strategies.Strategy do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer(),
          name: String.t(),
          type: String.t(),
          config: map(),
          status: String.t(),
          paper_mode: boolean(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @statuses ~w(stopped running paused error)

  schema "strategies" do
    field :name, :string
    field :type, :string
    field :config, :map, default: %{}
    field :status, :string, default: "stopped"
    field :paper_mode, :boolean, default: true

    has_many :trades, Polyx.Trades.Trade
    has_many :positions, Polyx.Strategies.Position
    has_many :events, Polyx.Strategies.Event

    timestamps(type: :utc_datetime)
  end

  def changeset(strategy, attrs) do
    strategy
    |> cast(attrs, [:name, :type, :config, :status, :paper_mode])
    |> validate_required([:name, :type])
    |> validate_inclusion(:status, @statuses)
  end

  def status_changeset(strategy, status) do
    strategy
    |> cast(%{status: status}, [:status])
    |> validate_inclusion(:status, @statuses)
  end
end
