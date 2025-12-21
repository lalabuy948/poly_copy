defmodule Polyx.Polymarket.Client.RequestBuilder do
  @moduledoc """
  Request builder utilities for Polymarket CLOB API.
  Handles URL construction and default headers.
  """

  @doc """
  Build CLOB API URL with query parameters.
  """
  def build_url(path, params, config) do
    base = config[:clob_url] || "https://clob.polymarket.com"
    query = URI.encode_query(params)

    if query == "" do
      "#{base}#{path}"
    else
      "#{base}#{path}?#{query}"
    end
  end

  @doc """
  Build Data API URL with query parameters.
  """
  def build_data_api_url(path, params) do
    base = "https://data-api.polymarket.com"
    query = URI.encode_query(params)

    if query == "" do
      "#{base}#{path}"
    else
      "#{base}#{path}?#{query}"
    end
  end

  @doc """
  Get default headers for requests.
  """
  def default_headers do
    [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"user-agent", "py_clob_client"}
    ]
  end
end
