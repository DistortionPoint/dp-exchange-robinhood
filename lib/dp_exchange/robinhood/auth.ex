defmodule DpExchange.Robinhood.Auth do
  @moduledoc """
  Signs a request with credentials the **host** has already obtained. Internal.

  > #### This package does not handle authentication {: .error}
  >
  > It signs. The host implements authentication and holds the credentials. This module is
  > handed them per call, signs one request, and keeps nothing.

  ## Robinhood's scheme

  Three headers:

      x-api-key:    <api key>
      x-timestamp:  <unix seconds>
      x-signature:  base64(ed25519_sign(payload, private_key))

  where the signed payload is a plain concatenation, in this order and with no separators:

      api_key <> timestamp <> path <> method <> body

  Four details in that line are easy to get wrong, and each produces the same unhelpful
  401:

  - **`path` includes the query string.** `/api/v1/crypto/marketdata/best_bid_ask/?symbol=BTC-USD`,
    not the path alone. A signature over the bare path fails on every request that filters.
  - **`method` is uppercase.**
  - **`body` is the empty string for a GET**, not omitted — the concatenation still has a
    slot for it.
  - **`timestamp` is seconds as a string**, not milliseconds.

  ## The key is a seed, not a signing key

  Robinhood issues a **base64-encoded 32-byte Ed25519 seed**. NaCl-style, the seed
  deterministically derives the signing key. Handing the seed to a signer that expects a
  full 64-byte secret key produces a valid-looking signature that the venue rejects — so
  the derivation happens here, once, from the venue's own format.
  """

  @typedoc "Credentials the host obtained. Signed with, and not kept."
  @type credentials :: %{
          required(:api_key) => String.t(),
          required(:private_key) => String.t()
        }

  @doc """
  Headers for a signed request.

  `path` must already include the query string, because the venue signs it.

  Returns `{:error, {:missing_credentials, :robinhood}}` rather than signing with a partial
  credential, and `{:error, {:invalid_private_key, reason}}` when the key is not the
  base64 32-byte seed the venue issues — both of which are clearer than the 401 they would
  otherwise become.
  """
  @spec headers(String.t(), String.t(), String.t(), credentials(), keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def headers(method, path, body, credentials, opts \\ [])

  def headers(method, path, body, %{api_key: api_key, private_key: private_key}, opts)
      when is_binary(method) and is_binary(path) and is_binary(body) do
    timestamp = opts |> Keyword.get(:timestamp, System.system_time(:second)) |> to_string()

    with {:ok, seed} <- decode_seed(private_key) do
      payload = api_key <> timestamp <> path <> String.upcase(method) <> body
      {_public, secret} = :crypto.generate_key(:eddsa, :ed25519, seed)
      signature = :crypto.sign(:eddsa, :none, payload, [secret, :ed25519])

      {:ok,
       [
         {"x-api-key", api_key},
         {"x-timestamp", timestamp},
         {"x-signature", Base.encode64(signature)}
       ]}
    end
  end

  def headers(_method, _path, _body, _credentials, _opts),
    do: {:error, {:missing_credentials, :robinhood}}

  @doc """
  The signed payload, exposed because its ordering is the whole scheme.

  A signature is opaque; the string it was taken over is not, and it is the thing worth
  asserting.
  """
  @spec payload(String.t(), String.t(), String.t(), String.t(), String.t()) :: String.t()
  def payload(api_key, timestamp, path, method, body),
    do: api_key <> to_string(timestamp) <> path <> String.upcase(method) <> body

  # The venue issues a base64 32-byte seed. Anything else is refused here rather than
  # producing a signature the venue will reject with no explanation.
  defp decode_seed(private_key) do
    case Base.decode64(private_key) do
      {:ok, <<seed::binary-size(32)>>} ->
        {:ok, seed}

      {:ok, other} ->
        {:error, {:invalid_private_key, {:expected_32_bytes, byte_size(other)}}}

      :error ->
        {:error, {:invalid_private_key, :not_base64}}
    end
  end
end
