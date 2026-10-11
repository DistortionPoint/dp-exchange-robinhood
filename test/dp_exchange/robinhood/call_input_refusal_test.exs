defmodule DpExchange.Robinhood.CallInputRefusalTest do
  @moduledoc """
  A call whose own arguments are unusable is refused locally, before anything is signed,
  instead of raising in the caller's process or going out with an empty parameter.

  `get_top_of_book/3` and `quantization/3` raised `FunctionClauseError` on a symbol that
  was not a string and built `symbol=` for a blank one; `get_order/3` and `cancel_order/3`
  raised on an id that was not a string; a blank `:account_number` was signed and sent as
  `account_number=`; the bulk quote read raised on any non-string symbol in the list.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
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

  # Reports every request that reaches the transport to the test, then answers a page.
  defp capturing(test_pid, body \\ %{"results" => []}) do
    fn conn ->
      send(test_pid, {:request, conn.request_path, conn.query_string})
      Req.Test.json(conn, body)
    end
  end

  defp opts(extra \\ []), do: [plug: capturing(self()), retry_attempts: 0] ++ extra

  describe "Rest refuses unusable arguments without a request" do
    test "a symbol that is not a non-empty string" do
      for bad <- [nil, :btc, 5, ""] do
        assert {:error, {:invalid_field, :symbol}} =
                 Rest.get_top_of_book(bad, @credentials, opts())

        assert {:error, {:invalid_field, :symbol}} =
                 Rest.quantization(bad, @credentials, opts())
      end

      refute_received {:request, _path, _query}
    end

    test "an order id that is not a string is a missing id" do
      for bad <- [nil, :id, 5] do
        assert {:error, {:missing_field, :id}} =
                 Rest.get_order(@credentials, bad, opts(account_number: "RH-1"))

        assert {:error, {:missing_field, :id}} = Rest.cancel_order(@credentials, bad, opts())
      end

      refute_received {:request, _path, _query}
    end

    test "a blank account number is no account number" do
      for blank <- ["", "  "] do
        expected = {:error, {:account_number_required, :robinhood}}
        assert expected == Rest.get_orders(@credentials, opts(account_number: blank))
        assert expected == Rest.get_balances(@credentials, opts(account_number: blank))
        assert expected == Rest.get_order(@credentials, "abc", opts(account_number: blank))

        assert expected ==
                 Rest.place_order(
                   @credentials,
                   %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: "1"},
                   opts(account_number: blank)
                 )
      end

      refute_received {:request, _path, _query}
    end

    test "the bulk read refuses a list holding a non-string symbol" do
      for bad <- [["BTC-USD", nil], [:eth], [""], "BTC-USD"] do
        assert {:error, {:invalid_field, key}} =
                 Rest.get_top_of_book_bulk(bad, @credentials, opts())

        assert key in [:symbol, :symbols]
      end

      refute_received {:request, _path, _query}
    end

    test "the bulk read refuses more symbols than one bounded request carries" do
      cap = Rest.max_bulk_symbols()
      over = for n <- 1..(cap + 1), do: "S#{n}-USD"

      assert {:error, {:too_many_symbols, ^cap}} =
               Rest.get_top_of_book_bulk(over, @credentials, opts())

      refute_received {:request, _path, _query}

      # Exactly the cap is sent, and a repeated symbol counts once.
      within = Enum.take(over, cap) ++ ["S1-USD"]
      assert {:ok, []} = Rest.get_top_of_book_bulk(within, @credentials, opts())

      assert_receive {:request, _path, _query}, 5_000
    end

    test "the bulk read asks for a repeated symbol once" do
      assert {:ok, []} =
               Rest.get_top_of_book_bulk(
                 ["BTC-USD", "ETH-USD", "BTC-USD"],
                 @credentials,
                 opts()
               )

      assert_receive {:request, "/api/v2/crypto/marketdata/best_bid_ask/", query}, 5_000
      assert query == "symbol=BTC-USD&symbol=ETH-USD"
    end
  end

  describe "the fake refuses what Rest refuses" do
    test "a symbol that is not a non-empty string" do
      for bad <- [nil, :btc, 5, ""] do
        assert {:error, {:invalid_field, :symbol}} =
                 Fake.get_top_of_book(bad, credentials: @credentials)

        assert {:error, {:invalid_field, :symbol}} =
                 Fake.quantization(bad, credentials: @credentials)
      end
    end

    test "an order id that is not a string" do
      for bad <- [nil, :id, 5] do
        assert {:error, {:missing_field, :id}} =
                 Fake.get_order(@credentials, bad, account_number: "RH-1")

        assert {:error, {:missing_field, :id}} = Fake.cancel_order(@credentials, bad, [])
      end
    end

    test "a blank account number" do
      assert {:error, {:account_number_required, :robinhood}} =
               Fake.get_orders(@credentials, account_number: " ")
    end

    test "order filters outside the spec's enums" do
      for {key, value} <- [side: :hold, type: :trailing, state: :partially_filled] do
        assert {:error, {:invalid_field, ^key}} =
                 Fake.get_orders(@credentials, [{key, value}, account_number: "RH-1"])
      end
    end

    test "subscribe/2 de-duplicates after upper-casing" do
      assert :ok = Fake.subscribe(["btc-usd", "BTC-USD"], [])
      assert_received {:dp_exchange, :robinhood, %{symbol: "BTC-USD"}}
      refute_received {:dp_exchange, :robinhood, %{symbol: "BTC-USD"}}
    end
  end

  describe "get_orders/2 order filters follow the spec's enums" do
    @base [account_number: "RH-1"]

    test "dates: a DateTime and a string are sent, anything else is refused" do
      start = [created_at_start: ~U[2026-10-01 00:00:00Z]]
      assert {:ok, []} = Rest.get_orders(@credentials, opts(@base ++ start))

      assert_receive {:request, _path, query}, 5_000
      assert URI.decode_query(query)["created_at_start"] == "2026-10-01T00:00:00Z"

      for bad <- [~N[2026-10-01 00:00:00], ~D[2026-10-01], 5, "yesterday", "2026-10-01", ""] do
        assert {:error, {:invalid_field, :updated_at_end}} =
                 Rest.get_orders(@credentials, opts(@base ++ [updated_at_end: bad]))
      end

      refute_received {:request, _path, _query}
    end

    test "side, type and state are mapped to the venue's words" do
      assert {:ok, []} =
               Rest.get_orders(
                 @credentials,
                 opts(@base ++ [side: :buy, type: :stop, state: :cancelled])
               )

      assert_receive {:request, _path, query}, 5_000
      decoded = URI.decode_query(query)
      assert %{"side" => "buy", "type" => "stop_loss", "state" => "canceled"} = decoded
    end

    test "values outside the enums are refused before signing" do
      for {key, bad} <- [
            side: :hold,
            side: "BUY",
            type: :trailing,
            state: "cancelled",
            state: :partially_filled,
            symbol: :btc,
            symbol: ""
          ] do
        assert {:error, {:invalid_field, ^key}} =
                 Rest.get_orders(@credentials, opts(@base ++ [{key, bad}]))
      end

      refute_received {:request, _path, _query}
    end
  end
end
