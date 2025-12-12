defmodule Polyx.Strategies.Event do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer(),
          strategy_id: integer(),
          type: String.t(),
          message: String.t(),
          metadata: map(),
          inserted_at: DateTime.t()
        }

  @event_types ~w(info trade error opportunity signal)

  schema "strategy_events" do
    field :type, :string
    field :message, :string
    field :metadata, :map, default: %{}

    belongs_to :strategy, Polyx.Strategies.Strategy

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:type, :message, :metadata])
    |> validate_required([:type, :message])
    |> validate_inclusion(:type, @event_types)
  end
end
