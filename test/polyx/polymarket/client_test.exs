defmodule Polyx.Polymarket.ClientTest do
  use ExUnit.Case, async: true

  alias Polyx.Polymarket.Client.APIError

  describe "APIError" do
    test "creates error with all fields" do
      error = %APIError{
        message: "CLOB /test: Something went wrong",
        status: 500,
        endpoint: "/test",
        reason: "internal error",
        retryable: true
      }

      assert error.message == "CLOB /test: Something went wrong"
      assert error.status == 500
      assert error.endpoint == "/test"
      assert error.retryable == true
    end

    test "implements Exception behavior" do
      error = %APIError{
        message: "Test error",
        status: 400,
        endpoint: "/test",
        reason: "bad request",
        retryable: false
      }

      assert Exception.message(error) == "Test error"
    end
  end
end
