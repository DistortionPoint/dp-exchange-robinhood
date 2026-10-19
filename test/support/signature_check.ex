defmodule DpExchange.Robinhood.Test.SignatureCheck do
  @moduledoc false
  # What the venue does with a signed request, done in a test plug: recompute the signed
  # message from the request AS IT ARRIVED (path with its query string, uppercase method, the
  # body bytes received) and verify the `x-signature` header against the public key the seed
  # derives. A test that only asserts the headers exist proves nothing about what they cover.

  alias DpExchange.Robinhood.Auth

  # The venue honours an `x-timestamp` for 30 seconds (the `Timestamp` security scheme).
  @window_seconds 30

  @doc """
  `:ok` when `conn`'s `x-api-key` is `api_key`, its `x-timestamp` is whole seconds within the
  venue's 30-second window, and its `x-signature` is a valid Ed25519 signature, under the key
  `seed` derives, over `api_key <> timestamp <> path_and_query <> METHOD <> body` for the
  request as received. Otherwise `{:error, reason}`.
  """
  @spec verify(Plug.Conn.t(), String.t(), binary(), String.t()) :: :ok | {:error, term()}
  def verify(%Plug.Conn{} = conn, api_key, seed, body) when byte_size(seed) == 32 do
    with {:ok, sent_key} <- single_header(conn, "x-api-key"),
         {:ok, timestamp} <- single_header(conn, "x-timestamp"),
         {:ok, encoded} <- single_header(conn, "x-signature"),
         :ok <- same_key(sent_key, api_key),
         :ok <- fresh(timestamp),
         {:ok, signature} <- decoded(Base.decode64(encoded)) do
      payload = Auth.payload(api_key, timestamp, path_and_query(conn), conn.method, body)
      {public, _secret} = :crypto.generate_key(:eddsa, :ed25519, seed)

      if :crypto.verify(:eddsa, :none, payload, signature, [public, :ed25519]),
        do: :ok,
        else: {:error, {:bad_signature, payload}}
    end
  end

  defp path_and_query(%Plug.Conn{request_path: path, query_string: query}) do
    if query in [nil, ""], do: path, else: path <> "?" <> query
  end

  defp single_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value] -> {:ok, value}
      other -> {:error, {:header, name, other}}
    end
  end

  defp same_key(key, key), do: :ok
  defp same_key(sent, _expected), do: {:error, {:api_key, sent}}

  defp fresh(timestamp) do
    case Integer.parse(timestamp) do
      {seconds, ""} when seconds > 0 ->
        if abs(System.system_time(:second) - seconds) <= @window_seconds,
          do: :ok,
          else: {:error, {:stale_timestamp, timestamp}}

      _not_seconds ->
        {:error, {:timestamp, timestamp}}
    end
  end

  defp decoded({:ok, signature}) when byte_size(signature) == 64, do: {:ok, signature}
  defp decoded(other), do: {:error, {:signature_encoding, other}}
end
