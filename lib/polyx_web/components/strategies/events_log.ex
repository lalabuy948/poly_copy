defmodule PolyxWeb.Components.Strategies.EventsLog do
  @moduledoc """
  Component for displaying the strategy activity log.
  """
  use PolyxWeb, :html

  import PolyxWeb.StrategiesLive.{Formatters, Helpers}

  @doc """
  Renders the events log with stream-based updates.
  """
  attr :streams, :map, required: true

  def events_log(assigns) do
    ~H"""
    <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
      <div class="px-5 py-4 border-b border-base-300">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <.icon name="hero-document-text" class="size-5 text-info" />
            <h2 class="font-semibold">Activity Log</h2>
          </div>
          <button
            type="button"
            phx-click="clear_activity_log"
            class="text-xs text-base-content/50 hover:text-base-content"
          >
            Clear
          </button>
        </div>
      </div>

      <div
        id="events-log"
        phx-update="stream"
        class="divide-y divide-base-300/50 max-h-[400px] overflow-y-auto"
      >
        <div id="events-empty" class="hidden only:block py-12 text-center">
          <.icon name="hero-document-text" class="size-8 text-base-content/30 mx-auto" />
          <p class="text-base-content/50 font-medium mt-4">No events yet</p>
        </div>

        <div :for={{id, event} <- @streams.events} id={id} class="flex items-start gap-3 px-5 py-3">
          <div class={[
            "w-8 h-8 rounded-lg flex items-center justify-center shrink-0",
            event_type_class(event.type)
          ]}>
            <.icon name={event_type_icon(event.type)} class="size-4" />
          </div>
          <div class="flex-1 min-w-0">
            <p class="text-sm">{event.message}</p>
            <p class="text-xs text-base-content/40 mt-0.5">{format_datetime(event.inserted_at)}</p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
