defmodule PolyxWeb.Components.Strategies.StrategyList do
  @moduledoc """
  Component for displaying the list of strategies with creation form.
  """
  use PolyxWeb, :html

  import PolyxWeb.StrategiesLive.{Formatters, Helpers}

  alias Polyx.Strategies.Behaviour

  @doc """
  Renders the strategies list with new strategy form.
  """
  attr :strategies, :list, required: true
  attr :selected_strategy, :any, required: true
  attr :show_new_form, :boolean, required: true
  attr :new_strategy_type, :string, required: true
  attr :new_strategy_name, :string, required: true

  def strategies_list(assigns) do
    ~H"""
    <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
      <div class="px-5 py-4 border-b border-base-300 flex items-center justify-between">
        <div class="flex items-center gap-2">
          <.icon name="hero-rectangle-stack" class="size-5 text-secondary" />
          <h2 class="font-semibold">Strategies</h2>
          <span class="px-2 py-0.5 rounded-full bg-base-300 text-xs font-medium">
            {length(@strategies)}
          </span>
        </div>
        <button
          type="button"
          phx-click="toggle_new_form"
          class="px-3 py-1.5 rounded-lg bg-primary/10 text-primary text-sm font-medium hover:bg-primary hover:text-primary-content transition-colors flex items-center gap-1"
        >
          <.icon name="hero-plus" class="size-4" /> New
        </button>
      </div>

      <%!-- New Strategy Form --%>
      <div :if={@show_new_form} class="p-5 border-b border-base-300 bg-base-100/50">
        <form phx-submit="create_strategy" class="space-y-4">
          <div>
            <label class="block text-xs font-medium text-base-content/60 mb-2">Strategy Type</label>
            <div class="grid grid-cols-2 gap-2">
              <button
                :for={{type, name, desc} <- Behaviour.available_types()}
                type="button"
                phx-click="select_type"
                phx-value-type={type}
                class={[
                  "p-3 rounded-xl border text-left transition-all",
                  @new_strategy_type == type && "border-primary bg-primary/5",
                  @new_strategy_type != type && "border-base-300 hover:border-base-content/20"
                ]}
              >
                <p class="text-sm font-medium">{name}</p>
                <p class="text-xs text-base-content/50 mt-0.5">{desc}</p>
              </button>
            </div>
          </div>
          <div>
            <label class="block text-xs font-medium text-base-content/60 mb-1">Name (optional)</label>
            <input
              type="text"
              name="name"
              value={@new_strategy_name}
              phx-change="update_name"
              placeholder={Behaviour.display_name(@new_strategy_type)}
              class="w-full px-3 py-2 rounded-lg bg-base-100 border border-base-300 text-sm"
            />
          </div>
          <div class="flex gap-2">
            <button
              type="submit"
              class="flex-1 px-4 py-2 rounded-lg bg-primary text-primary-content font-medium text-sm"
            >
              Create Strategy
            </button>
            <button
              type="button"
              phx-click="toggle_new_form"
              class="px-4 py-2 rounded-lg bg-base-300 text-base-content font-medium text-sm"
            >
              Cancel
            </button>
          </div>
        </form>
      </div>

      <div class="p-5">
        <div :if={@strategies == []} class="py-12 text-center">
          <div class="w-16 h-16 rounded-2xl bg-base-300/50 flex items-center justify-center mx-auto mb-4">
            <.icon name="hero-cpu-chip" class="size-8 text-base-content/30" />
          </div>
          <p class="text-base-content/50 font-medium">No strategies yet</p>
        </div>

        <div class="space-y-2">
          <div
            :for={strategy <- @strategies}
            class={[
              "group flex items-center justify-between p-3 rounded-xl border transition-colors cursor-pointer",
              @selected_strategy && @selected_strategy.strategy.id == strategy.id &&
                "bg-primary/5 border-primary/30",
              (!@selected_strategy || @selected_strategy.strategy.id != strategy.id) &&
                "bg-base-100 border-base-300/50 hover:border-base-300"
            ]}
            phx-click="select_strategy"
            phx-value-id={strategy.id}
          >
            <div class="flex items-center gap-3">
              <div class={[
                "w-10 h-10 rounded-xl flex items-center justify-center",
                status_bg_class(strategy.status)
              ]}>
                <.icon name={strategy_icon(strategy.type)} class="size-5" />
              </div>
              <div>
                <p class="font-medium text-sm">{strategy.name}</p>
                <p class="text-xs text-base-content/50">{Behaviour.display_name(strategy.type)}</p>
              </div>
            </div>
            <div class="flex items-center gap-2">
              <span
                :if={strategy.paper_mode}
                class="px-2 py-0.5 rounded text-xs font-medium bg-warning/10 text-warning"
              >
                PAPER
              </span>
              <span
                :if={!strategy.paper_mode}
                class="px-2 py-0.5 rounded text-xs font-medium bg-error/10 text-error"
              >
                LIVE
              </span>
              <span class={[
                "px-2 py-0.5 rounded text-xs font-medium",
                status_badge_class(strategy.status)
              ]}>
                {status_display(strategy.status)}
              </span>
              <button
                type="button"
                phx-click="toggle_live"
                phx-value-id={strategy.id}
                class={[
                  "relative inline-flex h-6 w-10 items-center rounded-full transition-colors",
                  strategy.status == "running" && "bg-success",
                  strategy.status != "running" && "bg-base-300"
                ]}
              >
                <span class={[
                  "inline-block h-4 w-4 transform rounded-full bg-white transition-transform shadow-sm",
                  strategy.status == "running" && "translate-x-5",
                  strategy.status != "running" && "translate-x-1"
                ]} />
              </button>
              <button
                type="button"
                phx-click="delete_strategy"
                phx-value-id={strategy.id}
                data-confirm="Delete this strategy?"
                class="p-1.5 rounded-lg text-error hover:bg-error/10 transition-colors opacity-0 group-hover:opacity-100"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
