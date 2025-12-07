defmodule Polyx.Strategies.Engine do
  @moduledoc """
  Supervisor for strategy runners.

  Manages the lifecycle of running strategies using DynamicSupervisor.
  Provides API to start/stop/restart strategy runners.
  """
  use Supervisor

  require Logger

  alias Polyx.Strategies
  alias Polyx.Strategies.Runner

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: Polyx.Strategies.Registry},
      {DynamicSupervisor, name: Polyx.Strategies.RunnerSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  # Public API

  @doc """
  Start a strategy runner for the given strategy ID.
  """
  def start_strategy(strategy_id) do
    Logger.info("[Engine] start_strategy called for id=#{strategy_id}")

    # Check Registry (actual process state), not DB status
    # DB status can be stale if process crashed or server restarted
    case Registry.lookup(Polyx.Strategies.Registry, strategy_id) do
      [{_pid, _}] ->
        Logger.info("[Engine] Strategy #{strategy_id} already running")
        {:error, :already_running}

      [] ->
        strategy = Strategies.get_strategy!(strategy_id)
        Logger.info("[Engine] Starting strategy #{strategy.name} (type: #{strategy.type})")
        spec = {Runner, strategy_id}

        case DynamicSupervisor.start_child(Polyx.Strategies.RunnerSupervisor, spec) do
          {:ok, pid} ->
            Logger.info("[Engine] Started strategy #{strategy.name} (pid: #{inspect(pid)})")
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            Logger.info("[Engine] Strategy already started with pid #{inspect(pid)}")
            {:error, {:already_running, pid}}

          {:error, reason} ->
            Logger.error("[Engine] Failed to start strategy: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  @doc """
  Stop a running strategy.
  """
  def stop_strategy(strategy_id) do
    case Registry.lookup(Polyx.Strategies.Registry, strategy_id) do
      [{pid, _}] ->
        Logger.info("[Engine] Stopping strategy #{strategy_id}")
        DynamicSupervisor.terminate_child(Polyx.Strategies.RunnerSupervisor, pid)

      [] ->
        {:error, :not_running}
    end
  end

  @doc """
  Restart a strategy (stop then start).
  """
  def restart_strategy(strategy_id) do
    stop_strategy(strategy_id)
    # Small delay to ensure clean shutdown
    Process.sleep(100)
    start_strategy(strategy_id)
  end

  @doc """
  Pause a running strategy (keeps process alive but stops processing).
  """
  def pause_strategy(strategy_id) do
    Logger.info("[Engine] pause_strategy called for id=#{strategy_id}")

    case Registry.lookup(Polyx.Strategies.Registry, strategy_id) do
      [{_pid, _}] ->
        Runner.pause(strategy_id)

      [] ->
        Logger.warning("[Engine] Cannot pause - strategy #{strategy_id} not running")
        {:error, :not_running}
    end
  end

  @doc """
  Resume a paused strategy.
  If the process isn't running (e.g., server restarted), starts it instead.
  """
  def resume_strategy(strategy_id) do
    Logger.info("[Engine] resume_strategy called for id=#{strategy_id}")

    case Registry.lookup(Polyx.Strategies.Registry, strategy_id) do
      [{_pid, _}] ->
        Runner.resume(strategy_id)

      [] ->
        # Process not running - start it fresh
        # This handles the case where server restarted while strategy was paused
        Logger.info("[Engine] Process not running, starting fresh")
        start_strategy(strategy_id)
    end
  end

  @doc """
  Check if a strategy is running.
  """
  def running?(strategy_id) do
    case Registry.lookup(Polyx.Strategies.Registry, strategy_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  @doc """
  Get the PID of a running strategy.
  """
  def get_runner_pid(strategy_id) do
    case Registry.lookup(Polyx.Strategies.Registry, strategy_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_running}
    end
  end

  @doc """
  List all running strategy IDs.
  """
  def list_running do
    Registry.select(Polyx.Strategies.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Stop all running strategies.
  """
  def stop_all do
    list_running()
    |> Enum.each(&stop_strategy/1)
  end

  @doc """
  Auto-start strategies that were running before shutdown.
  Call this during application startup if desired.
  """
  def auto_start_strategies do
    Strategies.list_strategies_by_status("running")
    |> Enum.each(fn strategy ->
      # Reset to stopped first, then start
      Strategies.update_strategy_status(strategy, "stopped")
      start_strategy(strategy.id)
    end)
  end
end
