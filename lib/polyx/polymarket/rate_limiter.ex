defmodule Polyx.Polymarket.RateLimiter do
  @moduledoc """
  Token bucket rate limiter for Polymarket API calls.

  Implements rate limiting based on Polymarket's documented limits:
  - CLOB API: 120 requests/minute (2 per second)
  - Data API: 60 requests/minute (1 per second)

  Uses a token bucket algorithm with automatic refill.
  """
  use GenServer

  require Logger

  # Rate limits per bucket (requests per minute)
  @clob_limit 120
  @data_limit 60
  @gamma_limit 60

  # Refill interval in milliseconds
  @refill_interval 1_000

  defstruct buckets: %{},
            waiters: %{}

  # Public API

  @doc """
  Start the rate limiter.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Acquire a token for the given bucket. Blocks until a token is available.
  Returns :ok when the request can proceed.

  Buckets:
  - :clob - CLOB API requests (120/min)
  - :data - Data API requests (60/min)
  - :gamma - Gamma API requests (60/min)
  """
  def acquire(bucket, timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:acquire, bucket}, timeout)
  end

  @doc """
  Try to acquire a token without blocking.
  Returns :ok if available, {:error, :rate_limited} if not.
  """
  def try_acquire(bucket) do
    GenServer.call(__MODULE__, {:try_acquire, bucket})
  end

  @doc """
  Get current bucket status for monitoring.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Reset a bucket (useful for testing or after long pauses).
  """
  def reset(bucket) do
    GenServer.call(__MODULE__, {:reset, bucket})
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Initialize buckets with full capacity
    buckets = %{
      clob: %{tokens: @clob_limit, max: @clob_limit, rate: @clob_limit / 60},
      data: %{tokens: @data_limit, max: @data_limit, rate: @data_limit / 60},
      gamma: %{tokens: @gamma_limit, max: @gamma_limit, rate: @gamma_limit / 60}
    }

    # Schedule periodic refill
    :timer.send_interval(@refill_interval, :refill)

    {:ok, %__MODULE__{buckets: buckets, waiters: %{}}}
  end

  @impl true
  def handle_call({:acquire, bucket}, from, state) do
    case try_take_token(state, bucket) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:empty, state} ->
        # Add to waiters queue
        waiters =
          Map.update(state.waiters, bucket, :queue.from_list([from]), &:queue.in(from, &1))

        {:noreply, %{state | waiters: waiters}}
    end
  end

  @impl true
  def handle_call({:try_acquire, bucket}, _from, state) do
    case try_take_token(state, bucket) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:empty, state} ->
        {:reply, {:error, :rate_limited}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status =
      Map.new(state.buckets, fn {name, bucket} ->
        waiter_count =
          case Map.get(state.waiters, name) do
            nil -> 0
            queue -> :queue.len(queue)
          end

        {name,
         %{
           tokens: bucket.tokens,
           max: bucket.max,
           rate_per_sec: bucket.rate,
           waiters: waiter_count
         }}
      end)

    {:reply, status, state}
  end

  @impl true
  def handle_call({:reset, bucket}, _from, state) do
    case Map.get(state.buckets, bucket) do
      nil ->
        {:reply, {:error, :unknown_bucket}, state}

      bucket_state ->
        new_buckets = Map.put(state.buckets, bucket, %{bucket_state | tokens: bucket_state.max})
        {:reply, :ok, %{state | buckets: new_buckets}}
    end
  end

  @impl true
  def handle_info(:refill, state) do
    # Refill all buckets
    new_buckets =
      Map.new(state.buckets, fn {name, bucket} ->
        new_tokens = min(bucket.tokens + bucket.rate, bucket.max)
        {name, %{bucket | tokens: new_tokens}}
      end)

    # Process any waiters that can now proceed
    {new_buckets, new_waiters} = process_waiters(%{state | buckets: new_buckets})

    {:noreply, %{state | buckets: new_buckets, waiters: new_waiters}}
  end

  # Private functions

  defp try_take_token(state, bucket) do
    case Map.get(state.buckets, bucket) do
      nil ->
        Logger.warning("Unknown rate limit bucket: #{bucket}, allowing request")
        {:ok, state}

      %{tokens: tokens} when tokens >= 1 ->
        new_buckets = Map.update!(state.buckets, bucket, &%{&1 | tokens: &1.tokens - 1})
        {:ok, %{state | buckets: new_buckets}}

      _ ->
        {:empty, state}
    end
  end

  defp process_waiters(state) do
    Enum.reduce(state.waiters, {state.buckets, %{}}, fn {bucket, queue}, {buckets, waiters} ->
      process_bucket_waiters(bucket, queue, buckets, waiters)
    end)
  end

  defp process_bucket_waiters(bucket, queue, buckets, waiters) do
    case :queue.out(queue) do
      {:empty, _} ->
        {buckets, waiters}

      {{:value, from}, rest} ->
        case Map.get(buckets, bucket) do
          %{tokens: tokens} when tokens >= 1 ->
            # Grant token to waiter
            GenServer.reply(from, :ok)
            new_buckets = Map.update!(buckets, bucket, &%{&1 | tokens: &1.tokens - 1})
            # Continue processing
            process_bucket_waiters(bucket, rest, new_buckets, waiters)

          _ ->
            # No more tokens, keep remaining waiters
            {buckets, Map.put(waiters, bucket, queue)}
        end
    end
  end
end
