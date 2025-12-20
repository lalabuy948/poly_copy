defmodule PolyxWeb.StrategiesLive.Helpers do
  @moduledoc """
  Helper functions for the StrategiesLive view.

  Contains functions for mapping statuses to CSS classes, icon names, and other UI utilities.
  """

  @doc """
  Returns the background CSS class for a strategy status.

  ## Examples

      iex> status_bg_class("running")
      "bg-success/10 text-success"
  """
  def status_bg_class("running"), do: "bg-success/10 text-success"
  def status_bg_class("paused"), do: "bg-warning/10 text-warning"
  def status_bg_class("error"), do: "bg-error/10 text-error"
  def status_bg_class(_), do: "bg-base-300 text-base-content/50"

  @doc """
  Returns the badge CSS class for a strategy status.

  ## Examples

      iex> status_badge_class("running")
      "bg-success/10 text-success"
  """
  def status_badge_class("running"), do: "bg-success/10 text-success"
  def status_badge_class("paused"), do: "bg-warning/10 text-warning"
  def status_badge_class("error"), do: "bg-error/10 text-error"
  def status_badge_class(_), do: "bg-base-300 text-base-content/50"

  @doc """
  Returns the icon name for a strategy type.

  ## Examples

      iex> strategy_icon("time_decay")
      "hero-clock"
  """
  def strategy_icon("time_decay"), do: "hero-clock"
  def strategy_icon(_), do: "hero-cpu-chip"

  @doc """
  Returns the CSS class for an event type.

  ## Examples

      iex> event_type_class("info")
      "bg-info/10 text-info"
  """
  def event_type_class("info"), do: "bg-info/10 text-info"
  def event_type_class("signal"), do: "bg-secondary/10 text-secondary"
  def event_type_class("trade"), do: "bg-success/10 text-success"
  def event_type_class("error"), do: "bg-error/10 text-error"
  def event_type_class(_), do: "bg-base-300 text-base-content/50"

  @doc """
  Returns the icon name for an event type.

  ## Examples

      iex> event_type_icon("info")
      "hero-information-circle"
  """
  def event_type_icon("info"), do: "hero-information-circle"
  def event_type_icon("signal"), do: "hero-bolt"
  def event_type_icon("trade"), do: "hero-banknotes"
  def event_type_icon("error"), do: "hero-exclamation-triangle"
  def event_type_icon(_), do: "hero-document"

  @doc """
  Returns the CSS class for an outcome badge.

  ## Examples

      iex> outcome_class("Yes")
      "bg-success/20 text-success"
  """
  def outcome_class("Yes"), do: "bg-success/20 text-success"
  def outcome_class("No"), do: "bg-error/20 text-error"
  def outcome_class(_), do: "bg-base-300 text-base-content/60"

  @doc """
  Returns the CSS class for an order side (BUY/SELL).

  ## Examples

      iex> order_side_class("BUY")
      "text-success font-semibold"

      iex> order_side_class(:sell)
      "text-error font-semibold"
  """
  def order_side_class(side) when side in ["BUY", "buy", :buy], do: "text-success font-semibold"
  def order_side_class(side) when side in ["SELL", "sell", :sell], do: "text-error font-semibold"
  def order_side_class(_), do: "text-base-content/60"
end
