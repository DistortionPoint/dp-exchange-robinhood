defmodule DpExchange.Robinhood.AuthTest do
  use ExUnit.Case, async: true

  alias DpExchange.Robinhood.Auth

  # A deterministic 32-byte seed, base64 as the venue issues it.
  @seed :binary.copy(<<7>>, 32)
  @private_key Base.encode64(@seed)
  @api_key "rh-api-7c3f0000-0000-0000-0000-000000000000"
  @credentials %{api_key: @api_key, private_key: @private_key}

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} -> if key == name, do: value end)
  end

  describe "the signed payload, whose ordering IS the scheme" do
    test "is api_key, timestamp, path, method, body — concatenated, no separators" do
      assert Auth.payload("K", "1700000000", "/p?x=1", "get", "BODY") ==
               "K1700000000/p?x=1GETBODY"
    end

    test "the method is uppercased" do
      assert Auth.payload("K", "1", "/p", "post", "") == "K1/pPOST"
    end

    test "an empty body still occupies its slot" do
      # Not omitted — the concatenation has a place for it, and a signature computed
      # without one differs from a signature computed with an empty one only when the
      # preceding field could absorb it. Stated because both look identical here.
      assert Auth.payload("K", "1", "/p", "GET", "") == "K1/pGET"
    end
  end

  describe "headers/5" do
    test "carries the three headers the venue requires" do
      assert {:ok, headers} =
               Auth.headers("GET", "/api/v1/crypto/trading/accounts/", "", @credentials)

      assert header(headers, "x-api-key") == @api_key
      assert is_binary(header(headers, "x-timestamp"))
      assert is_binary(header(headers, "x-signature"))
    end

    test "the signature is a base64 Ed25519 signature, 64 bytes decoded" do
      assert {:ok, headers} =
               Auth.headers("GET", "/p", "", @credentials, timestamp: 1_700_000_000)

      assert {:ok, raw} = Base.decode64(header(headers, "x-signature"))
      assert byte_size(raw) == 64
    end

    test "it verifies against the public key derived from the same seed" do
      # The only assertion that proves the seed was used the way the venue means: a
      # signature this package produces must verify under the key that seed derives.
      {public, _secret} = :crypto.generate_key(:eddsa, :ed25519, @seed)

      assert {:ok, headers} =
               Auth.headers("GET", "/p?a=1", "", @credentials, timestamp: 1_700_000_000)

      signature = headers |> header("x-signature") |> Base.decode64!()
      payload = Auth.payload(@api_key, "1700000000", "/p?a=1", "GET", "")

      assert :crypto.verify(:eddsa, :none, payload, signature, [public, :ed25519])
    end

    test "the same inputs produce the same signature" do
      assert {:ok, first} = Auth.headers("GET", "/p", "", @credentials, timestamp: 1_700_000_000)
      assert {:ok, second} = Auth.headers("GET", "/p", "", @credentials, timestamp: 1_700_000_000)

      assert header(first, "x-signature") == header(second, "x-signature")
    end

    test "the QUERY STRING changes the signature, because the venue signs the full path" do
      # The easiest thing to get wrong here: signing the bare path makes every filtered
      # request fail with an unhelpful 401.
      assert {:ok, bare} = Auth.headers("GET", "/p", "", @credentials, timestamp: 1)

      assert {:ok, with_query} =
               Auth.headers("GET", "/p?symbol=BTC-USD", "", @credentials, timestamp: 1)

      refute header(bare, "x-signature") == header(with_query, "x-signature")
    end

    test "the method and the body each change the signature" do
      assert {:ok, get} = Auth.headers("GET", "/p", "", @credentials, timestamp: 1)
      assert {:ok, post} = Auth.headers("POST", "/p", "", @credentials, timestamp: 1)
      assert {:ok, bodied} = Auth.headers("POST", "/p", "{}", @credentials, timestamp: 1)

      refute header(get, "x-signature") == header(post, "x-signature")
      refute header(post, "x-signature") == header(bodied, "x-signature")
    end

    test "the timestamp is seconds, not milliseconds" do
      assert {:ok, headers} = Auth.headers("GET", "/p", "", @credentials)

      timestamp = headers |> header("x-timestamp") |> String.to_integer()
      assert abs(timestamp - System.system_time(:second)) <= 1
    end

    test "the private key never appears in a header value" do
      assert {:ok, headers} = Auth.headers("GET", "/p", "", @credentials)

      for {_name, value} <- headers, do: refute(String.contains?(value, @private_key))
    end
  end

  describe "refusals, which are clearer than the 401 they replace" do
    test "partial credentials are refused rather than signed with" do
      assert {:error, {:missing_credentials, :robinhood}} =
               Auth.headers("GET", "/p", "", %{api_key: @api_key})

      assert {:error, {:missing_credentials, :robinhood}} = Auth.headers("GET", "/p", "", %{})
    end

    test "a key that is not base64 is named as such" do
      assert {:error, {:invalid_private_key, :not_base64}} =
               Auth.headers("GET", "/p", "", %{api_key: "k", private_key: "not base64!!"})
    end

    test "a key of the wrong length is named, with the length" do
      # A 64-byte secret key rather than the 32-byte seed the venue issues signs fine and
      # is rejected by the venue with nothing to explain it.
      wrong = Base.encode64(:binary.copy(<<1>>, 64))

      assert {:error, {:invalid_private_key, {:expected_32_bytes, 64}}} =
               Auth.headers("GET", "/p", "", %{api_key: "k", private_key: wrong})
    end
  end
end
