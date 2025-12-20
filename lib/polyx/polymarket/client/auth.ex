defmodule Polyx.Polymarket.Client.Auth do
  @moduledoc """
  Authentication for Polymarket CLOB API.
  Handles L2 HMAC signature generation for authenticated requests.
  """

  require Logger

  @doc """
  Add L2 auth headers for GET requests.
  """
  def add_l2_auth_headers(headers, method, request_path, _params, timestamp, config) do
    api_key = config[:api_key]
    api_secret = config[:api_secret]
    passphrase = config[:api_passphrase]
    # For proxy wallets, POLY_ADDRESS should be the signer (who derived the API creds)
    # Fall back to wallet_address for non-proxy setups
    auth_address = config[:signer_address] || config[:wallet_address]

    if api_key && api_secret && passphrase && auth_address do
      # Build the message to sign: timestamp + method + requestPath (no body for GET)
      # Must match Python: str(timestamp) + str(method) + str(requestPath)
      message = timestamp <> method <> request_path

      signature = generate_signature(api_secret, message)

      Logger.debug("HMAC message: #{message}")
      Logger.debug("HMAC signature: #{signature}")
      Logger.debug("Auth address (signer): #{auth_address}")
      Logger.debug("API key: #{api_key}")

      headers ++
        [
          {"POLY_ADDRESS", auth_address},
          {"POLY_SIGNATURE", signature},
          {"POLY_TIMESTAMP", timestamp},
          {"POLY_API_KEY", api_key},
          {"POLY_PASSPHRASE", passphrase}
        ]
    else
      Logger.warning(
        "Missing API credentials: key=#{!!api_key}, secret=#{!!api_secret}, pass=#{!!passphrase}, auth_address=#{!!auth_address}"
      )

      headers
    end
  end

  @doc """
  Add L2 auth headers for POST requests (includes body in signature).
  """
  def add_l2_auth_headers_post(headers, method, request_path, body, timestamp, config) do
    api_key = config[:api_key]
    api_secret = config[:api_secret]
    passphrase = config[:api_passphrase]
    # For proxy wallets, POLY_ADDRESS should be the signer (who derived the API creds)
    # Fall back to wallet_address for non-proxy setups
    auth_address = config[:signer_address] || config[:wallet_address]

    if api_key && api_secret && passphrase && auth_address do
      # Build the message to sign: timestamp + method + requestPath + body
      # For POST, body is included in the signature
      message = timestamp <> method <> request_path <> body

      signature = generate_signature(api_secret, message)

      Logger.debug("HMAC POST message: #{String.slice(message, 0, 200)}...")
      Logger.debug("HMAC signature: #{signature}")

      headers ++
        [
          {"POLY_ADDRESS", auth_address},
          {"POLY_SIGNATURE", signature},
          {"POLY_TIMESTAMP", timestamp},
          {"POLY_API_KEY", api_key},
          {"POLY_PASSPHRASE", passphrase}
        ]
    else
      Logger.warning("Missing API credentials for POST request")
      headers
    end
  end

  # Private functions

  defp generate_signature(api_secret, message) do
    # Decode secret - try URL-safe first, then standard base64
    secret =
      case Base.url_decode64(api_secret, padding: false) do
        {:ok, decoded} -> decoded
        :error -> Base.decode64!(api_secret)
      end

    # Create HMAC-SHA256 signature and encode with URL-safe base64 (with padding)
    :crypto.mac(:hmac, :sha256, secret, message)
    |> Base.url_encode64()
  end
end
