defmodule Polyx.CopyTrading.TradeWatcher do
  @moduledoc """
  GenServer that watches for new trades from tracked users.
  Polls the Polymarket API periodically and broadcasts new trades.
  Persists tracked users to the database.
  """

  use GenServer
  require Logger

  alias Polyx.Repo
  alias Polyx.Polymarket.Client
  alias Polyx.CopyTrading
  alias Polyx.CopyTrading.TrackedUser

  import Ecto.Query

  # Polymarket Data API rate limit: 200 requests / 10 seconds
  # We use 50% of capacity to leave headroom for other operations
  # With 100 req/10s budget and 3s interval, we can track up to 33 users comfortably
  @base_poll_interval :timer.seconds(1)
  @max_requests_per_10s 200

  defstruct tracked_users: %{},
            last_trade_ids: %{},
            poll_ref: nil

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def track_user(address, opts \\ []) do
    GenServer.call(__MODULE__, {:track_user, address, opts})
  end

  def untrack_user(address) do
    GenServer.call(__MODULE__, {:untrack_user, address})
  end

  def list_tracked_users do
    GenServer.call(__MODULE__, :list_tracked_users)
  end

  def list_archived_users do
    # Query directly from database since archived users aren't in GenServer state
    Repo.all(from u in TrackedUser, where: u.active == false, order_by: [desc: u.updated_at])
    |> Enum.map(fn u ->
      %{
        id: u.id,
        address: u.address,
        label: u.label,
        archived_at: u.updated_at
      }
    end)
  end

  def restore_user(address) do
    GenServer.call(__MODULE__, {:restore_user, address})
  end

  def update_user_label(address, label) do
    GenServer.call(__MODULE__, {:update_user_label, address, label})
  end

  def delete_user(address) do
    GenServer.call(__MODULE__, {:delete_user, address})
  end

  def get_user_trades(address) do
    GenServer.call(__MODULE__, {:get_user_trades, address})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Load tracked users from database on startup
    send(self(), :load_from_database)
    state = %__MODULE__{}
    {:ok, schedule_poll(state)}
  end

  @impl true
  def handle_call({:track_user, address, opts}, _from, state) do
    address = normalize_address(address)
    label = Keyword.get(opts, :label)
    label = if label && label != "", do: label, else: short_address(address)

    # Save to database
    case save_tracked_user(address, label) do
      {:ok, db_user} ->
        user_info = %{
          id: db_user.id,
          address: db_user.address,
          label: db_user.label,
          trades: [],
          added_at: db_user.inserted_at
        }

        new_state = %{
          state
          | tracked_users: Map.put(state.tracked_users, address, user_info),
            last_trade_ids: Map.put(state.last_trade_ids, address, MapSet.new())
        }

        Logger.info("Now tracking user: #{label} (#{address})")
        CopyTrading.broadcast(:user_tracked, user_info)

        # Fetch initial trades
        send(self(), {:fetch_trades, address})

        {:reply, {:ok, user_info}, new_state}

      {:error, changeset} ->
        Logger.warning("Failed to save tracked user: #{inspect(changeset.errors)}")
        {:reply, {:error, changeset.errors}, state}
    end
  end

  @impl true
  def handle_call({:untrack_user, address}, _from, state) do
    address = normalize_address(address)

    case Map.get(state.tracked_users, address) do
      nil ->
        {:reply, {:error, :not_found}, state}

      user_info ->
        # Remove from database
        delete_tracked_user(address)

        new_state = %{
          state
          | tracked_users: Map.delete(state.tracked_users, address),
            last_trade_ids: Map.delete(state.last_trade_ids, address)
        }

        Logger.info("Stopped tracking user: #{user_info.label}")
        CopyTrading.broadcast(:user_untracked, user_info)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:list_tracked_users, _from, state) do
    users = Map.values(state.tracked_users)
    {:reply, users, state}
  end

  @impl true
  def handle_call({:restore_user, address}, _from, state) do
    address = normalize_address(address)

    # Restore in database
    case Repo.get_by(TrackedUser, address: address) do
      nil ->
        {:reply, {:error, :not_found}, state}

      db_user ->
        case db_user |> TrackedUser.changeset(%{active: true}) |> Repo.update() do
          {:ok, updated_user} ->
            user_info = %{
              id: updated_user.id,
              address: updated_user.address,
              label: updated_user.label,
              trades: [],
              added_at: updated_user.inserted_at
            }

            new_state = %{
              state
              | tracked_users: Map.put(state.tracked_users, address, user_info),
                last_trade_ids: Map.put(state.last_trade_ids, address, MapSet.new())
            }

            Logger.info("Restored user: #{user_info.label} (#{address})")
            CopyTrading.broadcast(:user_tracked, user_info)

            # Fetch initial trades
            send(self(), {:fetch_trades, address})

            {:reply, {:ok, user_info}, new_state}

          {:error, changeset} ->
            {:reply, {:error, changeset.errors}, state}
        end
    end
  end

  @impl true
  def handle_call({:get_user_trades, address}, _from, state) do
    address = normalize_address(address)

    case Map.get(state.tracked_users, address) do
      nil -> {:reply, {:error, :not_found}, state}
      user_info -> {:reply, {:ok, user_info.trades}, state}
    end
  end

  @impl true
  def handle_call({:update_user_label, address, label}, _from, state) do
    address = normalize_address(address)
    label = if label && label != "", do: String.trim(label), else: short_address(address)

    case Map.get(state.tracked_users, address) do
      nil ->
        {:reply, {:error, :not_found}, state}

      user_info ->
        # Update in database
        case Repo.get_by(TrackedUser, address: address) do
          nil ->
            {:reply, {:error, :not_found}, state}

          db_user ->
            case db_user |> TrackedUser.changeset(%{label: label}) |> Repo.update() do
              {:ok, _updated} ->
                # Update in-memory state
                updated_user = %{user_info | label: label}

                new_state = %{
                  state
                  | tracked_users: Map.put(state.tracked_users, address, updated_user)
                }

                Logger.info("Updated label for #{address} to: #{label}")
                CopyTrading.broadcast(:user_label_updated, updated_user)

                {:reply, {:ok, updated_user}, new_state}

              {:error, changeset} ->
                {:reply, {:error, changeset.errors}, state}
            end
        end
    end
  end

  @impl true
  def handle_call({:delete_user, address}, _from, state) do
    address = normalize_address(address)

    # Only allow deleting archived (inactive) users
    case Repo.get_by(TrackedUser, address: address, active: false) do
      nil ->
        {:reply, {:error, :not_found}, state}

      db_user ->
        case Repo.delete(db_user) do
          {:ok, deleted_user} ->
            user_info = %{
              id: deleted_user.id,
              address: deleted_user.address,
              label: deleted_user.label
            }

            Logger.info("Permanently deleted user: #{deleted_user.label} (#{address})")
            CopyTrading.broadcast(:user_deleted, user_info)

            {:reply, {:ok, user_info}, state}

          {:error, changeset} ->
            {:reply, {:error, changeset.errors}, state}
        end
    end
  end

  @impl true
  def handle_info(:load_from_database, state) do
    db_users = Repo.all(from u in TrackedUser, where: u.active == true)

    new_state =
      Enum.reduce(db_users, state, fn db_user, acc ->
        address = db_user.address

        user_info = %{
          id: db_user.id,
          address: address,
          label: db_user.label,
          trades: [],
          added_at: db_user.inserted_at
        }

        # Fetch trades for this user
        send(self(), {:fetch_trades, address})

        %{
          acc
          | tracked_users: Map.put(acc.tracked_users, address, user_info),
            last_trade_ids: Map.put(acc.last_trade_ids, address, MapSet.new())
        }
      end)

    if map_size(new_state.tracked_users) > 0 do
      Logger.info("Loaded #{map_size(new_state.tracked_users)} tracked users from database")
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:poll, state) do
    # Poll trades for all tracked users
    addresses = Map.keys(state.tracked_users)

    Enum.each(addresses, fn address ->
      send(self(), {:fetch_trades, address})
    end)

    {:noreply, schedule_poll(state)}
  end

  @impl true
  def handle_info({:fetch_trades, address}, state) do
    # Spawn a task to fetch trades asynchronously so GenServer stays responsive
    parent = self()

    Task.start(fn ->
      result = fetch_user_trades(address)
      send(parent, {:trades_fetched, address, result})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:trades_fetched, address, {:ok, trades}}, state) do
    {:noreply, process_trades(state, address, trades)}
  end

  @impl true
  def handle_info({:trades_fetched, address, {:error, reason}}, state) do
    Logger.warning("Failed to fetch trades for #{address}: #{inspect(reason)}")
    {:noreply, state}
  end

  # Private functions

  defp save_tracked_user(address, label) do
    # Try to find existing user first
    case Repo.get_by(TrackedUser, address: address) do
      nil ->
        %TrackedUser{}
        |> TrackedUser.changeset(%{address: address, label: label, active: true})
        |> Repo.insert()

      existing ->
        existing
        |> TrackedUser.changeset(%{active: true, label: label})
        |> Repo.update()
    end
  end

  defp delete_tracked_user(address) do
    case Repo.get_by(TrackedUser, address: address) do
      nil ->
        :ok

      user ->
        user
        |> TrackedUser.changeset(%{active: false})
        |> Repo.update()
    end
  end

  defp schedule_poll(state) do
    if state.poll_ref, do: Process.cancel_timer(state.poll_ref)
    interval = calculate_poll_interval(state)
    ref = Process.send_after(self(), :poll, interval)
    %{state | poll_ref: ref}
  end

  # Calculate poll interval dynamically based on number of tracked users
  # Goal: stay under 100 requests per 10 seconds (50% of API limit)
  defp calculate_poll_interval(state) do
    user_count = map_size(state.tracked_users)

    if user_count == 0 do
      @base_poll_interval
    else
      # Requests per poll = user_count
      # Max polls per 10s = @max_requests_per_10s / user_count
      # Min interval = 10_000ms / max_polls
      min_interval_ms = div(10_000 * user_count, @max_requests_per_10s)
      # Use whichever is larger: base interval or calculated minimum
      max(@base_poll_interval, min_interval_ms)
    end
  end

  defp fetch_user_trades(address) do
    # Fetch activity from Data API (shows actual trades with timestamps)
    # Only fetch recent activity (100 items) for live feed - no need for full history
    case Client.get_activity(address, max_activities: 100) do
      {:ok, activities} when is_list(activities) ->
        # Transform activities into trade format - only include TRADE type
        # Logger.info("Fetched #{length(activities)} activities for #{address}")

        trades =
          activities
          |> Enum.filter(fn act -> act["type"] == "TRADE" end)
          |> Enum.map(fn act ->
            %{
              "id" => act["transactionHash"],
              "title" => act["title"],
              "outcome" => act["outcome"],
              "size" => act["size"],
              "price" => act["price"],
              "avgPrice" => act["price"],
              "side" => act["side"],
              "usdcSize" => act["usdcSize"],
              "market_slug" => act["slug"],
              "event_slug" => act["eventSlug"],
              "asset_id" => act["asset"],
              "icon" => act["icon"],
              "timestamp" => act["timestamp"],
              "transactionHash" => act["transactionHash"]
            }
          end)

        # |> Enum.take(100)

        {:ok, trades}

      {:error, reason} ->
        Logger.error("Failed to fetch trades for #{address}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_trades(state, address, trades) do
    # Check if user is still tracked (might have been untracked during async fetch)
    case Map.get(state.tracked_users, address) do
      nil ->
        # User was untracked while trades were being fetched, ignore
        state

      user_info ->
        known_ids = Map.get(state.last_trade_ids, address, MapSet.new())

        new_trades =
          trades
          |> Enum.reject(fn trade -> MapSet.member?(known_ids, trade["id"]) end)

        if new_trades != [] do
          Logger.info("Found #{length(new_trades)} new trades for #{short_address(address)}")

          # Broadcast new trades for copy execution
          Enum.each(new_trades, fn trade ->
            CopyTrading.broadcast(:new_trade, %{address: address, trade: trade})
          end)
        end

        # Update state
        all_trade_ids =
          trades
          |> Enum.map(& &1["id"])
          |> MapSet.new()

        updated_user = Map.put(user_info, :trades, trades)

        # Broadcast trades updated so LiveView can sync
        CopyTrading.broadcast(:trades_updated, %{address: address, trades: trades})

        %{
          state
          | tracked_users: Map.put(state.tracked_users, address, updated_user),
            last_trade_ids: Map.put(state.last_trade_ids, address, all_trade_ids)
        }
    end
  end

  defp normalize_address(address) do
    address
    |> String.trim()
    |> String.downcase()
  end

  defp short_address(address) do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
  end
end
