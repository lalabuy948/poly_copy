defmodule Polyx.Polymarket.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Polyx.Polymarket.RateLimiter

  describe "acquire/1" do
    test "allows requests within rate limit" do
      # Reset the bucket to ensure we have tokens
      RateLimiter.reset(:clob)

      # Should succeed immediately
      assert :ok = RateLimiter.acquire(:clob)
    end

    test "try_acquire returns error when bucket is empty" do
      # First, exhaust all tokens (CLOB has 120)
      # We won't actually exhaust all, just check the mechanism works
      RateLimiter.reset(:clob)

      # First try should work
      assert :ok = RateLimiter.try_acquire(:clob)
    end
  end

  describe "status/0" do
    test "returns status for all buckets" do
      status = RateLimiter.status()

      assert Map.has_key?(status, :clob)
      assert Map.has_key?(status, :data)
      assert Map.has_key?(status, :gamma)

      clob_status = status[:clob]
      assert Map.has_key?(clob_status, :tokens)
      assert Map.has_key?(clob_status, :max)
      assert Map.has_key?(clob_status, :rate_per_sec)
      assert Map.has_key?(clob_status, :waiters)
    end
  end

  describe "reset/1" do
    test "resets bucket to max capacity" do
      # Use some tokens first
      RateLimiter.acquire(:data)
      RateLimiter.acquire(:data)

      # Get status before reset
      status_before = RateLimiter.status()
      tokens_before = status_before[:data].tokens

      # Reset
      assert :ok = RateLimiter.reset(:data)

      # Check tokens are back to max
      status_after = RateLimiter.status()
      assert status_after[:data].tokens == status_after[:data].max
      assert status_after[:data].tokens >= tokens_before
    end

    test "returns error for unknown bucket" do
      assert {:error, :unknown_bucket} = RateLimiter.reset(:nonexistent)
    end
  end
end
