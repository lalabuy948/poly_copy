defmodule Polyx.Polymarket.GammaCache do
  @moduledoc """
  GenServer that owns the ETS cache table for Gamma market lookups.
  This ensures the table persists across code reloads during development.
  Includes periodic cleanup of expired entries to prevent memory leaks.
  """
  use GenServer

  require Logger

  @cache_table :gamma_token_cache
  # Clean up expired entries every 5 minutes
  @cleanup_interval :timer.minutes(5)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def table_name, do: @cache_table

  def lookup(key) do
    try do
      :ets.lookup(@cache_table, key)
    rescue
      ArgumentError -> []
    catch
      :error, :badarg -> []
    end
  end

  def insert(key, value, expires_at) do
    try do
      :ets.insert(@cache_table, {key, value, expires_at})
      :ok
    rescue
      ArgumentError -> :ok
    catch
      :error, :badarg -> :ok
    end
  end

  @doc """
  Manually trigger cleanup of expired entries.
  """
  def cleanup_expired do
    GenServer.cast(__MODULE__, :cleanup)
  end

  @impl true
  def init(_) do
    # Create the ETS table owned by this GenServer
    # If it already exists (from a previous instance), that's fine
    try do
      :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])
    rescue
      ArgumentError -> :ok
    catch
      :error, :badarg -> :ok
    end

    # Schedule first cleanup
    Process.send_after(self(), :cleanup, @cleanup_interval)

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    do_cleanup()
    # Schedule next cleanup
    Process.send_after(self(), :cleanup, @cleanup_interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:cleanup, state) do
    do_cleanup()
    {:noreply, state}
  end

  defp do_cleanup do
    now = System.system_time(:second)

    # Get all entries and filter expired ones
    expired =
      try do
        :ets.tab2list(@cache_table)
        |> Enum.filter(fn {_key, _value, expires_at} -> expires_at < now end)
        |> Enum.map(fn {key, _, _} -> key end)
      rescue
        ArgumentError -> []
      catch
        :error, :badarg -> []
      end

    # Delete expired entries
    Enum.each(expired, fn key ->
      try do
        :ets.delete(@cache_table, key)
      rescue
        ArgumentError -> :ok
      catch
        :error, :badarg -> :ok
      end
    end)

    if expired != [] do
      remaining = :ets.info(@cache_table, :size) || 0
      Logger.debug("[GammaCache] Cleaned #{length(expired)} expired entries, #{remaining} remaining")
    end
  end
end
