defmodule DpExchange.Robinhood.ParityEdgeCasesTest do
  @moduledoc """
  Tick AF: the fake answers what the real path answers for the same input, sibling options
  are validated alike, and the decoders refuse the plausible-but-wrong edge cases (negative or
  zero where positive is required, wrong types, huge exponents, duplicate entries, crossed
  books) instead of returning a value that merely looks right.
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

  @credentials %{
    api_key: "test-key-not-real",
    private_key: Base.encode64(:binary.copy(<<7>>, 32))
  }
  @account [account_number: "RH-1"]

  defp responding(body), do: fn conn -> Req.Test.json(conn, body) end

  # Reports every request, so a test can say that nothing went out.
  defp counting(test_pid, body) do
    fn conn ->
      send(test_pid, {:request, conn.request_path, conn.query_string})
      Req.Test.json(conn, body)
    end
  end

  defp opts(extra), do: [retry_attempts: 0] ++ extra

  defp account_row do
    %{"account_number" => "RH-1", "buying_power" => "1", "buying_power_currency" => "USD"}
  end

  # Holdings from `/holdings/`, the account's cash from anything else.
  defp holdings_and_accounts(holdings) do
    fn conn ->
      if String.contains?(conn.request_path, "/holdings/"),
        do: Req.Test.json(conn, holdings),
        else: Req.Test.json(conn, %{"results" => [account_row()]})
    end
  end

  describe "the catalogue lists a pair once" do
    test "get_symbols collapses a repeated or differently cased pair" do
      body = %{
        "results" => [
          %{"symbol" => "ETH-USD"},
          %{"symbol" => "BTC-USD"},
          %{"symbol" => "btc-usd"},
          %{"symbol" => "ETH-USD"}
        ]
      }

      assert {:ok, ["BTC-USD", "ETH-USD"]} =
               Rest.get_symbols(@credentials, opts(plug: responding(body)))
    end

    test "list_instruments collapses an identical repeat" do
      row = %{"symbol" => "BTC-USD", "asset_code" => "BTC", "quote_code" => "USD"}
      body = %{"results" => [row, row]}

      assert {:ok, [%{symbol: "BTC-USD"}]} =
               Rest.list_instruments(@credentials, opts(plug: responding(body)))
    end

    test "list_instruments refuses a pair listed twice with different meanings" do
      body = %{
        "results" => [
          %{"symbol" => "BTC-USD", "status" => "tradable"},
          %{"symbol" => "BTC-USD", "status" => "halted"}
        ]
      }

      assert {:error, {:duplicate_symbol, "BTC-USD"}} =
               Rest.list_instruments(@credentials, opts(plug: responding(body)))
    end
  end

  describe "an account or an asset is listed once" do
    test "get_accounts refuses a repeated account number" do
      body = %{"results" => [account_row(), account_row()]}

      assert {:error, {:duplicate_account, "RH-1"}} =
               Rest.get_accounts(@credentials, opts(plug: responding(body)))
    end

    test "get_balances refuses a holding listed twice rather than letting it be summed" do
      holding = %{
        "asset_code" => "BTC",
        "total_quantity" => "1",
        "quantity_available_for_trading" => "1"
      }

      plug = holdings_and_accounts(%{"results" => [holding, holding]})

      assert {:error, {:duplicate_asset, "BTC"}} =
               Rest.get_balances(@credentials, @account ++ opts(plug: plug))
    end

    test "distinct assets are still returned in the venue's order, cash last" do
      holdings = [
        %{"asset_code" => "ETH", "total_quantity" => "2"},
        %{"asset_code" => "BTC", "total_quantity" => "1"}
      ]

      plug = holdings_and_accounts(%{"results" => holdings})

      assert {:ok, balances} = Rest.get_balances(@credentials, @account ++ opts(plug: plug))
      assert Enum.map(balances, & &1.currency) == ["ETH", "BTC", "USD"]
    end
  end

  describe "get_orders/2 and get_order/3: a read refuses an amount that is not a quantity" do
    defp limit_order(extra) do
      Map.merge(%{"id" => "o-1", "state" => "open", "type" => "limit"}, extra)
    end

    @refused [
      {:quantity, %{"limit_order_config" => %{"asset_quantity" => "-1", "limit_price" => "6"}}},
      {:quantity, %{"limit_order_config" => %{"asset_quantity" => "0", "limit_price" => "6"}}},
      {:quantity, %{"limit_order_config" => %{"asset_quantity" => "abc", "limit_price" => "6"}}},
      {:quantity, %{"limit_order_config" => %{"asset_quantity" => true, "limit_price" => "6"}}},
      {:quantity, %{"limit_order_config" => %{"asset_quantity" => "1E5000"}}},
      {:quantity, %{"limit_order_config" => %{"asset_quantity" => "NaN", "limit_price" => "6"}}},
      {:price, %{"limit_order_config" => %{"asset_quantity" => "1", "limit_price" => "-5"}}},
      {:price, %{"limit_order_config" => %{"asset_quantity" => "1", "limit_price" => "0"}}},
      {:price, %{"limit_order_config" => %{"asset_quantity" => "1", "limit_price" => [1]}}},
      {:price,
       %{"limit_order_config" => %{"asset_quantity" => "1", "limit_price" => %{"a" => 1}}}},
      {:stop_price,
       %{
         "type" => "stop_limit",
         "stop_limit_order_config" => %{
           "asset_quantity" => "1",
           "limit_price" => "10",
           "stop_price" => "-1"
         }
       }},
      {:filled_quantity, %{"filled_asset_quantity" => "-0.1"}},
      {:filled_quantity, %{"filled_asset_quantity" => "x"}},
      {:average_price, %{"average_price" => "-1"}},
      {:average_price, %{"average_price" => false}},
      {:fee, %{"fee_charged" => "-0.01"}},
      {:fee, %{"fee_charged" => "NaN"}}
    ]

    for {{field, extra}, index} <- Enum.with_index(@refused) do
      test "#{index}: a bad #{field} is refused as invalid_decimal" do
        body = limit_order(unquote(Macro.escape(extra)))
        field = unquote(field)

        assert {:error, {:invalid_decimal, ^field, _raw}} =
                 Rest.get_order(@credentials, "o-1", @account ++ opts(plug: responding(body)))

        page = %{"results" => [body], "next" => nil}

        assert {:error, {:invalid_decimal, ^field, _raw}} =
                 Rest.get_orders(@credentials, @account ++ opts(plug: responding(page)))
      end
    end

    test "zero fills, a zero average price and a zero fee are an order that has not traded" do
      body =
        limit_order(%{
          "filled_asset_quantity" => "0",
          "average_price" => 0,
          "fee_charged" => "0.0",
          "limit_order_config" => %{"asset_quantity" => "1", "limit_price" => "2"}
        })

      assert {:ok, order} =
               Rest.get_order(@credentials, "o-1", @account ++ opts(plug: responding(body)))

      assert Decimal.equal?(order.filled_quantity, 0)
      assert Decimal.equal?(order.average_price, 0)
      assert Decimal.equal?(order.fee, 0)
    end

    test "null, an empty string and an absent key state nothing, and stay nil" do
      body =
        limit_order(%{
          "filled_asset_quantity" => "",
          "average_price" => nil,
          "limit_order_config" => %{"asset_quantity" => "1", "limit_price" => ""}
        })

      assert {:ok, order} =
               Rest.get_order(@credentials, "o-1", @account ++ opts(plug: responding(body)))

      assert {order.filled_quantity, order.average_price, order.price, order.fee} ==
               {nil, nil, nil, nil}
    end

    test "an id that is missing, empty or not text is no order" do
      for bad <- [nil, "", 5, %{"x" => 1}] do
        body = %{"id" => bad, "state" => "open"}

        assert {:error, reason} =
                 Rest.get_order(@credentials, "o-1", @account ++ opts(plug: responding(body)))

        assert reason == {:missing_required_field, :id}
      end
    end

    test "a state, side or type outside the venue's words is refused, not decoded as nil" do
      for {field, value} <- [{"state", "teleported"}, {"side", "hold"}, {"type", "iceberg"}] do
        body = limit_order(%{field => value})
        atom = String.to_existing_atom(field)

        assert {:error, {:unknown_enum, ^atom, ^value}} =
                 Rest.get_order(@credentials, "o-1", @account ++ opts(plug: responding(body)))
      end
    end

    test "the same order id twice in one history is refused" do
      page = %{"results" => [limit_order(%{}), limit_order(%{})], "next" => nil}

      assert {:error, {:duplicate_order_id, "o-1"}} =
               Rest.get_orders(@credentials, @account ++ opts(plug: responding(page)))
    end

    test "an out-of-order history is returned in the order the venue sent it" do
      rows = [limit_order(%{"id" => "o-2"}), limit_order(%{"id" => "o-1"})]
      page = %{"results" => rows, "next" => nil}

      assert {:ok, orders} =
               Rest.get_orders(@credentials, @account ++ opts(plug: responding(page)))

      assert Enum.map(orders, & &1.id) == ["o-2", "o-1"]
    end
  end

  describe "get_orders/2: :limit is validated by the real path and by the fake alike" do
    test "anything but a positive integer is refused, and nothing is signed" do
      for bad <- [0, -1, 1.5, "10", :ten, [1]] do
        assert {:error, {:invalid_field, :limit}} =
                 Rest.get_orders(
                   @credentials,
                   @account ++ opts(plug: counting(self(), %{"results" => []}), limit: bad)
                 )

        assert Fake.get_orders(@credentials, @account ++ [limit: bad]) ==
                 {:error, {:invalid_field, :limit}}
      end

      refute_received {:request, _path, _query}
    end

    test "a positive integer, or none, or a forwarded nil is accepted by both" do
      for good <- [1, 50, nil] do
        assert {:ok, []} =
                 Rest.get_orders(
                   @credentials,
                   @account ++ opts(plug: responding(%{"results" => []}), limit: good)
                 )

        assert {:ok, []} = Fake.get_orders(@credentials, @account ++ [limit: good])
      end
    end

    test "the account option and the filters are checked before the limit, as in the fake" do
      missing = {:error, {:missing_option, :account_number}}

      assert Rest.get_orders(@credentials, limit: 0) == missing
      assert Fake.get_orders(@credentials, limit: 0) == missing

      assert Rest.get_orders(@credentials, @account ++ [side: :up, limit: 0]) ==
               {:error, {:invalid_field, :side}}

      assert Fake.get_orders(@credentials, @account ++ [side: :up, limit: 0]) ==
               {:error, {:invalid_field, :side}}
    end
  end

  describe "get_top_of_book/3: a book that cannot be one" do
    defp book(bid, ask) do
      %{"results" => [%{"symbol" => "BTC-USD", "bid" => bid, "ask" => ask}]}
    end

    defp top_of_book(bid, ask) do
      Rest.get_top_of_book("BTC-USD", @credentials, opts(plug: responding(book(bid, ask))))
    end

    test "a bid above the ask is refused" do
      assert {:error, {:crossed_book, "5", "4"}} = top_of_book("5", "4")
    end

    test "a locked book (bid equal to ask) is still a book" do
      assert {:ok, %{bid: bid, ask: ask}} = top_of_book("4", "4")
      assert Decimal.equal?(bid, ask)
    end

    test "the bulk read drops a crossed row and keeps the others" do
      body = %{
        "results" => [
          %{"symbol" => "BTC-USD", "bid" => "9", "ask" => "1"},
          %{"symbol" => "ETH-USD", "bid" => "1", "ask" => "2"}
        ]
      }

      assert {:ok, [%{symbol: "ETH-USD"}]} =
               Rest.get_top_of_book_bulk(
                 ["BTC-USD", "ETH-USD"],
                 @credentials,
                 opts(plug: responding(body))
               )
    end

    test "a wrong type, a huge exponent or an empty string on a side is refused" do
      for {bid, ask, side} <- [
            {[1], "2", :bid},
            {"1", %{"x" => 1}, :ask},
            {"1E5000", "2", :bid},
            {"1", "", :ask},
            {true, "2", :bid}
          ] do
        assert {:error, {:invalid_decimal, ^side, _raw}} = top_of_book(bid, ask)
      end
    end

    test "a row for another symbol is not this symbol's book" do
      body = %{"results" => [%{"symbol" => "ETH-USD", "bid" => "1", "ask" => "2"}]}

      assert {:error, :symbol_not_in_response} =
               Rest.get_top_of_book("BTC-USD", @credentials, opts(plug: responding(body)))
    end

    test "results out of order still finds the row that names the symbol asked for" do
      body = %{
        "results" => [
          %{"symbol" => "ETH-USD", "bid" => "3", "ask" => "4"},
          %{"symbol" => "BTC-USD", "bid" => "1", "ask" => "2"}
        ]
      }

      assert {:ok, %{symbol: "BTC-USD", bid: bid}} =
               Rest.get_top_of_book("BTC-USD", @credentials, opts(plug: responding(body)))

      assert Decimal.equal?(bid, 1)
    end
  end

  describe "get_estimated_price/5: a number that is not a cost" do
    defp estimate(row) do
      body = %{"results" => [Map.put(row, "symbol", "BTC-USD")]}

      Rest.get_estimated_price("BTC-USD", "ask", "1", @credentials, opts(plug: responding(body)))
    end

    test "a negative quantity, price, ratio or cost is refused, as text or as a number" do
      for key <- ~w(quantity bid ask fee_ratio est_fee est_total_cost est_total_credit),
          bad <- ["-1", -1, -0.5] do
        assert {:error, {:invalid_decimal, ^key, _raw}} = estimate(%{key => bad})
      end
    end

    test "zero is still stated: a free estimate and an empty side are not negative" do
      assert {:ok, %{"results" => [row]}} = estimate(%{"est_fee" => 0, "bid" => "0"})
      assert Decimal.equal?(row["est_fee"], 0)
      assert row["bid"] == "0"
    end

    test "a huge exponent is not a number, and a row that is not an object refuses the answer" do
      assert {:error, {:invalid_decimal, "ask", _raw}} = estimate(%{"ask" => "1E5000"})

      for row <- [7, "x", [1], nil] do
        assert {:error, :unexpected_response_shape} =
                 Rest.get_estimated_price(
                   "BTC-USD",
                   "ask",
                   "1",
                   @credentials,
                   opts(plug: responding(%{"results" => [row]}))
                 )
      end
    end

    test "an improper quantity list is refused, not raised on" do
      assert Rest.estimate_request("BTC-USD", :ask, [1 | 2]) ==
               {:error, {:invalid_field, :quantity}}
    end
  end

  describe "Fake.get_estimated_price/5 answers what Rest.get_estimated_price/5 answers" do
    @bad_requests [
      {"", :ask, "1"},
      {"   ", :ask, "1"},
      {5, :ask, "1"},
      {nil, :ask, "1"},
      {"BTC-USD", :sideways, "1"},
      {"BTC-USD", nil, "1"},
      {"BTC-USD", "ASK", "1"},
      {"BTC-USD", :ask, "0"},
      {"BTC-USD", :ask, "-1"},
      {"BTC-USD", :ask, "NaN"},
      {"BTC-USD", :ask, "abc"},
      {"BTC-USD", :ask, nil},
      {"BTC-USD", :ask, []},
      {"BTC-USD", :ask, ["1", "0"]},
      {"BTC-USD", :ask, [1 | 2]},
      {"BTC-USD", :ask, "1E999999999"}
    ]

    for {{symbol, side, quantity}, index} <- Enum.with_index(@bad_requests) do
      test "#{index}: a bad estimate request is refused identically, unsent" do
        request = unquote(Macro.escape({symbol, side, quantity}))
        {symbol, side, quantity} = request
        plug = counting(self(), %{"results" => []})

        real = Rest.get_estimated_price(symbol, side, quantity, @credentials, opts(plug: plug))

        assert {:error, _reason} = real
        assert Fake.get_estimated_price(symbol, side, quantity, @credentials) == real
        refute_received {:request, _path, _query}
      end
    end

    test "the request is checked before the credentials, as the real path checks it" do
      assert Fake.get_estimated_price("BTC-USD", :sideways, "1", %{}) ==
               {:error, {:unsupported_side, :sideways}}

      assert Fake.get_estimated_price("BTC-USD", :ask, "1", %{}) ==
               {:error, {:missing_credentials, :robinhood}}

      assert Fake.get_estimated_price("BTC-USD", :ask, "1", nil) ==
               Rest.get_estimated_price("BTC-USD", :ask, "1", nil, opts(plug: responding(%{})))
    end

    test "a symbol the fake does not list is the one spelling of not listed" do
      assert Fake.get_estimated_price("NOPE-USD", :ask, "1", @credentials) ==
               {:refused, :not_listed}
    end

    test "a listed symbol answers one row per quantity, as Decimal, under the canonical symbol" do
      assert {:ok, %{"results" => [first, second]}} =
               Fake.get_estimated_price("btc-usd", "both", ["0.1", 1], @credentials)

      assert first["symbol"] == "BTC-USD"
      assert first["side"] == "both"
      assert Decimal.equal?(first["quantity"], Decimal.new("0.1"))
      assert Decimal.equal?(second["quantity"], 1)
      assert Decimal.lt?(first["bid"], first["ask"])

      # No fee figure the fake could only have invented.
      refute Map.has_key?(first, "est_fee")
    end

    test "a single quantity, as a Decimal, answers one row" do
      assert {:ok, %{"results" => [row]}} =
               Fake.get_estimated_price("ETH-USD", :ask, Decimal.new("2.5"), @credentials)

      assert Decimal.equal?(row["quantity"], Decimal.new("2.5"))
    end
  end
end
