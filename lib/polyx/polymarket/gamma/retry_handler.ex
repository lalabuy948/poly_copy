defmodule Polyx.Polymarket.Gamma.RetryHandler do
  @moduledoc """
  Generic retry handler for Gamma API requests.
  Handles rate limiting (429) and server errors (5xx) with exponential backoff.
  """

  require Logger

  @max_retries 3

  @doc """
  Execute a request function with retry logic.

  The request_fn should return:
  - {:ok, result} on success
  - {:error, reason} on failure
  - {:retry, reason} to force a retry
  - {:rate_limited} for 429 responses
  - {:server_error, status} for 5xx responses
  """
  def with_retry(request_fn, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, @max_retries)
    context = Keyword.get(opts, :context, "Request")
    do_with_retry(request_fn, max_retries, context)
  end

  defp do_with_retry(request_fn, retries_left, context) do
    case request_fn.() do
      {:ok, _} = success ->
        success

      {:rate_limited, wait_ms} when retries_left > 0 ->
        wait_time = wait_ms || calculate_backoff(:rate_limit, retries_left)
        Logger.warning("[Gamma] Rate limited on #{context}, waiting #{wait_time}ms")
        Process.sleep(wait_time)
        do_with_retry(request_fn, retries_left - 1, context)

      {:server_error, status} when retries_left > 0 ->
        Logger.warning("[Gamma] Server error #{status} on #{context}, retrying")
        Process.sleep(1000)
        do_with_retry(request_fn, retries_left - 1, context)

      {:retry, reason} when retries_left > 0 ->
        Logger.warning("[Gamma] #{context} failed, retrying: #{inspect(reason)}")
        Process.sleep(500)
        do_with_retry(request_fn, retries_left - 1, context)

      {:error, _} = error ->
        error

      {:rate_limited, _} ->
        {:error, :rate_limit_exceeded}

      {:server_error, status} ->
        {:error, "Server error #{status}"}

      {:retry, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Calculate exponential backoff time for rate limiting.
  """
  def calculate_backoff(:rate_limit, retries_left) do
    2000 * (@max_retries - retries_left + 1)
  end

  def calculate_backoff(:server_error, _retries_left) do
    1000
  end

  def calculate_backoff(:generic, _retries_left) do
    500
  end

  @doc """
  Handle HTTP response and convert to retry-compatible format.
  """
  def handle_response(response, success_fn) do
    case response do
      {:ok, %{status: 200, body: body}} ->
        success_fn.(body)

      {:ok, %{status: 429}} ->
        {:rate_limited, nil}

      {:ok, %{status: status}} when status >= 500 ->
        {:server_error, status}

      {:ok, %{status: status, body: body}} ->
        {:error, "API returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:retry, reason}
    end
  end
end
