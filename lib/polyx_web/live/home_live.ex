defmodule PolyxWeb.HomeLive do
  use PolyxWeb, :live_view

  alias Polyx.CopyTrading

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      CopyTrading.subscribe()
      # Refresh account summary every 30 seconds
      :timer.send_interval(30_000, self(), :refresh_account)
    end

    tracked_users = CopyTrading.list_tracked_users()
    archived_users = CopyTrading.list_archived_users()
    copy_trades = CopyTrading.get_copy_trades()
    settings = CopyTrading.get_settings()

    # Collect all recent trades from tracked users for live feed
    live_feed = collect_live_feed(tracked_users)

    # Track which original trade IDs have been copied
    copied_trade_ids = MapSet.new(Enum.map(copy_trades, & &1.original_trade_id))

    # Get account summary (balance + positions)
    account_summary = fetch_account_summary()

    {:ok,
     socket
     |> assign(:page_title, "Copy Trading")
     |> assign(:tracked_users, tracked_users)
     |> assign(:archived_users, archived_users)
     |> assign(:settings, settings)
     |> assign(:add_user_form, to_form(%{"address" => "", "label" => ""}))
     |> assign(:api_configured, Polyx.Polymarket.Client.credentials_configured?())
     |> assign(:credentials, Polyx.Credentials.to_masked_map())
     |> assign(:credentials_form, Polyx.Credentials.to_raw_map())
     |> assign(:show_credentials, false)
     |> assign(:copied_trade_ids, copied_trade_ids)
     |> assign(:account_summary, account_summary)
     |> assign(:feed_filter, nil)
     |> assign(:editing_user, nil)
     |> assign(:show_archived, false)
     |> stream(:copy_trades, copy_trades)
     |> stream(:live_feed, live_feed)}
  end

  @impl true
  def handle_event("validate_add_user", params, socket) do
    # Preserve form values during re-renders
    {:noreply, assign(socket, :add_user_form, to_form(params))}
  end

  @impl true
  def handle_event("add_user", %{"address" => address, "label" => label}, socket) do
    opts = if label != "", do: [label: label], else: []

    case CopyTrading.track_user(address, opts) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User added successfully")
         |> assign(:add_user_form, to_form(%{"address" => "", "label" => ""}))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("archive_user", %{"address" => address}, socket) do
    case CopyTrading.untrack_user(address) do
      :ok ->
        archived_users = CopyTrading.list_archived_users()

        {:noreply,
         socket
         |> assign(:archived_users, archived_users)
         |> put_flash(:info, "User archived")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "User not found")}
    end
  end

  @impl true
  def handle_event("filter_feed", %{"address" => address}, socket) do
    # Toggle filter - if already filtering this address, clear filter
    new_filter =
      if socket.assigns.feed_filter == address do
        nil
      else
        address
      end

    # Re-stream the filtered live feed
    live_feed =
      socket.assigns.tracked_users
      |> collect_live_feed()
      |> filter_feed(new_filter)

    {:noreply,
     socket
     |> assign(:feed_filter, new_filter)
     |> stream(:live_feed, live_feed, reset: true)}
  end

  @impl true
  def handle_event("clear_feed_filter", _params, socket) do
    live_feed = collect_live_feed(socket.assigns.tracked_users)

    {:noreply,
     socket
     |> assign(:feed_filter, nil)
     |> stream(:live_feed, live_feed, reset: true)}
  end

  @impl true
  def handle_event("toggle_archived", _params, socket) do
    {:noreply, assign(socket, :show_archived, !socket.assigns.show_archived)}
  end

  @impl true
  def handle_event("restore_user", %{"address" => address}, socket) do
    case CopyTrading.restore_user(address) do
      {:ok, _user} ->
        archived_users = CopyTrading.list_archived_users()

        {:noreply,
         socket
         |> assign(:archived_users, archived_users)
         |> put_flash(:info, "User restored")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "User not found")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to restore user")}
    end
  end

  @impl true
  def handle_event("delete_user", %{"address" => address}, socket) do
    case CopyTrading.delete_user(address) do
      {:ok, _user} ->
        archived_users = CopyTrading.list_archived_users()

        {:noreply,
         socket
         |> assign(:archived_users, archived_users)
         |> put_flash(:info, "User permanently deleted")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "User not found or not archived")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete user")}
    end
  end

  @impl true
  def handle_event("edit_user_label", %{"address" => address}, socket) do
    {:noreply, assign(socket, :editing_user, address)}
  end

  @impl true
  def handle_event("cancel_edit_label", _params, socket) do
    {:noreply, assign(socket, :editing_user, nil)}
  end

  @impl true
  def handle_event("save_user_label", %{"address" => address, "label" => label}, socket) do
    case CopyTrading.update_user_label(address, label) do
      {:ok, _user} ->
        # Update local state
        updated_users =
          Enum.map(socket.assigns.tracked_users, fn user ->
            if user.address == address do
              %{user | label: label}
            else
              user
            end
          end)

        {:noreply,
         socket
         |> assign(:tracked_users, updated_users)
         |> assign(:editing_user, nil)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update label")
         |> assign(:editing_user, nil)}
    end
  end

  @impl true
  def handle_event("update_sizing", params, socket) do
    opts = [
      sizing_mode: String.to_existing_atom(params["sizing_mode"]),
      fixed_amount: parse_float(params["fixed_amount"]),
      proportional_factor: parse_float(params["proportional_factor"]),
      percentage: parse_float(params["percentage"])
    ]

    case CopyTrading.update_settings(opts) do
      {:ok, new_settings} ->
        {:noreply, assign(socket, :settings, new_settings)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_enabled", _params, socket) do
    new_enabled = !socket.assigns.settings.enabled

    case CopyTrading.update_settings(enabled: new_enabled) do
      {:ok, new_settings} ->
        {:noreply, assign(socket, :settings, new_settings)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_credentials", _params, socket) do
    # Reload form data when opening the form
    socket =
      if !socket.assigns.show_credentials do
        assign(socket, :credentials_form, Polyx.Credentials.to_raw_map())
      else
        socket
      end

    {:noreply, assign(socket, :show_credentials, !socket.assigns.show_credentials)}
  end

  @impl true
  def handle_event("save_credentials", params, socket) do
    attrs = %{
      api_key: params["api_key"],
      api_secret: params["api_secret"],
      api_passphrase: params["api_passphrase"],
      wallet_address: params["wallet_address"],
      signer_address: params["signer_address"],
      private_key: params["private_key"]
    }

    case Polyx.Credentials.update(attrs) do
      {:ok, _creds} ->
        {:noreply,
         socket
         |> assign(:credentials, Polyx.Credentials.to_masked_map())
         |> assign(:api_configured, Polyx.Credentials.configured?())
         |> assign(:show_credentials, false)
         |> assign(:account_summary, fetch_account_summary())
         |> put_flash(:info, "Credentials saved successfully")}

      {:error, changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
          |> Enum.map(fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
          |> Enum.join("; ")

        {:noreply, put_flash(socket, :error, "Failed to save: #{errors}")}
    end
  end

  @impl true
  def handle_event("manual_copy", params, socket) do
    # Reconstruct the trade map from the params
    trade = %{
      "id" => params["trade_id"],
      "side" => params["side"],
      "size" => params["size"],
      "price" => params["price"],
      "outcome" => params["outcome"],
      "market_slug" => params["market_slug"],
      "asset_id" => params["asset_id"],
      "title" => params["title"],
      "event_slug" => params["event_slug"]
    }

    CopyTrading.manual_copy_trade(params["address"], trade)
    {:noreply, socket}
  end

  @impl true
  def handle_event("retry_trade", %{"trade-id" => trade_id}, socket) do
    case CopyTrading.retry_copy_trade(trade_id) do
      {:ok, _trade} ->
        {:noreply, put_flash(socket, :info, "Retrying trade...")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Trade not found")}

      {:error, :not_failed} ->
        {:noreply, put_flash(socket, :error, "Trade is not in failed state")}
    end
  end

  @impl true
  def handle_event("delete_trade", %{"trade-id" => trade_id}, socket) do
    case CopyTrading.delete_copy_trade(trade_id) do
      {:ok, _trade} ->
        {:noreply, put_flash(socket, :info, "Trade deleted")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Trade not found")}

      {:error, :not_failed} ->
        {:noreply, put_flash(socket, :error, "Only failed trades can be deleted")}
    end
  end

  @impl true
  def handle_event("delete_all_failed", _params, socket) do
    case CopyTrading.delete_all_failed_copy_trades() do
      {:ok, 0} ->
        {:noreply, put_flash(socket, :info, "No failed trades to delete")}

      {:ok, count} ->
        {:noreply, put_flash(socket, :info, "Deleted #{count} failed trade(s)")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete trades")}
    end
  end

  @impl true
  def handle_info({:user_tracked, user_info}, socket) do
    {:noreply, assign(socket, :tracked_users, [user_info | socket.assigns.tracked_users])}
  end

  @impl true
  def handle_info({:user_untracked, user_info}, socket) do
    remaining_users =
      Enum.reject(socket.assigns.tracked_users, &(&1.address == user_info.address))

    live_feed = collect_live_feed(remaining_users)

    {:noreply,
     socket
     |> assign(:tracked_users, remaining_users)
     |> stream(:live_feed, live_feed, reset: true)}
  end

  @impl true
  def handle_info({:new_trade, %{address: _address, trade: _trade}}, socket) do
    # Don't insert here - let :trades_updated handle the feed with proper sorting
    # This event is still useful for copy trading execution
    {:noreply, socket}
  end

  @impl true
  def handle_info({:copy_trade_executed, trade}, socket) do
    copied_ids = MapSet.put(socket.assigns.copied_trade_ids, trade.original_trade_id)

    # Rebuild live feed to show "Copied" label on the trade
    live_feed =
      socket.assigns.tracked_users
      |> collect_live_feed()
      |> filter_feed(socket.assigns.feed_filter)

    socket =
      socket
      |> assign(:copied_trade_ids, copied_ids)
      |> stream_insert(:copy_trades, trade, at: 0)
      |> stream(:live_feed, live_feed, reset: true)

    # Show flash based on trade status
    socket =
      case trade.status do
        :executed ->
          put_flash(socket, :info, "Trade copied successfully")

        :failed ->
          put_flash(
            socket,
            :error,
            "Copy trade failed: #{Map.get(trade, :error_message, "Unknown error")}"
          )

        _ ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:copy_trade_updated, trade}, socket) do
    {:noreply, stream_insert(socket, :copy_trades, trade)}
  end

  @impl true
  def handle_info({:copy_trade_deleted, trade}, socket) do
    # Remove from copied_trade_ids so the trade shows "Copy" button again in live feed
    copied_ids = MapSet.delete(socket.assigns.copied_trade_ids, trade.original_trade_id)

    # Rebuild live feed to show "Copy" button again
    live_feed =
      socket.assigns.tracked_users
      |> collect_live_feed()
      |> filter_feed(socket.assigns.feed_filter)

    {:noreply,
     socket
     |> assign(:copied_trade_ids, copied_ids)
     |> stream_delete(:copy_trades, trade)
     |> stream(:live_feed, live_feed, reset: true)}
  end

  @impl true
  def handle_info({:user_deleted, _user_info}, socket) do
    archived_users = CopyTrading.list_archived_users()
    {:noreply, assign(socket, :archived_users, archived_users)}
  end

  @impl true
  def handle_info(:refresh_account, socket) do
    {:noreply, assign(socket, :account_summary, fetch_account_summary())}
  end

  @impl true
  def handle_info({:settings_updated, settings}, socket) do
    {:noreply, assign(socket, :settings, settings)}
  end

  @impl true
  def handle_info({:user_label_updated, updated_user}, socket) do
    # Update local tracked users list with new label
    updated_users =
      Enum.map(socket.assigns.tracked_users, fn user ->
        if user.address == updated_user.address do
          %{user | label: updated_user.label}
        else
          user
        end
      end)

    {:noreply, assign(socket, :tracked_users, updated_users)}
  end

  @impl true
  def handle_info({:trades_updated, %{address: address, trades: trades}}, socket) do
    # Check if trades actually changed for this user using content fingerprint
    current_user = Enum.find(socket.assigns.tracked_users, &(&1.address == address))
    current_fingerprint = if current_user, do: trades_fingerprint(current_user.trades), else: nil
    new_fingerprint = trades_fingerprint(trades)

    if current_fingerprint == new_fingerprint do
      # No change in trades content, skip update
      {:noreply, socket}
    else
      # Update tracked user's trades
      updated_users =
        Enum.map(socket.assigns.tracked_users, fn user ->
          if user.address == address do
            %{user | trades: trades}
          else
            user
          end
        end)

      # Rebuild live feed with updated trades (ensures correct sort order across all users)
      live_feed =
        updated_users
        |> collect_live_feed()
        |> filter_feed(socket.assigns.feed_filter)

      {:noreply,
       socket
       |> assign(:tracked_users, updated_users)
       |> stream(:live_feed, live_feed, reset: true)}
    end
  end

  defp parse_float(str) when is_binary(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float(num) when is_number(num), do: num
  defp parse_float(_), do: 0.0

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="min-h-screen">
        <%!-- Header Section --%>
        <div class="border-b border-base-300 bg-base-100/80 backdrop-blur-sm sticky top-0 z-10">
          <div class="max-w-7xl mx-auto px-4 py-4">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-4">
                <div class="flex items-center gap-3">
                  <div class="w-10 h-10 rounded-xl bg-gradient-to-br from-primary to-secondary flex items-center justify-center">
                    <.icon name="hero-arrow-path" class="size-5 text-white" />
                  </div>
                  <div>
                    <h1 class="text-xl font-bold tracking-tight">Poly Copy</h1>
                    <p class="text-xs text-base-content/50">Polymarket copy trading</p>
                  </div>
                </div>
              </div>

              <div class="flex items-center gap-3">
                <%!-- Strategies Link
                <.link
                  navigate={~p"/strategies"}
                  class="px-4 py-2.5 rounded-xl bg-secondary/10 hover:bg-secondary/20 transition-colors text-sm font-medium flex items-center gap-2 text-secondary"
                >
                  <.icon name="hero-cpu-chip" class="size-4" /> Strategies
                </.link> --%>

                <%!-- Theme Toggle --%>
                <button
                  type="button"
                  id="navbar-theme-toggle"
                  phx-click={JS.dispatch("phx:toggle-theme")}
                  class="p-2.5 rounded-xl bg-base-300/50 hover:bg-base-300 transition-colors"
                  title="Toggle theme"
                >
                  <.icon
                    name="hero-sun"
                    class="size-5 text-warning hidden [[data-theme=dark]_&]:block"
                  />
                  <.icon
                    name="hero-moon"
                    class="size-5 text-primary block [[data-theme=dark]_&]:hidden"
                  />
                </button>

                <%!-- Live/Paused Toggle --%>
                <button
                  type="button"
                  phx-click="toggle_enabled"
                  class={[
                    "relative px-5 py-2.5 rounded-xl font-semibold text-sm transition-all duration-200",
                    "flex items-center gap-2 shadow-lg",
                    @settings.enabled &&
                      "bg-gradient-to-r from-success to-emerald-500 text-white shadow-success/25",
                    !@settings.enabled && "bg-base-300 text-base-content/70 hover:bg-base-200"
                  ]}
                >
                  <span
                    :if={@settings.enabled}
                    class="relative flex size-2"
                  >
                    <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-white opacity-75" />
                    <span class="relative inline-flex rounded-full size-2 bg-white" />
                  </span>
                  <span
                    :if={!@settings.enabled}
                    class="size-2 rounded-full bg-base-content/30"
                  />
                  {if @settings.enabled, do: "Live", else: "Paused"}
                </button>
              </div>
            </div>
          </div>
        </div>

        <%!-- Main Content --%>
        <div class="max-w-7xl mx-auto px-4 py-6">
          <%!-- Alert for unconfigured API --%>
          <div
            :if={!@api_configured}
            class="mb-6 p-4 rounded-xl bg-error/5 border border-error/20 flex items-start justify-between gap-3"
          >
            <div class="flex items-start gap-3">
              <.icon name="hero-exclamation-triangle" class="size-5 text-error shrink-0 mt-0.5" />
              <div class="text-sm">
                <p class="font-medium text-error">API credentials not configured</p>
                <p class="text-base-content/60 mt-1">
                  Add your Polymarket API credentials to enable trade tracking.
                </p>
              </div>
            </div>
            <button
              type="button"
              phx-click="toggle_credentials"
              class="px-3 py-1.5 rounded-lg bg-error/10 text-error text-sm font-medium hover:bg-error/20 transition-colors shrink-0"
            >
              Configure
            </button>
          </div>

          <div class="grid grid-cols-1 xl:grid-cols-12 gap-6">
            <%!-- Left Column: Tracked Users + Activity --%>
            <div class="xl:col-span-8 space-y-6">
              <%!-- Tracked Users Card --%>
              <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
                <div class="px-5 py-4 border-b border-base-300 flex items-center justify-between">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-users" class="size-5 text-primary" />
                    <h2 class="font-semibold">Tracked Wallets</h2>
                    <span class="px-2 py-0.5 rounded-full bg-base-300 text-xs font-medium">
                      {length(@tracked_users)}
                    </span>
                  </div>
                </div>

                <div class="p-5">
                  <%!-- Add User Form --%>
                  <form
                    phx-submit="add_user"
                    phx-change="validate_add_user"
                    id="add-user-form"
                    class="flex gap-2 mb-5"
                  >
                    <div class="flex-1 relative">
                      <input
                        type="text"
                        name="address"
                        value={@add_user_form["address"].value}
                        placeholder="Enter wallet address (0x...)"
                        class="w-full px-4 py-2.5 rounded-xl bg-base-100 border border-base-300 text-sm placeholder:text-base-content/40 focus:outline-none focus:ring-2 focus:ring-primary/20 focus:border-primary transition-all"
                        required
                      />
                    </div>
                    <input
                      type="text"
                      name="label"
                      value={@add_user_form["label"].value}
                      placeholder="Label"
                      class="w-45 px-3 py-2.5 rounded-xl bg-base-100 border border-base-300 text-sm placeholder:text-base-content/40 focus:outline-none focus:ring-2 focus:ring-primary/20 focus:border-primary transition-all"
                    />
                    <button
                      type="submit"
                      class="px-4 py-2.5 rounded-xl bg-primary text-primary-content font-medium text-sm hover:bg-primary/90 transition-colors flex items-center gap-1.5"
                    >
                      <.icon name="hero-plus" class="size-4" /> Add
                    </button>
                  </form>

                  <%!-- Users List --%>
                  <div class="space-y-2">
                    <div
                      :if={@tracked_users == []}
                      class="py-12 text-center"
                    >
                      <div class="w-16 h-16 rounded-2xl bg-base-300/50 flex items-center justify-center mx-auto mb-4">
                        <.icon name="hero-user-plus" class="size-8 text-base-content/30" />
                      </div>
                      <p class="text-base-content/50 font-medium">No wallets tracked</p>
                      <p class="text-sm text-base-content/40 mt-1">
                        Add a wallet address to start monitoring trades
                      </p>
                    </div>

                    <div
                      :for={user <- @tracked_users}
                      class={[
                        "group flex items-center justify-between p-3 rounded-xl border transition-colors",
                        @feed_filter == user.address && "bg-primary/5 border-primary/30",
                        @feed_filter != user.address &&
                          "bg-base-100 border-base-300/50 hover:border-base-300"
                      ]}
                    >
                      <%= if @editing_user == user.address do %>
                        <%!-- Edit Mode --%>
                        <form
                          phx-submit="save_user_label"
                          class="flex items-center gap-3 flex-1"
                        >
                          <input type="hidden" name="address" value={user.address} />
                          <div class={[
                            "w-10 h-10 rounded-xl flex items-center justify-center shrink-0",
                            "bg-gradient-to-br from-primary/20 to-secondary/20"
                          ]}>
                            <span class="text-sm font-bold text-primary">
                              {user.label |> String.slice(0, 2) |> String.upcase()}
                            </span>
                          </div>
                          <div class="flex-1">
                            <input
                              type="text"
                              name="label"
                              value={user.label}
                              autofocus
                              class="w-full px-3 py-1.5 rounded-lg bg-base-100 border border-primary/30 text-sm font-medium focus:outline-none focus:ring-2 focus:ring-primary/20 focus:border-primary transition-all"
                              placeholder="Enter label"
                            />
                            <p class="text-xs text-base-content/40 font-mono mt-1">
                              {String.slice(user.address, 0, 10)}...{String.slice(user.address, -6, 6)}
                            </p>
                          </div>
                          <div class="flex items-center gap-1">
                            <button
                              type="submit"
                              class="p-2 rounded-lg text-success hover:bg-success/10 transition-all"
                              title="Save"
                            >
                              <.icon name="hero-check" class="size-4" />
                            </button>
                            <button
                              type="button"
                              phx-click="cancel_edit_label"
                              class="p-2 rounded-lg text-base-content/50 hover:text-error hover:bg-error/10 transition-all"
                              title="Cancel"
                            >
                              <.icon name="hero-x-mark" class="size-4" />
                            </button>
                          </div>
                        </form>
                      <% else %>
                        <%!-- Normal View --%>
                        <div class="flex items-center gap-3">
                          <div class={[
                            "w-10 h-10 rounded-xl flex items-center justify-center",
                            @feed_filter == user.address && "bg-primary/20",
                            @feed_filter != user.address &&
                              "bg-gradient-to-br from-primary/20 to-secondary/20"
                          ]}>
                            <span class="text-sm font-bold text-primary">
                              {user.label |> String.slice(0, 2) |> String.upcase()}
                            </span>
                          </div>
                          <div>
                            <div class="flex items-center gap-1">
                              <.link
                                navigate={~p"/profile/#{user.address}"}
                                class="font-medium text-sm hover:text-primary transition-colors"
                              >
                                {user.label}
                              </.link>
                              <.link
                                navigate={~p"/profile/#{user.address}"}
                                title="View trade analysis"
                                class="p-1 rounded text-base-content/30 hover:text-info hover:bg-info/10 opacity-0 group-hover:opacity-100 transition-all"
                              >
                                <.icon name="hero-chart-bar" class="size-3" />
                              </.link>
                              <a
                                href={"https://polymarket.com/profile/#{user.address}"}
                                target="_blank"
                                rel="noopener noreferrer"
                                title="View on Polymarket"
                                class="p-1 rounded text-base-content/30 hover:text-primary hover:bg-primary/10 opacity-0 group-hover:opacity-100 transition-all"
                              >
                                <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                              </a>
                              <button
                                type="button"
                                phx-click="edit_user_label"
                                phx-value-address={user.address}
                                title="Edit label"
                                class="p-1 rounded text-base-content/30 hover:text-primary hover:bg-primary/10 opacity-0 group-hover:opacity-100 transition-all"
                              >
                                <.icon name="hero-pencil" class="size-3" />
                              </button>
                            </div>
                            <p class="text-xs text-base-content/40 font-mono">
                              {String.slice(user.address, 0, 10)}...{String.slice(user.address, -6, 6)}
                            </p>
                          </div>
                        </div>
                        <div class="flex items-center gap-2">
                          <div class="text-right mr-1">
                            <p class="text-sm font-semibold">{length(user.trades)}</p>
                            <p class="text-xs text-base-content/40">trades</p>
                          </div>
                          <button
                            type="button"
                            phx-click="filter_feed"
                            phx-value-address={user.address}
                            title={
                              if @feed_filter == user.address, do: "Show all", else: "Filter feed"
                            }
                            class={[
                              "p-2 rounded-lg transition-all",
                              @feed_filter == user.address && "text-primary bg-primary/10",
                              @feed_filter != user.address &&
                                "text-base-content/30 hover:text-info hover:bg-info/10 opacity-0 group-hover:opacity-100"
                            ]}
                          >
                            <.icon name="hero-funnel" class="size-4" />
                          </button>
                          <button
                            type="button"
                            phx-click="archive_user"
                            phx-value-address={user.address}
                            title="Archive user"
                            class="p-2 rounded-lg text-base-content/30 hover:text-warning hover:bg-warning/10 opacity-0 group-hover:opacity-100 transition-all"
                          >
                            <.icon name="hero-archive-box" class="size-4" />
                          </button>
                        </div>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>

              <%!-- Archived Users (collapsible) --%>
              <div :if={@archived_users != []}>
                <button
                  type="button"
                  phx-click="toggle_archived"
                  class="flex items-center gap-2 cursor-pointer text-sm text-base-content/50 hover:text-base-content/70 transition-colors"
                >
                  <.icon
                    name="hero-chevron-right"
                    class={
                      if @show_archived,
                        do: "size-4 transition-transform rotate-90",
                        else: "size-4 transition-transform"
                    }
                  />
                  <.icon name="hero-archive-box" class="size-4" />
                  <span>Archived ({length(@archived_users)})</span>
                </button>
                <div :if={@show_archived} class="mt-3 space-y-2">
                  <div
                    :for={user <- @archived_users}
                    class="flex items-center justify-between p-3 rounded-xl bg-base-200/30 border border-base-300/30"
                  >
                    <div class="flex items-center gap-3">
                      <div class="w-8 h-8 rounded-lg bg-base-300/50 flex items-center justify-center">
                        <span class="text-xs font-bold text-base-content/40">
                          {user.label |> String.slice(0, 2) |> String.upcase()}
                        </span>
                      </div>
                      <div>
                        <div class="flex items-center gap-1">
                          <.link
                            navigate={~p"/profile/#{user.address}"}
                            class="font-medium text-sm text-base-content/60 hover:text-primary transition-colors"
                          >
                            {user.label}
                          </.link>
                          <a
                            href={"https://polymarket.com/profile/#{user.address}"}
                            target="_blank"
                            rel="noopener noreferrer"
                            title="View on Polymarket"
                            class="text-base-content/30 hover:text-primary transition-colors"
                          >
                            <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                          </a>
                        </div>
                        <p class="text-xs text-base-content/30 font-mono">
                          {String.slice(user.address, 0, 10)}...{String.slice(user.address, -6, 6)}
                        </p>
                      </div>
                    </div>
                    <div class="flex items-center gap-2">
                      <button
                        type="button"
                        phx-click="restore_user"
                        phx-value-address={user.address}
                        title="Restore user"
                        class="px-3 py-1.5 rounded-lg text-xs font-medium bg-primary/10 text-primary hover:bg-primary hover:text-primary-content transition-colors"
                      >
                        Restore
                      </button>
                      <button
                        type="button"
                        phx-click="delete_user"
                        phx-value-address={user.address}
                        data-confirm="Are you sure you want to permanently delete this wallet? This cannot be undone."
                        title="Delete permanently"
                        class="p-1.5 rounded-lg text-error/60 hover:text-error hover:bg-error/10 transition-colors"
                      >
                        <.icon name="hero-trash" class="size-4" />
                      </button>
                    </div>
                  </div>
                </div>
              </div>

              <%!-- Live Feed from Tracked Wallets --%>
              <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
                <div class="px-5 py-4 border-b border-base-300 flex items-center justify-between">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-rss" class="size-5 text-info" />
                    <h2 class="font-semibold">Live Feed</h2>
                    <span class="relative flex size-2">
                      <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-info opacity-75" />
                      <span class="relative inline-flex rounded-full size-2 bg-info" />
                    </span>
                  </div>
                  <%= if @feed_filter do %>
                    <button
                      type="button"
                      phx-click="clear_feed_filter"
                      class="flex items-center gap-1.5 px-2.5 py-1 rounded-lg bg-primary/10 text-primary text-xs font-medium hover:bg-primary/20 transition-colors"
                    >
                      <.icon name="hero-funnel" class="size-3.5" />
                      {get_filter_label(@tracked_users, @feed_filter)}
                      <.icon name="hero-x-mark" class="size-3.5" />
                    </button>
                  <% else %>
                    <span class="text-xs text-base-content/40">Tracked wallet trades</span>
                  <% end %>
                </div>

                <div
                  id="live-feed"
                  phx-update="stream"
                  class="divide-y divide-base-300/50 max-h-[350px] overflow-y-auto"
                >
                  <div
                    id="live-feed-empty"
                    class="hidden only:block py-12 text-center"
                  >
                    <div class="w-16 h-16 rounded-2xl bg-base-300/50 flex items-center justify-center mx-auto mb-4">
                      <.icon name="hero-signal" class="size-8 text-base-content/30" />
                    </div>
                    <p class="text-base-content/50 font-medium">No trades yet</p>
                    <p class="text-sm text-base-content/40 mt-1">
                      Trades from tracked wallets will appear here
                    </p>
                  </div>

                  <div
                    :for={{id, item} <- @streams.live_feed}
                    id={id}
                    class="flex items-start gap-3 px-5 py-3 hover:bg-base-100/50 transition-colors"
                  >
                    <%!-- Outcome badge --%>
                    <div class={[
                      "w-10 h-10 rounded-lg flex items-center justify-center text-xs font-bold shrink-0",
                      outcome_class(item.outcome, item.side)
                    ]}>
                      {outcome_label(item.outcome, item.side)}
                    </div>
                    <div class="flex-1 min-w-0">
                      <%!-- Market title and trader --%>
                      <div class="flex items-start justify-between gap-2">
                        <div class="min-w-0">
                          <a
                            :if={item.event_slug}
                            href={"https://polymarket.com/event/#{item.event_slug}"}
                            target="_blank"
                            rel="noopener noreferrer"
                            class="text-sm font-medium leading-tight truncate block hover:text-primary transition-colors"
                            title={item.title}
                          >
                            {item.title || "Unknown Market"}
                            <.icon
                              name="hero-arrow-top-right-on-square"
                              class="size-3 inline ml-1 opacity-50"
                            />
                          </a>
                          <p
                            :if={!item.event_slug}
                            class="text-sm font-medium leading-tight truncate"
                            title={item.title}
                          >
                            {item.title || "Unknown Market"}
                          </p>
                          <p class="text-xs text-base-content/50 mt-0.5">
                            <span class="font-medium">{item.label}</span>
                            <%= if format_relative_time(item.timestamp) do %>
                              <span class="text-base-content/30"> • </span>
                              <span class="text-base-content/40">
                                {format_relative_time(item.timestamp)}
                              </span>
                            <% end %>
                          </p>
                        </div>
                      </div>
                      <%!-- Trade details --%>
                      <div class="flex flex-wrap items-center gap-x-3 gap-y-1 mt-2 text-xs">
                        <span class={[
                          "px-1.5 py-0.5 rounded font-semibold",
                          item.side in ["BUY", "YES"] && "bg-success/10 text-success",
                          item.side in ["SELL", "NO"] && "bg-error/10 text-error",
                          item.side not in ["BUY", "YES", "SELL", "NO"] &&
                            "bg-base-300 text-base-content/60"
                        ]}>
                          {item.side}
                        </span>
                        <span class="font-mono text-base-content/70">
                          {format_shares(item.size)} shares @ {format_price(item.avg_price)}
                        </span>
                        <span :if={item.usdc_size > 0} class="text-base-content/30">•</span>
                        <span
                          :if={item.usdc_size > 0}
                          class="font-mono font-medium text-base-content/80"
                        >
                          ${format_currency(item.usdc_size)}
                        </span>
                      </div>
                    </div>
                    <%!-- Copy button --%>
                    <div class="shrink-0 pt-1">
                      <%= if MapSet.member?(@copied_trade_ids, item.trade_id) do %>
                        <span class="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-lg bg-success/10 text-success text-xs font-medium">
                          <.icon name="hero-check" class="size-3.5" /> Copied
                        </span>
                      <% else %>
                        <button
                          type="button"
                          phx-click="manual_copy"
                          phx-value-trade_id={item.trade_id}
                          phx-value-address={item.address}
                          phx-value-side={item.side}
                          phx-value-size={item.size}
                          phx-value-price={item.price}
                          phx-value-outcome={item.outcome}
                          phx-value-market_slug={item.market_slug}
                          phx-value-asset_id={item.asset_id}
                          phx-value-title={item.title}
                          phx-value-event_slug={item.event_slug}
                          class="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-lg bg-primary/10 text-primary hover:bg-primary hover:text-primary-content text-xs font-medium transition-colors"
                        >
                          <.icon name="hero-document-duplicate" class="size-3.5" /> Copy
                        </button>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>

              <%!-- Copy Trades Activity --%>
              <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
                <div class="px-5 py-4 border-b border-base-300 flex items-center justify-between">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-bolt" class="size-5 text-secondary" />
                    <h2 class="font-semibold">Copy Activity</h2>
                  </div>
                  <button
                    type="button"
                    phx-click="delete_all_failed"
                    data-confirm="Delete all failed trades? This cannot be undone."
                    class="flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg bg-error/10 text-error text-xs font-medium hover:bg-error hover:text-error-content transition-colors"
                  >
                    <.icon name="hero-trash" class="size-3.5" /> Delete All Failed
                  </button>
                </div>

                <div
                  id="copy-trades"
                  phx-update="stream"
                  class="p-5 space-y-2 max-h-[400px] overflow-y-auto"
                >
                  <div
                    id="copy-trades-empty"
                    class="hidden only:block py-12 text-center"
                  >
                    <div class="w-16 h-16 rounded-2xl bg-base-300/50 flex items-center justify-center mx-auto mb-4">
                      <.icon name="hero-clock" class="size-8 text-base-content/30" />
                    </div>
                    <p class="text-base-content/50 font-medium">Waiting for trades</p>
                    <p class="text-sm text-base-content/40 mt-1">
                      Copy trades will appear here in real-time
                    </p>
                  </div>

                  <div
                    :for={{id, trade} <- @streams.copy_trades}
                    id={id}
                    class={[
                      "flex items-start gap-3 p-3 rounded-xl border transition-all",
                      trade.status == :simulated && "bg-warning/5 border-warning/20",
                      trade.status == :executed && "bg-success/5 border-success/20",
                      trade.status == :failed && "bg-error/5 border-error/20",
                      trade.status == :pending && "bg-base-100 border-base-300/50"
                    ]}
                  >
                    <%!-- Outcome badge --%>
                    <div class={[
                      "w-10 h-10 rounded-lg flex items-center justify-center text-xs font-bold shrink-0",
                      outcome_class(trade.outcome, trade.side)
                    ]}>
                      {outcome_label(trade.outcome, trade.side)}
                    </div>
                    <div class="flex-1 min-w-0">
                      <%!-- Market title with link --%>
                      <div class="flex items-start justify-between gap-2">
                        <div class="min-w-0">
                          <a
                            :if={trade.event_slug}
                            href={"https://polymarket.com/event/#{trade.event_slug}"}
                            target="_blank"
                            rel="noopener noreferrer"
                            class="text-sm font-medium leading-tight truncate block hover:text-primary transition-colors"
                            title={trade.title}
                          >
                            {trade.title || "Unknown Market"}
                            <.icon
                              name="hero-arrow-top-right-on-square"
                              class="size-3 inline ml-1 opacity-50"
                            />
                          </a>
                          <p
                            :if={!trade.event_slug}
                            class="text-sm font-medium leading-tight truncate"
                            title={trade.title}
                          >
                            {trade.title || "Unknown Market"}
                          </p>
                          <p class="text-xs text-base-content/50 mt-0.5">
                            From
                            <span class="font-medium">{short_address(trade.source_address)}</span>
                            {if trade.executed_at, do: " • #{format_time(trade.executed_at)}"}
                          </p>
                        </div>
                      </div>
                      <%!-- Position details --%>
                      <div class="flex flex-wrap items-center gap-x-3 gap-y-1 mt-2 text-xs">
                        <span class={[
                          "px-1.5 py-0.5 rounded font-semibold",
                          trade.side in ["BUY", "YES"] && "bg-success/10 text-success",
                          trade.side in ["SELL", "NO"] && "bg-error/10 text-error",
                          trade.side not in ["BUY", "YES", "SELL", "NO"] &&
                            "bg-base-300 text-base-content/60"
                        ]}>
                          {trade.side}
                        </span>
                        <span class="font-mono text-base-content/70">
                          ${format_size(trade.copy_size)} ({format_shares_from_trade(trade)} shares) @ {format_price(
                            trade.original_price
                          )}
                        </span>
                      </div>
                    </div>
                    <%!-- Status and actions --%>
                    <div class="flex items-center gap-2 shrink-0">
                      <span class={[
                        "px-2 py-0.5 rounded text-xs font-medium",
                        trade.status == :simulated && "bg-warning/10 text-warning",
                        trade.status == :executed && "bg-success/10 text-success",
                        trade.status == :failed && "bg-error/10 text-error",
                        trade.status == :pending && "bg-base-300 text-base-content/60"
                      ]}>
                        {status_label(trade.status)}
                      </span>
                      <button
                        :if={trade.status == :failed}
                        type="button"
                        phx-click="retry_trade"
                        phx-value-trade-id={trade.id}
                        class="px-2 py-0.5 rounded text-xs font-medium bg-primary/10 text-primary hover:bg-primary hover:text-primary-content transition-colors flex items-center gap-1"
                        title="Retry this trade"
                      >
                        <.icon name="hero-arrow-path" class="size-3" /> Retry
                      </button>
                      <button
                        :if={trade.status == :failed}
                        type="button"
                        phx-click="delete_trade"
                        phx-value-trade-id={trade.id}
                        class="px-2 py-0.5 rounded text-xs font-medium bg-error/10 text-error hover:bg-error hover:text-error-content transition-colors flex items-center gap-1"
                        title="Delete this trade"
                      >
                        <.icon name="hero-trash" class="size-3" />
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Right Column: Settings --%>
            <div class="xl:col-span-4 space-y-6">
              <%!-- Account Overview Card --%>
              <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
                <div class="px-5 py-4 border-b border-base-300">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-wallet" class="size-5 text-primary" />
                    <h2 class="font-semibold">Account</h2>
                  </div>
                </div>

                <div class="p-5 space-y-4">
                  <%!-- Balance --%>
                  <div class="flex items-center justify-between">
                    <span class="text-sm text-base-content/60">Balance</span>
                    <span class="text-lg font-semibold">
                      <%= if @account_summary.usdc_balance do %>
                        ${:erlang.float_to_binary(@account_summary.usdc_balance * 1.0, decimals: 2)}
                      <% else %>
                        <span class="text-base-content/40">--</span>
                      <% end %>
                    </span>
                  </div>

                  <%!-- Positions Value --%>
                  <div class="flex items-center justify-between">
                    <span class="text-sm text-base-content/60">Positions</span>
                    <span class="font-medium">
                      ${:erlang.float_to_binary(@account_summary.positions_value * 1.0, decimals: 2)}
                      <span class="text-xs text-base-content/40 ml-1">
                        ({@account_summary.positions_count})
                      </span>
                    </span>
                  </div>

                  <%!-- PnL --%>
                  <div class="flex items-center justify-between">
                    <span class="text-sm text-base-content/60">Total PnL</span>
                    <span class={[
                      "font-semibold",
                      @account_summary.total_pnl > 0 && "text-success",
                      @account_summary.total_pnl < 0 && "text-error",
                      @account_summary.total_pnl == 0.0 && "text-base-content/60"
                    ]}>
                      <%= if @account_summary.total_pnl >= 0 do %>
                        +
                      <% end %>${:erlang.float_to_binary(@account_summary.total_pnl * 1.0,
                        decimals: 2
                      )}
                    </span>
                  </div>
                </div>
              </div>

              <%!-- API Credentials Card --%>
              <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
                <div class="px-5 py-4 border-b border-base-300">
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-2">
                      <.icon name="hero-key" class="size-5 text-warning" />
                      <h2 class="font-semibold">API Credentials</h2>
                    </div>
                    <button
                      type="button"
                      phx-click="toggle_credentials"
                      class="text-xs text-base-content/60 hover:text-base-content flex items-center gap-1"
                    >
                      <%= if @show_credentials do %>
                        <.icon name="hero-chevron-up" class="size-4" /> Hide
                      <% else %>
                        <.icon name="hero-chevron-down" class="size-4" />
                        {if @api_configured, do: "Edit", else: "Setup"}
                      <% end %>
                    </button>
                  </div>
                </div>

                <div class="p-5">
                  <%= if @show_credentials do %>
                    <form
                      phx-submit="save_credentials"
                      id="credentials-form"
                      phx-update="ignore"
                      class="space-y-4"
                    >
                      <div class="space-y-3">
                        <div>
                          <label class="block text-xs font-medium text-base-content/60 mb-1">
                            API Key
                          </label>
                          <input
                            type="text"
                            name="api_key"
                            value={@credentials_form.api_key}
                            placeholder="Enter API key"
                            class="w-full px-3 py-2 rounded-lg bg-base-100 border border-base-300 text-sm placeholder:text-base-content/40 focus:outline-none focus:ring-2 focus:ring-primary/20 focus:border-primary"
                          />
                        </div>
                        <div>
                          <label class="block text-xs font-medium text-base-content/60 mb-1">
                            API Secret
                          </label>
                          <input
                            type="text"
                            name="api_secret"
                            value={@credentials_form.api_secret}
                            placeholder="Enter API secret"
                            class="w-full px-3 py-2 rounded-lg bg-base-100 border border-base-300 text-sm placeholder:text-base-content/40 focus:outline-none focus:ring-2 focus:ring-primary/20 focus:border-primary"
                          />
                        </div>
                        <div>
                          <label class="block text-xs font-medium text-base-content/60 mb-1">
                            API Passphrase
                          </label>
                          <input
                            type="text"
                            name="api_passphrase"
                            value={@credentials_form.api_passphrase}
                            placeholder="Enter API passphrase"
                            class="w-full px-3 py-2 rounded-lg bg-base-100 border border-base-300 text-sm placeholder:text-base-content/40 focus:outline-none focus:ring-2 focus:ring-primary/20 focus:border-primary"
                          />
                        </div>
                        <div>
                          <label class="block text-xs font-medium text-base-content/60 mb-1">
                            Wallet Address (Proxy)
                          </label>
                          <input
                            type="text"
                            name="wallet_address"
                            value={@credentials_form.wallet_address}
                            placeholder="0x..."
                            class="w-full px-3 py-2 rounded-lg bg-base-100 border border-base-300 text-sm font-mono placeholder:text-base-content/40 focus:outline-none focus:ring-2 focus:ring-primary/20 focus:border-primary"
                          />
                        </div>
                        <div>
                          <label class="block text-xs font-medium text-base-content/60 mb-1">
                            Signer Address (Optional)
                          </label>
                          <input
                            type="text"
                            name="signer_address"
                            value={@credentials_form.signer_address}
                            placeholder="0x... (leave empty if same as wallet)"
                            class="w-full px-3 py-2 rounded-lg bg-base-100 border border-base-300 text-sm font-mono placeholder:text-base-content/40 focus:outline-none focus:ring-2 focus:ring-primary/20 focus:border-primary"
                          />
                        </div>
                        <div>
                          <label class="block text-xs font-medium text-base-content/60 mb-1">
                            Private Key
                          </label>
                          <input
                            type="text"
                            name="private_key"
                            value={@credentials_form.private_key}
                            placeholder="Enter private key (without 0x prefix)"
                            class="w-full px-3 py-2 rounded-lg bg-base-100 border border-base-300 text-sm font-mono placeholder:text-base-content/40 focus:outline-none focus:ring-2 focus:ring-primary/20 focus:border-primary"
                          />
                        </div>
                      </div>
                      <div class="flex gap-2">
                        <button
                          type="submit"
                          class="flex-1 px-4 py-2 rounded-lg bg-primary text-primary-content font-medium text-sm hover:bg-primary/90 transition-colors"
                        >
                          Save Credentials
                        </button>
                        <button
                          type="button"
                          phx-click="toggle_credentials"
                          class="px-4 py-2 rounded-lg bg-base-300 text-base-content font-medium text-sm hover:bg-base-300/80 transition-colors"
                        >
                          Cancel
                        </button>
                      </div>
                    </form>
                  <% else %>
                    <div class="space-y-2 text-sm">
                      <div class="flex items-center justify-between">
                        <span class="text-base-content/60">Status</span>
                        <%= if @api_configured do %>
                          <span class="px-2 py-0.5 rounded-full bg-success/10 text-success text-xs font-medium">
                            Configured
                          </span>
                        <% else %>
                          <span class="px-2 py-0.5 rounded-full bg-error/10 text-error text-xs font-medium">
                            Not configured
                          </span>
                        <% end %>
                      </div>
                      <%= if @credentials.wallet_address do %>
                        <div class="flex items-center justify-between">
                          <span class="text-base-content/60">Wallet</span>
                          <div class="flex items-center gap-1.5">
                            <span class="font-mono text-xs">
                              {String.slice(@credentials.wallet_address || "", 0, 6)}...{String.slice(
                                @credentials.wallet_address || "",
                                -4,
                                4
                              )}
                            </span>
                            <button
                              type="button"
                              phx-click={
                                JS.dispatch("phx:copy", detail: %{text: @credentials.wallet_address})
                              }
                              class="p-1 rounded text-base-content/30 hover:text-primary hover:bg-primary/10 transition-all"
                              title="Copy wallet address"
                            >
                              <.icon name="hero-clipboard-document" class="size-3.5" />
                            </button>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>

              <%!-- Trade Sizing Card --%>
              <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
                <div class="px-5 py-4 border-b border-base-300">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-adjustments-horizontal" class="size-5 text-accent" />
                    <h2 class="font-semibold">Trade Sizing</h2>
                  </div>
                </div>

                <div class="p-5">
                  <form phx-change="update_sizing" id="settings-form" class="space-y-4">
                    <%!-- Sizing Mode Tabs --%>
                    <div class="grid grid-cols-3 gap-1 p-1 rounded-xl bg-base-300/50">
                      <label class={[
                        "px-3 py-2 rounded-lg text-center text-sm font-medium cursor-pointer transition-all",
                        @settings.sizing_mode == :fixed && "bg-base-100 shadow-sm",
                        @settings.sizing_mode != :fixed && "hover:bg-base-200/50"
                      ]}>
                        <input
                          type="radio"
                          name="sizing_mode"
                          value="fixed"
                          checked={@settings.sizing_mode == :fixed}
                          class="sr-only"
                        /> Fixed
                      </label>
                      <label class={[
                        "px-3 py-2 rounded-lg text-center text-sm font-medium cursor-pointer transition-all",
                        @settings.sizing_mode == :proportional && "bg-base-100 shadow-sm",
                        @settings.sizing_mode != :proportional && "hover:bg-base-200/50"
                      ]}>
                        <input
                          type="radio"
                          name="sizing_mode"
                          value="proportional"
                          checked={@settings.sizing_mode == :proportional}
                          class="sr-only"
                        /> Scale
                      </label>
                      <label class={[
                        "px-3 py-2 rounded-lg text-center text-sm font-medium cursor-pointer transition-all",
                        @settings.sizing_mode == :percentage && "bg-base-100 shadow-sm",
                        @settings.sizing_mode != :percentage && "hover:bg-base-200/50"
                      ]}>
                        <input
                          type="radio"
                          name="sizing_mode"
                          value="percentage"
                          checked={@settings.sizing_mode == :percentage}
                          class="sr-only"
                        /> Percent
                      </label>
                    </div>

                    <%!-- Fixed Amount --%>
                    <div :if={@settings.sizing_mode == :fixed} class="space-y-2">
                      <label class="text-sm text-base-content/60">Amount per trade</label>
                      <div class="relative">
                        <span class="absolute left-3 top-1/2 -translate-y-1/2 text-base-content/40">
                          $
                        </span>
                        <input
                          type="number"
                          name="fixed_amount"
                          value={@settings.fixed_amount}
                          step="0.5"
                          min="0.5"
                          class="w-full pl-7 pr-16 py-3 rounded-xl bg-base-100 border border-base-300 text-lg font-semibold focus:outline-none focus:ring-2 focus:ring-primary/20 focus:border-primary transition-all"
                        />
                        <span class="absolute right-3 top-1/2 -translate-y-1/2 text-base-content/40 text-sm">
                          USDC
                        </span>
                      </div>
                      <p class="text-xs text-base-content/40">
                        <.icon name="hero-information-circle" class="size-3 inline" />
                        Min 5 shares required. At high prices (~$1), minimum is ~$5.
                      </p>
                    </div>

                    <%!-- Proportional Factor --%>
                    <div :if={@settings.sizing_mode == :proportional} class="space-y-2">
                      <label class="text-sm text-base-content/60">Scale factor</label>
                      <div class="relative">
                        <input
                          type="number"
                          name="proportional_factor"
                          value={@settings.proportional_factor}
                          step="0.01"
                          min="0.01"
                          max="10"
                          class="w-full px-4 py-3 rounded-xl bg-base-100 border border-base-300 text-lg font-semibold focus:outline-none focus:ring-2 focus:ring-primary/20 focus:border-primary transition-all"
                        />
                        <span class="absolute right-3 top-1/2 -translate-y-1/2 text-base-content/40 text-sm">
                          x
                        </span>
                      </div>
                      <p class="text-xs text-base-content/40">
                        0.1x = copy 10% of original size
                      </p>
                    </div>

                    <%!-- Percentage --%>
                    <div :if={@settings.sizing_mode == :percentage} class="space-y-2">
                      <label class="text-sm text-base-content/60">Percentage of balance</label>
                      <div class="relative">
                        <input
                          type="number"
                          name="percentage"
                          value={@settings.percentage}
                          step="0.5"
                          min="0.5"
                          max="100"
                          class="w-full px-4 pr-10 py-3 rounded-xl bg-base-100 border border-base-300 text-lg font-semibold focus:outline-none focus:ring-2 focus:ring-primary/20 focus:border-primary transition-all"
                        />
                        <span class="absolute right-3 top-1/2 -translate-y-1/2 text-base-content/40 text-sm">
                          %
                        </span>
                      </div>
                    </div>

                    <%!-- Hidden inputs to preserve values --%>
                    <input
                      :if={@settings.sizing_mode != :fixed}
                      type="hidden"
                      name="fixed_amount"
                      value={@settings.fixed_amount}
                    />
                    <input
                      :if={@settings.sizing_mode != :proportional}
                      type="hidden"
                      name="proportional_factor"
                      value={@settings.proportional_factor}
                    />
                    <input
                      :if={@settings.sizing_mode != :percentage}
                      type="hidden"
                      name="percentage"
                      value={@settings.percentage}
                    />
                  </form>
                </div>
              </div>

              <%!-- Status Card --%>
              <div class="rounded-2xl bg-base-200/50 border border-base-300 overflow-hidden">
                <div class="px-5 py-4 border-b border-base-300">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-signal" class="size-5 text-info" />
                    <h2 class="font-semibold">Status</h2>
                  </div>
                </div>

                <div class="p-5 space-y-4">
                  <div class="flex items-center justify-between">
                    <span class="text-sm text-base-content/60">Copy Trading</span>
                    <div class="flex items-center gap-2">
                      <span
                        :if={@settings.enabled}
                        class="relative flex size-2"
                      >
                        <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-success opacity-75" />
                        <span class="relative inline-flex rounded-full size-2 bg-success" />
                      </span>
                      <span :if={!@settings.enabled} class="size-2 rounded-full bg-error" />
                      <span class={[
                        "text-sm font-medium",
                        @settings.enabled && "text-success",
                        !@settings.enabled && "text-error"
                      ]}>
                        {if @settings.enabled, do: "Active", else: "Paused"}
                      </span>
                    </div>
                  </div>

                  <div class="flex items-center justify-between">
                    <span class="text-sm text-base-content/60">Sizing</span>
                    <span class="text-sm font-medium">
                      {case @settings.sizing_mode do
                        :fixed -> "$#{format_fixed_amount(@settings.fixed_amount)} (5 share min)"
                        :proportional -> "#{@settings.proportional_factor}x scale"
                        :percentage -> "#{@settings.percentage}% balance"
                      end}
                    </span>
                  </div>

                  <div class="flex items-center justify-between">
                    <span class="text-sm text-base-content/60">Tracked</span>
                    <span class="text-sm font-medium">{length(@tracked_users)} wallets</span>
                  </div>
                </div>
              </div>

              <%!-- Info Card --%>
              <div class="rounded-2xl bg-gradient-to-br from-primary/5 to-secondary/5 border border-primary/10 p-5">
                <div class="flex items-start gap-3">
                  <div class="w-8 h-8 rounded-lg bg-primary/10 flex items-center justify-center shrink-0">
                    <.icon name="hero-light-bulb" class="size-4 text-primary" />
                  </div>
                  <div>
                    <p class="text-sm font-medium">How it works</p>
                    <p class="text-xs text-base-content/60 mt-1 leading-relaxed">
                      Add wallet addresses to track. When they make trades on Polymarket,
                      we'll automatically copy those trades using your configured sizing.
                    </p>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp format_size(size) when is_number(size),
    do: :erlang.float_to_binary(size * 1.0, decimals: 2)

  defp format_size(_), do: "0.00"

  # Format fixed amount - show integer if whole number
  defp format_fixed_amount(amount) when is_number(amount) do
    if amount == trunc(amount) do
      Integer.to_string(trunc(amount))
    else
      :erlang.float_to_binary(amount * 1.0, decimals: 1)
    end
  end

  defp format_fixed_amount(_), do: "0"

  defp format_price(price) when is_number(price),
    do: :erlang.float_to_binary(price * 1.0, decimals: 4)

  defp format_price(_), do: "0.0000"

  # Format shares with appropriate decimal places
  defp format_shares(shares) when is_number(shares) do
    cond do
      shares >= 1000 -> :erlang.float_to_binary(shares / 1000, decimals: 1) <> "k"
      shares >= 1 -> :erlang.float_to_binary(shares * 1.0, decimals: 1)
      true -> :erlang.float_to_binary(shares * 1.0, decimals: 2)
    end
  end

  defp format_shares(_), do: "0"

  # Format currency (dollars) with 2 decimal places
  defp format_currency(amount) when is_number(amount) do
    :erlang.float_to_binary(abs(amount) * 1.0, decimals: 2)
  end

  defp format_currency(_), do: "0.00"

  defp short_address(address) when is_binary(address) do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
  end

  defp short_address(_), do: "unknown"

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(_), do: ""

  # Format relative time like "6 minutes ago"
  defp format_relative_time(nil), do: nil

  defp format_relative_time(timestamp) when is_integer(timestamp) do
    now = System.system_time(:second)
    diff_seconds = now - timestamp

    cond do
      diff_seconds < 60 -> "just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)}h ago"
      diff_seconds < 604_800 -> "#{div(diff_seconds, 86400)}d ago"
      true -> "#{div(diff_seconds, 604_800)}w ago"
    end
  end

  defp format_relative_time(_), do: nil

  # Calculate shares from trade: for BUY, shares = size/price
  defp format_shares_from_trade(trade) do
    size = to_float(trade.copy_size)
    price = to_float(trade.original_price)

    if price > 0 do
      shares = size / price
      format_shares(shares)
    else
      "0"
    end
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n * 1.0
  defp to_float(_), do: 0.0

  defp status_label(:executed), do: "COPIED"
  defp status_label(:simulated), do: "SIMULATED"
  defp status_label(:failed), do: "FAILED"
  defp status_label(:pending), do: "PENDING"
  defp status_label(status), do: status |> to_string() |> String.upcase()

  # Outcome display helpers - handles Yes/No markets and multi-outcome markets
  defp outcome_class(outcome, side) do
    cond do
      outcome in ["Yes", "yes", "YES"] -> "bg-success/10 text-success"
      outcome in ["No", "no", "NO"] -> "bg-error/10 text-error"
      side in ["YES", "BUY"] -> "bg-success/10 text-success"
      side in ["NO", "SELL"] -> "bg-error/10 text-error"
      is_binary(outcome) and outcome != "" -> "bg-info/10 text-info"
      true -> "bg-base-300 text-base-content/50"
    end
  end

  defp outcome_label(outcome, side) do
    cond do
      outcome in ["Yes", "yes", "YES"] -> "YES"
      outcome in ["No", "no", "NO"] -> "NO"
      is_binary(outcome) and outcome != "" -> short_outcome(outcome)
      side in ["YES", "BUY"] -> "YES"
      side in ["NO", "SELL"] -> "NO"
      true -> "-"
    end
  end

  # Shorten long outcome names for multi-outcome markets
  defp short_outcome(outcome) when is_binary(outcome) do
    if String.length(outcome) <= 4 do
      String.upcase(outcome)
    else
      # Take first 3 chars
      outcome |> String.slice(0, 3) |> String.upcase()
    end
  end

  defp short_outcome(_), do: "-"

  defp fetch_account_summary do
    case Polyx.Polymarket.Client.get_account_summary() do
      {:ok, summary} ->
        summary

      {:error, _} ->
        %{usdc_balance: nil, positions_value: 0.0, total_pnl: 0.0, positions_count: 0}
    end
  end

  # Maximum trades to show in live feed - keeps the feed focused on recent activity
  @max_live_feed_items 25

  defp collect_live_feed(tracked_users) do
    tracked_users
    |> Enum.flat_map(fn user ->
      # Take all trades to sort globally, but we'll limit after sorting
      user.trades
      |> Enum.map(fn trade ->
        %{
          id: trade["id"] || System.unique_integer([:positive]),
          trade_id: trade["id"],
          address: user.address,
          label: user.label,
          side: trade["side"] || "UNKNOWN",
          size: parse_trade_value(trade["size"]),
          price: parse_trade_value(trade["price"]),
          avg_price: parse_trade_value(trade["avgPrice"]),
          outcome: trade["outcome"],
          title: trade["title"],
          market_slug: trade["market_slug"],
          event_slug: trade["event_slug"],
          asset_id: trade["asset_id"],
          pnl: parse_trade_value(trade["pnl"]),
          percent_pnl: parse_trade_value(trade["percentPnl"]),
          current_value: parse_trade_value(trade["currentValue"]),
          end_date: trade["endDate"],
          icon: trade["icon"],
          redeemable: trade["redeemable"],
          timestamp: parse_timestamp(trade["timestamp"]),
          usdc_size: parse_trade_value(trade["usdcSize"])
        }
      end)
    end)
    # Sort by size descending first for deterministic dedup (always keep largest)
    |> Enum.sort_by(& &1.size, :desc)
    # Deduplicate by trade_id
    |> Enum.uniq_by(& &1.trade_id)
    # Re-sort by timestamp (most recent first) for display
    |> Enum.sort_by(& &1.timestamp, :desc)
    |> Enum.take(@max_live_feed_items)
  end

  defp parse_trade_value(nil), do: 0.0

  defp parse_trade_value(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_trade_value(val) when is_number(val), do: val * 1.0
  defp parse_trade_value(_), do: 0.0

  # Parse timestamp - Activity API returns Unix timestamp in seconds
  defp parse_timestamp(nil), do: nil
  defp parse_timestamp(ts) when is_integer(ts), do: ts

  defp parse_timestamp(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_timestamp(_), do: nil

  # Filter live feed by address
  defp filter_feed(feed, nil), do: feed
  defp filter_feed(feed, address), do: Enum.filter(feed, &(&1.address == address))

  # Create a fingerprint of trades for change detection
  # Uses id + size + usdcSize to detect content changes
  defp trades_fingerprint(trades) when is_list(trades) do
    trades
    |> Enum.map(fn t -> {t["id"], t["size"], t["usdcSize"]} end)
    |> Enum.sort()
    |> :erlang.phash2()
  end

  defp trades_fingerprint(_), do: nil

  # Get label for filtered user
  defp get_filter_label(tracked_users, address) do
    case Enum.find(tracked_users, &(&1.address == address)) do
      nil -> short_address(address)
      user -> user.label
    end
  end
end
