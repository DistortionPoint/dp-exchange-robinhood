defmodule DpExchange.Robinhood.OptionRefusalTest do
  @moduledoc """
  Options are refused, not ignored, when ignoring them would change what a call means.

  Two defects, one rule. Every facade call reads its options with `Keyword` functions, which
  raise inside the caller's process when the options are a map or a string: a call that moves
  funds (`place_order/3`, `cancel_order/3`) among them. And the contract's market-data options
  (`:limit`, `:depth`, `:since`, `:include_partial`) were accepted and dropped by calls that
  can honour none of them, so `get_symbols(limit: 1)` returned the whole catalogue to a caller
  who believed it had asked for one row and `subscribe(symbols, depth: 5)` subscribed to a
  top of book. `DpExchange.Core.Venue` says such an option is
  `{:error, {:unsupported_option, key}}`, never ignored. The Fake refuses the same.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Robinhood
  alias DpExchange.Robinhood.{Fake, Rest}

  @moduletag :capture_log

  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{api_key: "k", private_key: Base.encode64(:binary.copy(<<3>>, 32))}
  @request %{
    symbol: "BTC-USD",
    side: :buy,
    order_type: :market,
    quantity: "1"
  }

  # Reports every request that reaches the transport, then answers an empty page.
  defp capturing(test_pid) do
    fn conn ->
      send(test_pid, {:request, conn.request_path, conn.query_string})
      Req.Test.json(conn, %{"results" => []})
    end
  end

  # Values that are not a keyword list, including the improper list `Keyword` walks into.
  defp not_keyword do
    [%{credentials: @credentials}, "opts", 5, [1, 2], [{"a", 1}], [{:a, 1} | :tail]]
  end

  defp invalid_opts?({:error, {:invalid_options, _value}}), do: true
  defp invalid_opts?(_other), do: false

  describe "options that are not a keyword list" do
    test "the real facade answers {:invalid_options, _} for every call that reads them" do
      for bad <- not_keyword() do
        answers = [
          Robinhood.get_top_of_book("BTC-USD", bad),
          Robinhood.get_symbols(bad),
          Robinhood.list_instruments(bad),
          Robinhood.quantization("BTC-USD", bad),
          Robinhood.get_balances(@credentials, bad),
          Robinhood.get_accounts(@credentials, bad),
          Robinhood.place_order(@credentials, @request, bad),
          Robinhood.cancel_order(@credentials, "order-1", bad),
          Robinhood.get_order(@credentials, "order-1", bad),
          Robinhood.get_orders(@credentials, bad),
          Robinhood.get_estimated_price("BTC-USD", :ask, "1", @credentials, bad),
          Robinhood.subscribe(["BTC-USD"], bad),
          Robinhood.unsubscribe(["BTC-USD"], bad),
          Robinhood.update_symbols(["BTC-USD"], bad),
          Robinhood.subscribe_notices(bad)
        ]

        assert Enum.all?(answers, &invalid_opts?/1),
               "options #{inspect(bad)} gave #{inspect(answers, limit: :infinity)}"
      end
    end

    test "the reads with no error channel raise rather than answer 'nothing covered'" do
      for bad <- not_keyword() do
        assert_raise ArgumentError, ~r/options must be a keyword list/, fn ->
          Robinhood.coverage(bad)
        end

        assert_raise ArgumentError, ~r/options must be a keyword list/, fn ->
          Robinhood.coverage_by_kind(bad)
        end

        assert_raise ArgumentError, ~r/options must be a keyword list/, fn ->
          Robinhood.wanted(bad)
        end
      end
    end

    test "the raise bounds the value it shows" do
      error =
        assert_raise ArgumentError, fn -> Robinhood.coverage(String.duplicate("x", 10_000)) end

      assert byte_size(Exception.message(error)) < 300
    end

    test "the Fake refuses exactly what the facade refuses" do
      for bad <- not_keyword() do
        answers = [
          Fake.get_top_of_book("BTC-USD", bad),
          Fake.get_symbols(bad),
          Fake.list_instruments(bad),
          Fake.quantization("BTC-USD", bad),
          Fake.get_balances(@credentials, bad),
          Fake.get_accounts(@credentials, bad),
          Fake.place_order(@credentials, @request, bad),
          Fake.cancel_order(@credentials, "order-1", bad),
          Fake.get_order(@credentials, "order-1", bad),
          Fake.get_orders(@credentials, bad),
          Fake.get_estimated_price("BTC-USD", :ask, "1", @credentials, bad),
          Fake.subscribe(["BTC-USD"], bad),
          Fake.unsubscribe(["BTC-USD"], bad),
          Fake.update_symbols(["BTC-USD"], bad),
          Fake.subscribe_notices(bad)
        ]

        assert Enum.all?(answers, &invalid_opts?/1),
               "options #{inspect(bad)} gave #{inspect(answers, limit: :infinity)}"
      end

      assert Fake.wanted() == []
    end

    test "an empty keyword list is still a keyword list" do
      assert Rest.validate_opts([], :get_orders) == :ok
      assert Rest.validate_opts([credentials: @credentials, limit: 1], :get_orders) == :ok
    end

    test "the value rides the error bounded, so a hostile options term cannot flood a log" do
      huge = String.duplicate("x", 10_000)

      assert {:error, {:invalid_options, shown}} = Robinhood.get_symbols(huge)
      assert is_binary(shown)
      assert byte_size(shown) < 200
    end
  end

  describe "market-data options this venue cannot honour" do
    for key <- [:limit, :depth, :since, :include_partial] do
      test "#{key} is {:unsupported_option, #{inspect(key)}} on the real market-data calls" do
        key = unquote(key)
        refused = {:error, {:unsupported_option, key}}
        opts = [{key, 1}, credentials: @credentials, plug: capturing(self())]

        assert Robinhood.get_top_of_book("BTC-USD", opts) == refused
        assert Robinhood.get_symbols(opts) == refused
        assert Robinhood.list_instruments(opts) == refused
        assert Robinhood.subscribe(["BTC-USD"], [{key, 1}]) == refused
        assert Robinhood.update_symbols(["BTC-USD"], [{key, 1}]) == refused

        # Refused before anything was signed or sent: each call above has returned.
        refute_received {:request, _path, _query}
      end

      test "#{key} is {:unsupported_option, #{inspect(key)}} on the Fake's market-data calls" do
        key = unquote(key)
        refused = {:error, {:unsupported_option, key}}
        opts = [{key, 1}, credentials: @credentials]

        assert Fake.get_top_of_book("BTC-USD", opts) == refused
        assert Fake.get_symbols(opts) == refused
        assert Fake.list_instruments(opts) == refused
        assert Fake.subscribe(["BTC-USD"], [{key, 1}]) == refused
        assert Fake.update_symbols(["BTC-USD"], [{key, 1}]) == refused

        # A refused subscribe subscribed to nothing.
        assert Fake.wanted() == []
      end
    end

    test "a forwarded nil is an absent option, as everywhere in this family" do
      opts = [credentials: @credentials, limit: nil, depth: nil, since: nil, include_partial: nil]

      assert {:ok, symbols} = Fake.get_symbols(opts)
      assert symbols == ["BTC-USD", "DOGE-USD", "ETH-USD"]
      assert {:ok, %{symbol: "BTC-USD"}} = Fake.get_top_of_book("BTC-USD", opts)
      assert Rest.validate_market_opts(opts, :get_symbols) == :ok
    end

    test "the first offending option is the one named" do
      assert Rest.validate_market_opts([since: 1, limit: 2], :get_symbols) ==
               {:error, {:unsupported_option, :limit}}
    end

    test "get_orders keeps :limit, which there means one page" do
      opts = [account_number: "RH-1", limit: 1, plug: capturing(self()), retry_attempts: 0]

      assert {:ok, []} = Robinhood.get_orders(@credentials, opts)
      assert_received {:request, "/api/v2/crypto/trading/orders/", _query}
    end
  end
end
