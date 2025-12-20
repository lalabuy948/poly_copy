defmodule Polyx.Polymarket.Client.Pagination do
  @moduledoc """
  Pagination utilities for Data API endpoints.
  Handles fetching all pages of paginated data.
  """

  require Logger

  @doc """
  Fetch all pages of a paginated endpoint.
  Stops when receiving a partial page (fewer items than page_size).

  Options:
    - :on_progress - Callback fn(fetched_count) for progress updates
  """
  def fetch_all_paginated(get_page_fn, page_size, opts \\ []) do
    on_progress = Keyword.get(opts, :on_progress)
    do_fetch_all_paginated(get_page_fn, page_size, 0, [], on_progress)
  end

  @doc """
  Fetch activities using concurrent requests for large profiles.
  Uses a smart probe to avoid unnecessary concurrent requests for small profiles.

  Options:
    - :max_activities - Maximum number of activities to fetch
    - :on_progress - Callback fn(batch_info) for progress updates
  """
  def fetch_activities_concurrent(get_page_fn, max_activities, opts \\ []) do
    on_progress = Keyword.get(opts, :on_progress)
    page_size = 500

    # For small limits, use non-blocking single request
    if max_activities <= page_size do
      case get_page_fn.(page_size, 0, :nowait) do
        {:ok, activities} when is_list(activities) ->
          if on_progress do
            on_progress.(%{batch: 1, total_batches: 1, activities: length(activities)})
          end

          {:ok, activities}

        {:error, reason} ->
          {:error, reason}
      end
    else
      fetch_activities_large(get_page_fn, max_activities, page_size, on_progress)
    end
  end

  # Private functions

  defp do_fetch_all_paginated(get_page_fn, page_size, offset, acc, on_progress) do
    page_start = System.monotonic_time(:millisecond)

    case get_page_fn.(page_size, offset) do
      {:ok, items} when is_list(items) and length(items) == page_size ->
        # Full page - there might be more
        page_elapsed = System.monotonic_time(:millisecond) - page_start

        Logger.debug(
          "[Pagination] Page at offset=#{offset}: #{length(items)} items in #{page_elapsed}ms"
        )

        if on_progress, do: on_progress.(length(acc) + length(items))

        do_fetch_all_paginated(
          get_page_fn,
          page_size,
          offset + page_size,
          acc ++ items,
          on_progress
        )

      {:ok, items} when is_list(items) and length(items) > 0 ->
        # Partial page - this is the last page
        page_elapsed = System.monotonic_time(:millisecond) - page_start
        total = acc ++ items

        Logger.debug(
          "[Pagination] Done: #{length(total)} items (last page: #{length(items)}) in #{page_elapsed}ms"
        )

        if on_progress, do: on_progress.(length(total))
        {:ok, total}

      {:ok, items} when is_list(items) ->
        # Empty page - we're done
        page_elapsed = System.monotonic_time(:millisecond) - page_start

        Logger.debug("[Pagination] Done: #{length(acc)} items (empty page) in #{page_elapsed}ms")

        if on_progress, do: on_progress.(length(acc))
        {:ok, acc}

      {:error, reason} when acc == [] ->
        Logger.warning("[Pagination] Failed at offset=#{offset}: #{inspect(reason)}")
        {:error, reason}

      {:error, reason} ->
        Logger.warning(
          "[Pagination] Error at offset=#{offset}: #{inspect(reason)}, returning #{length(acc)} items"
        )

        # Return what we have so far if we hit an error mid-pagination
        {:ok, acc}
    end
  end

  defp fetch_activities_large(get_page_fn, max_activities, page_size, on_progress) do
    max_pages = max(1, div(max_activities, page_size))

    Logger.debug(
      "[Pagination] Starting activity fetch, max_pages=#{max_pages}, page_size=#{page_size}"
    )

    # Smart probe: fetch first page to determine if we need concurrent fetching
    probe_start = System.monotonic_time(:millisecond)

    case get_page_fn.(page_size, 0, :blocking) do
      {:ok, first_page} when is_list(first_page) ->
        probe_elapsed = System.monotonic_time(:millisecond) - probe_start
        count = length(first_page)
        Logger.info("[Pagination] Activity probe: #{count} items in #{probe_elapsed}ms")

        cond do
          count == 0 ->
            {:ok, []}

          count < page_size ->
            # Small profile - we already have all activities
            if on_progress do
              on_progress.(%{batch: 1, total_batches: 1, activities: count})
            end

            {:ok, first_page}

          true ->
            # Large profile - need to fetch more pages concurrently
            total_batches = max(1, ceil((max_pages - 1) / 10))

            if on_progress do
              on_progress.(%{batch: 0, total_batches: total_batches, activities: count})
            end

            fetch_remaining_pages(get_page_fn, max_pages, page_size, first_page, on_progress)
        end

      {:error, reason} ->
        probe_elapsed = System.monotonic_time(:millisecond) - probe_start

        Logger.warning(
          "[Pagination] Activity probe failed in #{probe_elapsed}ms: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp fetch_remaining_pages(get_page_fn, max_pages, page_size, first_page, on_progress) do
    Logger.debug("[Pagination] Fetching remaining pages (already have page 0)")
    batch_size = 10
    max_retries = 3
    total_batches = max(1, ceil((max_pages - 1) / batch_size))

    result =
      1..(max_pages - 1)
      |> Enum.chunk_every(batch_size)
      |> Enum.reduce_while({:ok, first_page, 0}, fn page_batch, {:ok, acc, batch_num} ->
        batch_start = System.monotonic_time(:millisecond)
        Logger.debug("[Pagination] Fetching batch #{batch_num + 1}, pages #{inspect(page_batch)}")

        results =
          page_batch
          |> Task.async_stream(
            fn page_num ->
              offset = page_num * page_size
              fetch_page_with_retry(get_page_fn, page_size, offset, max_retries)
            end,
            max_concurrency: batch_size,
            timeout: :infinity
          )
          |> Enum.map(fn
            {:ok, result} -> result
            {:exit, reason} -> {:error, {:task_exit, reason}}
          end)

        {activities, should_stop, _failed_pages} =
          results
          |> Enum.with_index()
          |> Enum.reduce({[], false, []}, fn {result, idx}, {acts, stop, failed} ->
            page_num = Enum.at(page_batch, idx)

            case result do
              {:ok, page_activities} when is_list(page_activities) ->
                if length(page_activities) < page_size do
                  {acts ++ page_activities, true, failed}
                else
                  {acts ++ page_activities, stop, failed}
                end

              {:ok, _} ->
                {acts, true, failed}

              {:error, reason} ->
                Logger.warning(
                  "Failed to fetch page #{page_num} after retries: #{inspect(reason)}"
                )

                {acts, stop, [page_num | failed]}
            end
          end)

        batch_elapsed = System.monotonic_time(:millisecond) - batch_start
        new_acc = acc ++ activities

        Logger.debug(
          "[Pagination] Batch #{batch_num + 1} completed in #{batch_elapsed}ms, " <>
            "fetched #{length(activities)} activities, total=#{length(new_acc)}"
        )

        if on_progress do
          on_progress.(%{
            batch: batch_num + 1,
            total_batches: total_batches,
            activities: length(new_acc)
          })
        end

        if should_stop do
          {:halt, {:ok, new_acc}}
        else
          {:cont, {:ok, new_acc, batch_num + 1}}
        end
      end)

    case result do
      {:ok, activities} -> {:ok, activities}
      {:ok, activities, _batch_num} -> {:ok, activities}
    end
  end

  defp fetch_page_with_retry(get_page_fn, page_size, offset, retries_left, delay \\ 1000)

  defp fetch_page_with_retry(_get_page_fn, _page_size, _offset, 0, _delay) do
    {:error, :max_retries_exceeded}
  end

  defp fetch_page_with_retry(get_page_fn, page_size, offset, retries_left, delay) do
    case get_page_fn.(page_size, offset, :blocking) do
      {:ok, _} = success ->
        success

      {:error, {429, _}} ->
        Logger.debug("Rate limited fetching page at offset #{offset}, retrying in #{delay * 2}ms")

        Process.sleep(delay * 2)
        fetch_page_with_retry(get_page_fn, page_size, offset, retries_left - 1, delay * 2)

      {:error, {status, _}} when status >= 500 ->
        Logger.debug(
          "Server error #{status} fetching page at offset #{offset}, retrying in #{delay}ms"
        )

        Process.sleep(delay)
        fetch_page_with_retry(get_page_fn, page_size, offset, retries_left - 1, delay * 2)

      {:error, _} = error ->
        error
    end
  end
end
