defmodule DpExchange.Robinhood.RequestIntegrityTest do
  @moduledoc """
  What is signed and sent is exactly what the caller meant, and a cursor from the venue is
  checked before it is followed.

  Each case here is a request or a page that used to be accepted and carried on: an order id
  that rewrote the signed path, a quantity of `"NaN"` in a signed order body, a `next` on
  another host, a first page of accounts standing in for all of them.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Robinhood.{Auth, Fake, Rest}

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
  @account [account_number: "RH-1"]
  @market %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: Decimal.new("0.5")}
  @base "https://trading.robinhood.com/api/v2/crypto/trading"

  # Answers `body` and tells the test every request that got this far.
  defp hitting(body, test_pid, status \\ 200) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:hit, conn.method, conn.request_path, conn.query_string, raw,
         Plug.Conn.get_req_header(conn, "content-type")}
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  describe "Auth.headers/5 with a forwarded timestamp: nil" do
    test "signs with the clock, rather than an empty x-timestamp" do
      assert {:ok, headers} = Auth.headers("GET", "/p", "", @credentials, timestamp: nil)
      {"x-timestamp", timestamp} = List.keyfind(headers, "x-timestamp", 0)
      assert timestamp =~ ~r/^\d{10}$/
    end
  end

  describe "an order id is one path segment" do
    test "get_order/3 percent-encodes reserved characters instead of rewriting the path" do
      plug = hitting(%{"id" => "x"}, self())

      assert {:ok, _order} =
               Rest.get_order(@credentials, "x/cancel/?y=1",
                 account_number: "RH-1",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:hit, "GET", path, query, _raw, _content_type}
      refute path =~ "x/cancel/"
      assert query == "account_number=RH-1"
    end

    test "cancel_order/3 does the same, and signs the path it sends" do
      plug = hitting(%{"id" => "x"}, self())

      assert {:ok, _order} =
               Rest.cancel_order(@credentials, "a/b#c", plug: plug, retry_attempts: 0)

      assert_receive {:hit, "POST", path, query, _raw, _content_type}
      refute path =~ "a/b"
      assert query == ""
    end

    test "a blank id is refused before anything is sent" do
      plug = hitting(%{"id" => "x"}, self())

      for blank <- ["", "  "] do
        assert {:error, {:missing_field, :id}} =
                 Rest.cancel_order(@credentials, blank, plug: plug, retry_attempts: 0)

        assert {:error, {:missing_field, :id}} =
                 Rest.get_order(@credentials, blank,
                   account_number: "RH-1",
                   plug: plug,
                   retry_attempts: 0
                 )
      end

      refute_received {:hit, _method, _path, _query, _raw, _content_type}
    end

    test "the fake refuses a blank id as the real path does" do
      assert Fake.cancel_order(@credentials, "", []) == {:error, {:missing_field, :id}}
      assert Fake.get_order(@credentials, " ", @account) == {:error, {:missing_field, :id}}
    end
  end

  describe "a symbol is one query value" do
    test "get_top_of_book/3 cannot be made to carry a second parameter" do
      plug = hitting(%{"results" => []}, self())

      _result =
        Rest.get_top_of_book("BTC-USD&symbol=ETH-USD", @credentials,
          plug: plug,
          retry_attempts: 0
        )

      assert_receive {:hit, "GET", _path, query, _raw, _content_type}
      assert [{"symbol", _one_value}] = URI.query_decoder(query) |> Enum.to_list()
    end

    test "quantization/3 cannot either" do
      plug = hitting(%{"results" => []}, self())

      _result =
        Rest.quantization("BTC-USD#x", @credentials, plug: plug, retry_attempts: 0)

      assert_receive {:hit, "GET", _path, query, _raw, _content_type}
      assert [{"symbol", _one_value}] = URI.query_decoder(query) |> Enum.to_list()
    end
  end

  describe "a signed POST carries what the vendor's client carries" do
    test "an order body travels as application/json" do
      plug = hitting(%{"id" => "o-1"}, self())

      assert {:ok, _order} =
               Rest.place_order(@credentials, @market,
                 account_number: "RH-1",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:hit, "POST", _path, _query, raw, ["application/json"]}
      assert %{"market_order_config" => %{"asset_quantity" => "0.5"}} = Jason.decode!(raw)
    end

    test "a cancel sends no body and no content type, and signs the empty string" do
      plug = hitting(%{"id" => "o-1"}, self())

      assert {:ok, _order} =
               Rest.cancel_order(@credentials, "o-1", plug: plug, retry_attempts: 0)

      assert_receive {:hit, "POST", _path, _query, "", []}
    end
  end

  describe "place_order/3 refuses what it would otherwise sign and send" do
    test "a side outside buy/sell" do
      assert {:error, {:unsupported_side, :hold}} = place(%{@market | side: :hold})
      assert {:error, {:unsupported_side, "BUY"}} = place(%{@market | side: "BUY"})
      refute_received {:hit, _method, _path, _query, _raw, _content_type}
    end

    test "a quantity that is not a positive finite number" do
      unreadable = ["0", "-1", "NaN", "Infinity", "abc", "", 0, -2, 0.0, Decimal.new("-1")]

      for bad <- unreadable do
        assert {:error, {:invalid_field, :quantity}} = place(%{@market | quantity: bad})
      end

      assert {:error, {:missing_field, :quantity}} = place(%{@market | quantity: nil})

      refute_received {:hit, _method, _path, _query, _raw, _content_type}
    end

    test "a price or stop price that is not a positive finite number" do
      limit = %{@market | order_type: :limit}
      assert {:error, {:invalid_field, :price}} = place(Map.put(limit, :price, "0"))
      assert {:error, {:invalid_field, :price}} = place(Map.put(limit, :price, "NaN"))

      stop = %{@market | order_type: :stop}
      assert {:error, {:invalid_field, :stop_price}} = place(Map.put(stop, :stop_price, -1))
      refute_received {:hit, _method, _path, _query, _raw, _content_type}
    end

    test "a symbol that is blank or not a string" do
      assert {:error, {:invalid_field, :symbol}} = place(%{@market | symbol: ""})
      assert {:error, {:invalid_field, :symbol}} = place(%{@market | symbol: 5})
      refute_received {:hit, _method, _path, _query, _raw, _content_type}
    end

    test "a request that is not a map" do
      assert {:error, {:invalid_request, :not_a_map}} = place("BTC-USD")
      assert Rest.validate_order_request(nil) == {:error, {:invalid_request, :not_a_map}}
      refute_received {:hit, _method, _path, _query, _raw, _content_type}
    end

    test "the fake refuses exactly the same orders" do
      for request <- [
            %{@market | side: :hold},
            %{@market | quantity: "NaN"},
            %{@market | quantity: 0},
            %{@market | symbol: ""}
          ] do
        assert {:error, _reason} = expected = Rest.validate_order_request(request)
        assert Fake.place_order(@credentials, request, @account) == expected
      end
    end

    test "a string quantity in scientific notation is sent in full notation" do
      plug = hitting(%{"id" => "o-1"}, self())

      assert {:ok, _order} =
               Rest.place_order(@credentials, %{@market | quantity: "1e-5"},
                 account_number: "RH-1",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:hit, "POST", _path, _query, raw, _content_type}
      assert Jason.decode!(raw)["market_order_config"]["asset_quantity"] == "0.00001"
    end

    defp place(request) do
      Rest.place_order(@credentials, request,
        account_number: "RH-1",
        plug: hitting(%{"id" => "o-1"}, self()),
        retry_attempts: 0
      )
    end
  end

  describe "the fake's placed order is what the real path would decode" do
    test "canonical symbol, Decimal amounts, :stop for stop_loss, its own fields only" do
      request = %{
        symbol: "btc-usd",
        side: "buy",
        order_type: :stop_loss,
        quantity: "0.5",
        stop_price: 100,
        time_in_force: :gtc
      }

      assert {:ok, order} = Fake.place_order(@credentials, request, @account)

      assert order.symbol == "BTC-USD"
      assert order.side == :buy
      assert order.order_type == :stop
      assert order.time_in_force == :gtc
      assert Decimal.equal?(order.quantity, Decimal.new("0.5"))
      assert Decimal.equal?(order.stop_price, Decimal.new("100"))
      assert order.price == nil
    end

    test "a limit order carries its price, and no time in force, as a real read does" do
      request = %{
        symbol: "BTC-USD",
        side: :sell,
        order_type: :limit,
        quantity: 0.25,
        price: "60000",
        time_in_force: :gtc
      }

      assert {:ok, order} = Fake.place_order(@credentials, request, @account)

      assert Decimal.equal?(order.quantity, Decimal.new("0.25"))
      assert Decimal.equal?(order.price, Decimal.new("60000"))
      assert order.stop_price == nil
      assert order.time_in_force == nil
    end
  end

  describe "an order the venue calls pending" do
    test "decodes as Core's :pending, not as an unknown state" do
      plug = hitting(%{"id" => "o-1", "state" => "pending"}, self())

      assert {:ok, order} =
               Rest.get_order(@credentials, "o-1",
                 account_number: "RH-1",
                 plug: plug,
                 retry_attempts: 0
               )

      assert order.status == :pending
    end
  end

  describe "get_orders/2's type filter" do
    test "the contract's :stop is the venue's stop_loss" do
      plug = hitting(%{"results" => [], "next" => nil}, self())

      assert {:ok, []} =
               Rest.get_orders(@credentials,
                 account_number: "RH-1",
                 type: :stop,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:hit, "GET", _path, query, _raw, _content_type}
      assert URI.decode_query(query)["type"] == "stop_loss"
    end
  end

  describe "a cursor is checked before it is followed" do
    defp paged(next, test_pid) do
      fn conn ->
        send(test_pid, {:hit, conn.request_path})
        Req.Test.json(conn, %{"results" => [%{"symbol" => "BTC-USD"}], "next" => next})
      end
    end

    test "a next on another host ends the walk with an error, and is never requested" do
      next = "https://evil.example.com/api/v2/crypto/trading/trading_pairs/?cursor=2"

      assert {:error, {:foreign_next_url, "evil.example.com"}} =
               Rest.get_symbols(@credentials, plug: paged(next, self()), retry_attempts: 0)

      assert_received {:hit, _first}
      refute_received {:hit, _second}
    end

    test "a next with no path is an error, not a crash" do
      assert {:error, {:unexpected_next_path, nil}} =
               Rest.get_symbols(@credentials,
                 plug: paged("?cursor=2", self()),
                 retry_attempts: 0
               )
    end

    test "a next outside /api/ is an error" do
      next = "https://trading.robinhood.com/elsewhere/?cursor=2"

      assert {:error, {:unexpected_next_path, "/elsewhere/"}} =
               Rest.get_symbols(@credentials, plug: paged(next, self()), retry_attempts: 0)
    end

    test "a next that is present but not a string is unreadable, not 'no more pages'" do
      for bad <- [5, %{"cursor" => "2"}, ["x"]] do
        assert {:error, :unexpected_response_shape} =
                 Rest.get_symbols(@credentials,
                   plug: paged(bad, self()),
                   retry_attempts: 0
                 )
      end
    end

    test "a relative next on this package's own base is followed" do
      me = self()

      plug = fn conn ->
        send(me, {:hit, conn.request_path, conn.query_string})

        if conn.query_string == "" do
          Req.Test.json(conn, %{
            "results" => [%{"symbol" => "BTC-USD"}],
            "next" => "/api/v2/crypto/trading/trading_pairs/?cursor=2"
          })
        else
          Req.Test.json(conn, %{"results" => [%{"symbol" => "ETH-USD"}], "next" => nil})
        end
      end

      assert {:ok, ["BTC-USD", "ETH-USD"]} =
               Rest.get_symbols(@credentials, plug: plug, retry_attempts: 0)
    end
  end

  describe "get_accounts/2 walks every page" do
    defp account_pages(test_pid) do
      fn conn ->
        send(test_pid, {:page, conn.request_path, conn.query_string})

        cond do
          String.contains?(conn.request_path, "/holdings/") ->
            Req.Test.json(conn, %{"results" => [], "next" => nil})

          conn.query_string == "" ->
            first = %{
              "account_number" => "A1",
              "buying_power" => "1",
              "buying_power_currency" => "USD"
            }

            Req.Test.json(conn, %{
              "results" => [first],
              "next" => @base <> "/accounts/?cursor=2"
            })

          true ->
            Req.Test.json(conn, %{
              "results" => [
                %{
                  "account_number" => "A2",
                  "buying_power" => "47.79",
                  "buying_power_currency" => "USD"
                }
              ],
              "next" => nil
            })
        end
      end
    end

    test "the second page's accounts are returned" do
      assert {:ok, [%{"account_number" => "A1"}, %{"account_number" => "A2"}]} =
               Rest.get_accounts(@credentials,
                 plug: account_pages(self()),
                 retry_attempts: 0
               )
    end

    test "get_balances/2 finds an account that is on the second page" do
      assert {:ok, [cash]} =
               Rest.get_balances(@credentials,
                 account_number: "A2",
                 plug: account_pages(self()),
                 retry_attempts: 0
               )

      assert Decimal.equal?(cash.available_balance, Decimal.new("47.79"))
    end

    test "a next pointing back at the first page is a loop, not a hang" do
      plug = fn conn ->
        Req.Test.json(conn, %{
          "results" => [%{"account_number" => "A1"}],
          "next" => @base <> "/accounts/"
        })
      end

      assert {:error, {:pagination_loop, "/api/v2/crypto/trading/accounts/"}} =
               Rest.get_accounts(@credentials, plug: plug, retry_attempts: 0)
    end

    test "a cursor that never repeats is bounded" do
      counter = :atomics.new(1, signed: false)

      plug = fn conn ->
        n = :atomics.add_get(counter, 1, 1)

        Req.Test.json(conn, %{
          "results" => [%{"account_number" => "A#{n}"}],
          "next" => @base <> "/accounts/?cursor=#{n}"
        })
      end

      assert {:error, :too_many_account_pages} =
               Rest.get_accounts(@credentials, plug: plug, retry_attempts: 0)

      assert :atomics.get(counter, 1) <= 50
    end

    test "a bare object is an account only if it names one" do
      for body <- [%{}, %{"detail" => "ok"}, %{"account_number" => ""}] do
        assert {:error, :unexpected_response_shape} =
                 Rest.get_accounts(@credentials,
                   plug: fn conn -> Req.Test.json(conn, body) end,
                   retry_attempts: 0
                 )
      end
    end
  end

  describe "get_estimated_price/5 refuses what it would otherwise sign and send" do
    defp estimate(side, quantity, symbol \\ "BTC-USD") do
      Rest.get_estimated_price(symbol, side, quantity, @credentials,
        plug: hitting(%{"results" => []}, self()),
        retry_attempts: 0
      )
    end

    test "a side outside bid/ask/both; atoms and strings are both accepted" do
      assert {:error, {:unsupported_side, "buy"}} = estimate("buy", "1")
      assert {:error, {:unsupported_side, nil}} = estimate(nil, "1")
      assert {:ok, _body} = estimate(:both, "1")
      assert_receive {:hit, "GET", _path, query, _raw, _content_type}
      assert URI.decode_query(query)["side"] == "both"
    end

    test "a quantity that is not a positive finite number, alone or in a list" do
      for bad <- ["0", "-1", "NaN", "abc", "", 0, nil, [], ["1", "0"], ["1", "x"]] do
        assert {:error, {:invalid_field, :quantity}} = estimate("ask", bad)
      end
    end

    test "a symbol that is not a string" do
      assert {:error, {:invalid_field, :symbol}} = estimate("ask", "1", nil)
      assert {:error, {:invalid_field, :symbol}} = estimate("ask", "1", "")
    end

    test "nothing was sent for any of them" do
      _refused = estimate("buy", "1")
      _refused = estimate("ask", "0")
      refute_received {:hit, _method, _path, _query, _raw, _content_type}
    end

    test "a body that is not an object is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_estimated_price("BTC-USD", "ask", "1", @credentials,
                 plug: fn conn -> Req.Test.json(conn, ["x"]) end,
                 retry_attempts: 0
               )
    end

    test "numbers in each row are Decimal, strings and other keys are untouched" do
      body = %{
        "results" => [%{"symbol" => "BTC-USD", "bid" => 0.1, "ask" => "2", "est_fee" => 3}]
      }

      assert {:ok, %{"results" => [row]}} =
               Rest.get_estimated_price("BTC-USD", "both", "1", @credentials,
                 plug: fn conn -> Req.Test.json(conn, body) end,
                 retry_attempts: 0
               )

      assert Decimal.equal?(row["bid"], Decimal.new("0.1"))
      assert Decimal.equal?(row["est_fee"], Decimal.new("3"))
      assert row["ask"] == "2"
      assert row["symbol"] == "BTC-USD"
    end
  end

  describe "quantization/3 with no readable increment" do
    test "is refused rather than answered as a rounding rule that states none" do
      row = %{
        "symbol" => "BTC-USD",
        "quote_increment" => "NaN",
        "asset_increment" => "",
        "max_order_size" => "100"
      }

      assert {:error, {:missing_required_field, :increments}} =
               Rest.quantization("BTC-USD", @credentials,
                 plug: fn conn -> Req.Test.json(conn, %{"results" => [row]}) end,
                 retry_attempts: 0
               )
    end
  end
end
