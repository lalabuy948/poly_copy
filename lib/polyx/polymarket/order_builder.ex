defmodule Polyx.Polymarket.OrderBuilder do
  @moduledoc """
  Builds and signs orders for Polymarket's CTF Exchange using EIP-712.

  The order struct follows the CTFExchange contract:
  - Order(uint256 salt, address maker, address signer, address taker, uint256 tokenId,
          uint256 makerAmount, uint256 takerAmount, uint256 expiration, uint256 nonce,
          uint256 feeRateBps, uint8 side, uint8 signatureType)
  """

  require Logger

  # Side enum
  @side_buy 0
  @side_sell 1

  # Signature types
  @sig_type_eoa 0
  @sig_type_poly_proxy 2

  # EIP-712 domain
  @domain_name "Polymarket CTF Exchange"
  @domain_version "1"

  # Chain IDs
  @polygon_chain_id 137

  # Contract addresses (Polygon mainnet)
  @ctf_exchange_address "0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E"
  @neg_risk_ctf_exchange "0xC5d563A36AE78145C45a50134d48A1215220f80a"

  # Zero address for taker (open order)
  @zero_address "0x0000000000000000000000000000000000000000"

  # ORDER_TYPEHASH = keccak256("Order(uint256 salt,address maker,address signer,address taker,uint256 tokenId,uint256 makerAmount,uint256 takerAmount,uint256 expiration,uint256 nonce,uint256 feeRateBps,uint8 side,uint8 signatureType)")
  @order_typehash_string "Order(uint256 salt,address maker,address signer,address taker,uint256 tokenId,uint256 makerAmount,uint256 takerAmount,uint256 expiration,uint256 nonce,uint256 feeRateBps,uint8 side,uint8 signatureType)"

  @doc """
  Build and sign a market order to buy outcome tokens.

  ## Parameters
  - token_id: The ERC1155 token ID for the outcome
  - side: :buy or :sell
  - amount: Dollar amount for buy, share amount for sell
  - price: Price per share (0.0 to 1.0)
  - opts: Additional options
    - :private_key - The private key to sign with (required)
    - :wallet_address - The maker/funder address (required)
    - :signer_address - The signer address if using proxy wallet (optional)
    - :neg_risk - Whether this is a neg risk market (default false)
    - :order_type - :fok, :fak, :gtc, :gtd (default :gtc)
  """
  def build_order(token_id, side, amount, price, opts) do
    private_key = Keyword.fetch!(opts, :private_key)
    wallet_address = Keyword.fetch!(opts, :wallet_address)
    signer_address = Keyword.get(opts, :signer_address)
    neg_risk = Keyword.get(opts, :neg_risk, false)

    # Determine if using proxy wallet (signer differs from maker)
    {signer, sig_type} =
      if signer_address && normalize_address(signer_address) != normalize_address(wallet_address) do
        {normalize_address(signer_address), @sig_type_poly_proxy}
      else
        {normalize_address(wallet_address), @sig_type_eoa}
      end

    # Calculate amounts based on side
    {maker_amount, taker_amount} = calculate_amounts(side, amount, price)

    salt = generate_salt()

    # Build the order struct for signing (uses integers for side/signatureType)
    order_for_signing = %{
      salt: salt,
      maker: normalize_address(wallet_address),
      signer: signer,
      taker: normalize_address(@zero_address),
      tokenId: token_id,
      makerAmount: Integer.to_string(maker_amount),
      takerAmount: Integer.to_string(taker_amount),
      expiration: "0",
      nonce: "0",
      feeRateBps: "0",
      side: side_to_int(side),
      signatureType: sig_type
    }

    # Sign the order
    exchange_address = if neg_risk, do: @neg_risk_ctf_exchange, else: @ctf_exchange_address

    case sign_order(order_for_signing, private_key, exchange_address) do
      {:ok, signature} ->
        # Build API payload - matching TypeScript NewOrder type exactly
        # expiration, nonce, feeRateBps are strings per TypeScript types.ts
        api_order = %{
          salt: salt,
          maker: order_for_signing.maker,
          signer: order_for_signing.signer,
          taker: order_for_signing.taker,
          tokenId: order_for_signing.tokenId,
          makerAmount: Integer.to_string(maker_amount),
          takerAmount: Integer.to_string(taker_amount),
          expiration: "0",
          nonce: "0",
          feeRateBps: "0",
          side: side_to_api_string(side),
          signatureType: sig_type,
          signature: signature
        }

        {:ok, api_order}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sign an order using EIP-712 typed data signing.
  """
  def sign_order(order, private_key, exchange_address) do
    # Build domain separator
    domain_separator = build_domain_separator(exchange_address)

    # Build order struct hash
    order_hash = hash_order(order)

    # Build the final message to sign (EIP-712 format)
    # \x19\x01 ++ domainSeparator ++ hashStruct(message)
    message =
      <<0x19, 0x01>> <>
        decode_hex(domain_separator) <>
        decode_hex(order_hash)

    # Hash the message
    message_hash = keccak256(message)

    # Sign with the private key
    case sign_message(message_hash, private_key) do
      {:ok, signature} ->
        {:ok, "0x" <> Base.encode16(signature, case: :lower)}

      error ->
        error
    end
  end

  @doc """
  Build the EIP-712 domain separator.
  """
  def build_domain_separator(exchange_address) do
    # EIP-712 domain type hash
    domain_type =
      "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"

    domain_type_hash = keccak256(domain_type)

    # Hash the domain values
    name_hash = keccak256(@domain_name)
    version_hash = keccak256(@domain_version)
    chain_id = <<@polygon_chain_id::unsigned-big-integer-size(256)>>
    verifying_contract = pad_address(exchange_address)

    # Encode and hash
    encoded =
      domain_type_hash <>
        name_hash <>
        version_hash <>
        chain_id <>
        verifying_contract

    "0x" <> Base.encode16(keccak256(encoded), case: :lower)
  end

  @doc """
  Hash an order struct according to EIP-712.
  """
  def hash_order(order) do
    order_type_hash = keccak256(@order_typehash_string)

    encoded =
      order_type_hash <>
        encode_uint256(order.salt) <>
        pad_address(order.maker) <>
        pad_address(order.signer) <>
        pad_address(order.taker) <>
        encode_uint256(order.tokenId) <>
        encode_uint256(order.makerAmount) <>
        encode_uint256(order.takerAmount) <>
        encode_uint256(order.expiration) <>
        encode_uint256(order.nonce) <>
        encode_uint256(order.feeRateBps) <>
        encode_uint8(order.side) <>
        encode_uint8(order.signatureType)

    "0x" <> Base.encode16(keccak256(encoded), case: :lower)
  end

  # Private functions

  defp calculate_amounts(:buy, size, price) do
    # For BUY limit orders:
    # - size = number of tokens to buy
    # - makerAmount = USDC to pay = size × price
    # - takerAmount = tokens to receive = size
    #
    # Example: Buy 5.01 tokens at $0.998 each
    # - takerAmount = 5.01 tokens = 5010000 (6 decimals)
    # - makerAmount = 5.01 × 0.998 = 4.99998 USDC = 4999980 (6 decimals)
    #
    # Rounding: round down to 2 decimal places for amounts
    token_amount = (round_down_decimals(size, 2) * 1_000_000) |> trunc()
    usdc_amount = (round_down_decimals(size * price, 5) * 1_000_000) |> trunc()

    {usdc_amount, token_amount}
  end

  defp calculate_amounts(:sell, size, price) do
    # For SELL limit orders:
    # - size = number of tokens to sell
    # - makerAmount = tokens to give = size
    # - takerAmount = USDC to receive = size × price
    #
    # Example: Sell 5.01 tokens at $0.998 each
    # - makerAmount = 5.01 tokens = 5010000 (6 decimals)
    # - takerAmount = 5.01 × 0.998 = 4.99998 USDC = 4999980 (6 decimals)
    token_amount = (round_down_decimals(size, 2) * 1_000_000) |> trunc()
    usdc_amount = (round_down_decimals(size * price, 5) * 1_000_000) |> trunc()

    {token_amount, usdc_amount}
  end

  # Round down to specified decimal places (for human-readable amounts)
  # e.g., round_down_decimals(5.019, 2) = 5.01
  defp round_down_decimals(amount, decimals) do
    multiplier = :math.pow(10, decimals)
    Float.floor(amount * multiplier) / multiplier
  end

  defp side_to_int(:buy), do: @side_buy
  defp side_to_int(:sell), do: @side_sell

  defp side_to_api_string(:buy), do: "BUY"
  defp side_to_api_string(:sell), do: "SELL"

  defp generate_salt do
    # Generate a random salt (32-bit range like Python examples)
    :rand.uniform(2_147_483_647)
  end

  defp normalize_address(address) do
    address
    |> String.downcase()
    |> String.replace_prefix("0x", "")
    |> then(&("0x" <> &1))
  end

  defp pad_address(address) do
    address
    |> String.replace_prefix("0x", "")
    |> String.downcase()
    |> Base.decode16!(case: :lower)
    |> then(&(<<0::size(96)>> <> &1))
  end

  defp encode_uint256(value) when is_binary(value) do
    value
    |> String.to_integer()
    |> encode_uint256()
  end

  defp encode_uint256(value) when is_integer(value) do
    <<value::unsigned-big-integer-size(256)>>
  end

  defp encode_uint8(value) when is_integer(value) do
    <<0::size(248), value::unsigned-big-integer-size(8)>>
  end

  defp decode_hex("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp decode_hex(hex), do: Base.decode16!(hex, case: :mixed)

  defp keccak256(data) when is_binary(data) do
    ExKeccak.hash_256(data)
  end

  defp sign_message(message_hash, private_key) do
    # Decode private key
    private_key_bytes =
      private_key
      |> String.replace_prefix("0x", "")
      |> Base.decode16!(case: :mixed)

    # Sign using secp256k1
    # Returns {:ok, {r, s, recovery_id}} where r and s are 32-byte binaries
    case ExSecp256k1.sign(message_hash, private_key_bytes) do
      {:ok, {r, s, recovery_id}} ->
        # EIP-155 recovery id adjustment (add 27)
        v = recovery_id + 27
        signature = r <> s <> <<v>>
        {:ok, signature}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
