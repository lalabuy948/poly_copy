defmodule Polyx.CopyTrading.TrackedUser do
  @moduledoc """
  Schema for persisting tracked users to the database.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "tracked_users" do
    field :address, :string
    field :label, :string
    field :active, :boolean, default: true

    timestamps()
  end

  @doc false
  def changeset(tracked_user, attrs) do
    tracked_user
    |> cast(attrs, [:address, :label, :active])
    |> validate_required([:address])
    |> validate_format(:address, ~r/^0x[a-fA-F0-9]{40}$/,
      message: "must be a valid Ethereum address"
    )
    |> unique_constraint(:address)
    |> maybe_set_label()
  end

  defp maybe_set_label(changeset) do
    case get_field(changeset, :label) do
      nil ->
        address = get_field(changeset, :address)

        if address do
          short = "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
          put_change(changeset, :label, short)
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
