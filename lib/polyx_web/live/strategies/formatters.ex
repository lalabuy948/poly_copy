defmodule PolyxWeb.StrategiesLive.Formatters do
  @moduledoc """
  Formatting utilities for the StrategiesLive view.

  Contains pure functions for formatting numbers, dates, prices, and other display values.
  """

  alias Polyx.Strategies.Config

  @doc """
  Formats a decimal value as a percentage.

  ## Examples

      iex> format_percent(0.8)
      "80%"

      iex> format_percent(nil)
      "-"
  """
  def format_percent(value) when is_number(value), do: "#{round(value * 100)}%"
  def format_percent(_), do: "-"

  @doc """
  Formats a price as a percentage (cents display).

  ## Examples

      iex> format_price_percent(0.85)
      "85.0¢"
  """
  def format_price_percent(price) when is_number(price), do: "#{Float.round(price * 100, 1)}¢"
  def format_price_percent(_), do: "-"

  @doc """
  Formats a price with high precision (4 decimal places).

  ## Examples

      iex> format_price_precise(0.8523)
      "0.8523"
  """
  def format_price_precise(price) when is_number(price),
    do: :erlang.float_to_binary(price * 1.0, decimals: 4)

  def format_price_precise(_), do: "-"

  @doc """
  Formats a price as cents.

  ## Examples

      iex> format_price_cents(0.99)
      "99.0¢"
  """
  def format_price_cents(price) when is_number(price), do: "#{Float.round(price * 100, 1)}¢"
  def format_price_cents(_), do: "-"

  @doc """
  Formats a DateTime as HH:MM:SS.
  """
  def format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  def format_datetime(_), do: ""

  @doc """
  Formats a DateTime as HH:MM:SS (alias for format_datetime).
  """
  def format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  def format_time(_), do: ""

  @doc """
  Returns the display label for a timeframe preset.

  ## Examples

      iex> timeframe_label("15m")
      "15 Minutes"
  """
  def timeframe_label(timeframe) do
    presets = Config.timeframe_presets()

    case Map.get(presets, timeframe) do
      %{label: label} -> label
      _ -> "15 Minutes"
    end
  end

  @doc """
  Returns the display text for a strategy status.

  ## Examples

      iex> status_display("running")
      "LIVE"

      iex> status_display("stopped")
      "OFF"
  """
  def status_display("running"), do: "LIVE"
  def status_display("paused"), do: "PAUSED"
  def status_display("stopped"), do: "OFF"
  def status_display("error"), do: "ERROR"
  def status_display(other), do: String.upcase(other)

  @doc """
  Extracts and formats the outcome label from a signal for display.

  ## Examples

      iex> signal_outcome_label(%{metadata: %{outcome: "Up"}})
      "↑ UP"

      iex> signal_outcome_label(%{action: :buy})
      "BUY"
  """
  def signal_outcome_label(signal) do
    outcome = get_in(signal, [:metadata, :outcome]) || get_in(signal, ["metadata", "outcome"])

    case outcome do
      "Up" -> "↑ UP"
      "Down" -> "↓ DOWN"
      "Yes" -> "YES"
      "No" -> "NO"
      nil -> signal.action |> to_string() |> String.upcase()
      other -> String.upcase(to_string(other))
    end
  end

  @doc """
  Returns the Tailwind CSS class for PnL display based on value.

  ## Examples

      iex> pnl_class(Decimal.new("100"))
      "text-success"

      iex> pnl_class(Decimal.new("-50"))
      "text-error"
  """
  def pnl_class(pnl) do
    cond do
      Decimal.compare(pnl, 0) == :gt -> "text-success"
      Decimal.compare(pnl, 0) == :lt -> "text-error"
      true -> ""
    end
  end
end
