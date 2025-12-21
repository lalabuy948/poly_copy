defmodule PolyxWeb.Components.Strategies.NoSelection do
  @moduledoc """
  Component for displaying the empty state when no strategy is selected.
  """
  use PolyxWeb, :html

  @doc """
  Renders the empty state when no strategy is selected.
  """
  attr :rest, :global

  def no_selection(assigns) do
    ~H"""
    <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
      <div class="py-20 text-center">
        <div class="w-20 h-20 rounded-2xl bg-base-300/50 flex items-center justify-center mx-auto mb-4">
          <.icon name="hero-cursor-arrow-rays" class="size-10 text-base-content/30" />
        </div>
        <p class="text-base-content/50 font-medium">Select a strategy</p>
        <p class="text-sm text-base-content/40 mt-1">Click on a strategy to view details</p>
      </div>
    </div>
    """
  end
end
