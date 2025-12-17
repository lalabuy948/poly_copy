defmodule Polyx.Polymarket.GammaCache do
  @moduledoc """
  GenServer that caches Gamma market lookups in GenServer state.
  Includes periodic cleanup of expired entries to prevent memory leaks.
  """
  use GenServer

  require Logger

  # Clean up expired entries every 5 minutes
  @cleanup_interval :timer.minutes(5)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def lookup(key) do
    GenServer.call(__MODULE__, {:lookup, key})
  end

  def insert(key, value, expires_at) do
    GenServer.cast(__MODULE__, {:insert, key, value, expires_at})
    :ok
  end

  @doc """
  Manually trigger cleanup of expired entries.
  """
  def cleanup_expired do
    GenServer.cast(__MODULE__, :cleanup)
  end

  @impl true
  def init(_) do
    # Schedule first cleanup
    Process.send_after(self(), :cleanup, @cleanup_interval)

    {:ok, %{cache: %{}}}
  end

  @impl true
  def handle_call({:lookup, key}, _from, state) do
    now = System.system_time(:second)

    result =
      case Map.get(state.cache, key) do
        {value, expires_at} when expires_at > now ->
          [{key, value, expires_at}]

        _ ->
          []
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:insert, key, value, expires_at}, state) do
    new_cache = Map.put(state.cache, key, {value, expires_at})
    {:noreply, %{state | cache: new_cache}}
  end

  @impl true
  def handle_cast(:cleanup, state) do
    new_state = do_cleanup(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    new_state = do_cleanup(state)
    # Schedule next cleanup
    Process.send_after(self(), :cleanup, @cleanup_interval)
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp do_cleanup(state) do
    now = System.system_time(:second)

    {expired_keys, valid_cache} =
      Enum.reduce(state.cache, {[], %{}}, fn {key, {value, expires_at}}, {expired, valid} ->
        if expires_at < now do
          {[key | expired], valid}
        else
          {expired, Map.put(valid, key, {value, expires_at})}
        end
      end)

    if expired_keys != [] do
      Logger.debug(
        "[GammaCache] Cleaned #{length(expired_keys)} expired entries, #{map_size(valid_cache)} remaining"
      )
    end

    %{state | cache: valid_cache}
  end
end
