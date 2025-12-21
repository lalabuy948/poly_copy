defmodule Polyx.Polymarket.Client.RetryHandler do
  @moduledoc """
  Generic retry handler for CLOB API requests.
  Handles rate limiting (429) and server errors (5xx) with exponential backoff.
  """

  require Logger

  alias Polyx.Polymarket.Client.APIError

  @max_retries 3

  @doc """
  Execute an HTTP request with retry logic for authenticated endpoints.
  """
  def with_retry(request_fn, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, @max_retries)
    api_name = Keyword.get(opts, :api_name, "API")
    path = Keyword.get(opts, :path, "/unknown")

    do_with_retry(request_fn, max_retries, api_name, path)
  end

  defp do_with_retry(request_fn, retries_left, api_name, path) do
    case request_fn.() do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 429, body: _body}} when retries_left > 0 ->
        wait_ms = 2000 * (@max_retries - retries_left + 1)

        Logger.warning(
          "#{api_name} rate limited on #{path}, waiting #{wait_ms}ms (#{retries_left} retries left)"
        )

        Process.sleep(wait_ms)
        do_with_retry(request_fn, retries_left - 1, api_name, path)

      {:ok, %Req.Response{status: status}} when status >= 500 and retries_left > 0 ->
        Logger.warning("#{api_name} server error #{status}, retrying (#{retries_left} left)")
        Process.sleep(1000)
        do_with_retry(request_fn, retries_left - 1, api_name, path)

      {:ok, %Req.Response{status: status, body: body}} ->
        error = build_api_error(api_name, path, status, body)
        Logger.warning("#{api_name} error: #{error.message}")
        {:error, error}

      {:error, %Req.TransportError{reason: reason}} when retries_left > 0 ->
        attempt = @max_retries - retries_left + 1
        # Exponential-ish backoff to avoid hammering on flaky network/API timeouts
        wait_ms = min(5_000, 500 * attempt * attempt)

        Logger.warning(
          "#{api_name} transport error: #{inspect(reason)}, retrying in #{wait_ms}ms (#{retries_left} left)"
        )

        Process.sleep(wait_ms)
        do_with_retry(request_fn, retries_left - 1, api_name, path)

      {:error, reason} ->
        error = build_api_error(api_name, path, nil, reason)
        Logger.error("#{api_name} request failed: #{inspect(reason)}")
        {:error, error}
    end
  end

  # Build structured API error
  defp build_api_error(api_name, endpoint, status, reason) do
    retryable = status in [429, 500, 502, 503, 504] or is_nil(status)

    message =
      case reason do
        %{"error" => msg} -> "#{api_name} #{endpoint}: #{msg}"
        msg when is_binary(msg) -> "#{api_name} #{endpoint}: #{msg}"
        _ -> "#{api_name} #{endpoint}: HTTP #{status || "error"} - #{inspect(reason)}"
      end

    %APIError{
      message: message,
      status: status,
      endpoint: endpoint,
      reason: reason,
      retryable: retryable
    }
  end
end
