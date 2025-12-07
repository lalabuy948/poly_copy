defmodule Polyx.Polymarket.GammaCache do
  @moduledoc """
  GenServer that owns the ETS cache table for Gamma market lookups.
  This ensures the table persists across code reloads during development.
  """
  use GenServer

  @cache_table :gamma_token_cache

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

    {:ok, %{}}
  end
end
