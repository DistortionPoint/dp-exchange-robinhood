defmodule DpExchange.Robinhood.TradingTest do
  @moduledoc """
  The v2 account, holdings and trading surface — the whole of it.

  **This package could not trade a venue that can be traded.** `place_order/3` was declared
  `:unsupported` on a broker whose documentation publishes it, which the inventory called
  the sharpest single consequence of the coverage gap anywhere in the family. This closes
  it.

  Two things about v2 in particular are asserted because they are what a v1 habit gets
  wrong. **`account_number` is a required query parameter** on holdings, on the order list,
  on one order and on placing one, where v1 took none — a call without it is not a smaller
  answer, it is a rejection. And **`estimated_price` moved from `marketdata` to `trading`**
  between the versions, so a package pointed at the old path gets a 404 that reads like an
  outage.

  The third is `client_order_id`: the venue treats it as an idempotency key, so a retry of
  a request whose response was never seen must reuse the same one rather than mint a new
  one and place a second order.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.{Config, Types}
  alias DpExchange.Robinhood.{Fake, Rest}

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

  @credentials %{api_key: "rh-key", private_key: Base.encode64(:crypto.strong_rand_bytes(32))}

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp capturing(body, test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, conn.query_string, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  describe "the account is the prerequisite for everything else" do
    test "it reads v2's own path" do
      me = self()

      assert {:ok, [account]} =
               Rest.get_accounts(@credentials,
                 plug: capturing(%{"account_number" => "RH-1"}, me),
                 retry_attempts: 0
               )

      assert account["account_number"] == "RH-1"
      assert_receive {:request, "GET", "/api/v2/crypto/trading/accounts/", "", _raw}
    end

    test "every account-scoped call refuses without the account number" do
      # v1 took none and answered for the credential's own account, so a call without one is
      # a v1 habit that v2 will not honour.
      assert {:error, {:account_number_required, :robinhood}} =
               Rest.get_balances(@credentials, [])

      assert {:error, {:account_number_required, :robinhood}} =
               Rest.get_orders(@credentials, [])

      assert {:error, {:account_number_required, :robinhood}} =
               Rest.get_order(@credentials, "o-1", [])

      assert {:error, {:account_number_required, :robinhood}} =
               Rest.place_order(@credentials, %{}, [])
    end
  end

  describe "holdings" do
    test "total and available are separate, and hold is nil" do
      # The difference between them is a balance sitting in an open order. `hold` stays nil
      # because the venue publishes no such figure — subtracting would state a number it
      # never did.
      body = %{
        "results" => [
          %{
            "asset_code" => "BTC",
            "total_quantity" => "1.5",
            "quantity_available_for_trading" => "1.0"
          }
        ]
      }

      assert {:ok, [balance]} =
               Rest.get_balances(@credentials,
                 account_number: "RH-1",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert %Types.Balance{currency: "BTC"} = balance
      assert Decimal.equal?(balance.balance, Decimal.new("1.5"))
      assert Decimal.equal?(balance.available_balance, Decimal.new("1.0"))
      assert balance.hold == nil
    end

    test "the asset filter is repeated per code, as the venue takes it" do
      me = self()

      assert {:ok, []} =
               Rest.get_balances(@credentials,
                 account_number: "RH-1",
                 asset_codes: ["BTC", "ETH"],
                 plug: capturing(%{"results" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/api/v2/crypto/trading/holdings/"
      assert query =~ "account_number=RH-1"
      assert query =~ "asset_code=BTC"
      assert query =~ "asset_code=ETH"
    end
  end

  describe "estimated price — the third price, and the one that moved" do
    test "it reaches trading, not marketdata" do
      # A package pointed at v1's path gets a 404 that reads like an outage.
      me = self()

      assert {:ok, _estimate} =
               Rest.get_estimated_price("BTC-USD", "ask", "0.1", @credentials,
                 plug: capturing(%{"results" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/api/v2/crypto/trading/estimated_price/"
      refute path =~ "marketdata"
      assert query =~ "side=ask"
      assert query =~ "quantity=0.1"
    end

    test "several quantities go in one request, which is how a caller sees the slope" do
      me = self()

      assert {:ok, _estimate} =
               Rest.get_estimated_price(
                 "BTC-USD",
                 "both",
                 [Decimal.new("0.1"), Decimal.new("1"), Decimal.new("10")],
                 @credentials,
                 plug: capturing(%{}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", _path, query, _raw}
      assert query =~ "quantity=0.1%2C1%2C10"
    end

    test "a small quantity is sent in full notation" do
      me = self()

      assert {:ok, _estimate} =
               Rest.get_estimated_price(
                 "BTC-USD",
                 "ask",
                 Decimal.new("0.00000001"),
                 @credentials,
                 plug: capturing(%{}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", _path, query, _raw}
      assert query =~ "quantity=0.00000001"
    end
  end

  describe "placing an order" do
    test "the config goes under a key named after the order's own type" do
      # A config under the wrong key is silently ignored and the order is placed with none.
      me = self()

      assert {:ok, _order} =
               Rest.place_order(
                 @credentials,
                 %{
                   symbol: "BTC-USD",
                   side: :buy,
                   order_type: :market,
                   quantity: Decimal.new("0.5")
                 },
                 account_number: "RH-1",
                 plug: capturing(%{"id" => "o-1", "state" => "open"}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", path, query, raw}
      assert path == "/api/v2/crypto/trading/orders/"
      assert query == "account_number=RH-1"

      body = Jason.decode!(raw)
      assert body["type"] == "market"
      assert body["market_order_config"] == %{"asset_quantity" => "0.5"}
      refute Map.has_key?(body, "limit_order_config")
    end

    test "a limit order carries its price in its own config" do
      me = self()

      assert {:ok, _order} =
               Rest.place_order(
                 @credentials,
                 %{
                   symbol: "BTC-USD",
                   side: :sell,
                   order_type: :limit,
                   quantity: Decimal.new("0.5"),
                   price: Decimal.new("60000")
                 },
                 account_number: "RH-1",
                 plug: capturing(%{"id" => "o-2"}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", _path, _query, raw}

      assert Jason.decode!(raw)["limit_order_config"] == %{
               "asset_quantity" => "0.5",
               "limit_price" => "60000"
             }
    end

    test "a limit without a price is refused by field name, before the request" do
      assert {:error, {:missing_field, :price}} =
               Rest.place_order(
                 @credentials,
                 %{symbol: "BTC-USD", side: :buy, order_type: :limit, quantity: Decimal.new("1")},
                 account_number: "RH-1"
               )
    end

    test "a stop-limit needs both prices" do
      assert {:error, {:missing_field, :stop_price}} =
               Rest.place_order(
                 @credentials,
                 %{
                   symbol: "BTC-USD",
                   side: :buy,
                   order_type: :stop_limit,
                   quantity: Decimal.new("1"),
                   price: Decimal.new("60000")
                 },
                 account_number: "RH-1"
               )
    end

    test "an order type the venue does not serve is named back" do
      assert {:error, {:unsupported_order_type, :trailing_stop}} =
               Rest.place_order(
                 @credentials,
                 %{
                   symbol: "BTC-USD",
                   side: :buy,
                   order_type: :trailing_stop,
                   quantity: Decimal.new("1")
                 },
                 account_number: "RH-1"
               )
    end

    test "a limit order's time_in_force rides in its own config, as the vendor's schema takes it" do
      # `AddOrderV2.limit_order_config` carries `time_in_force` — a real field, not one
      # invented here.
      me = self()

      assert {:ok, _order} =
               Rest.place_order(
                 @credentials,
                 %{
                   symbol: "BTC-USD",
                   side: :sell,
                   order_type: :limit,
                   quantity: Decimal.new("0.5"),
                   price: Decimal.new("60000"),
                   time_in_force: :gtc
                 },
                 account_number: "RH-1",
                 plug: capturing(%{"id" => "o-3"}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", _path, _query, raw}

      assert Jason.decode!(raw)["limit_order_config"] == %{
               "asset_quantity" => "0.5",
               "limit_price" => "60000",
               "time_in_force" => "gtc"
             }
    end

    test "the venue's :day is sent as gfd — that is its own name for it" do
      me = self()

      assert {:ok, _order} =
               Rest.place_order(
                 @credentials,
                 %{
                   symbol: "BTC-USD",
                   side: :buy,
                   order_type: :stop_loss,
                   quantity: Decimal.new("1"),
                   stop_price: Decimal.new("50000"),
                   time_in_force: :day
                 },
                 account_number: "RH-1",
                 plug: capturing(%{"id" => "o-4"}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", _path, _query, raw}
      assert Jason.decode!(raw)["stop_loss_order_config"]["time_in_force"] == "gfd"
    end

    test "no time_in_force means no key at all, not a default" do
      me = self()

      assert {:ok, _order} =
               Rest.place_order(
                 @credentials,
                 %{
                   symbol: "BTC-USD",
                   side: :buy,
                   order_type: :limit,
                   quantity: Decimal.new("1"),
                   price: Decimal.new("50000")
                 },
                 account_number: "RH-1",
                 plug: capturing(%{"id" => "o-5"}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", _path, _query, raw}
      refute Map.has_key?(Jason.decode!(raw)["limit_order_config"], "time_in_force")
    end

    test "a time_in_force this venue cannot honour is refused, not silently dropped" do
      # Core's vocabulary has :ioc — a real atom this venue has no wire name for. Silently
      # omitting it would place a GTC-equivalent order under a caller's IOC instruction.
      assert {:error, {:unsupported_time_in_force, :ioc}} =
               Rest.place_order(
                 @credentials,
                 %{
                   symbol: "BTC-USD",
                   side: :buy,
                   order_type: :limit,
                   quantity: Decimal.new("1"),
                   price: Decimal.new("50000"),
                   time_in_force: :ioc
                 },
                 account_number: "RH-1"
               )
    end

    test "market orders have no time_in_force slot on the vendor's schema, and none is sent" do
      me = self()

      assert {:ok, _order} =
               Rest.place_order(
                 @credentials,
                 %{
                   symbol: "BTC-USD",
                   side: :buy,
                   order_type: :market,
                   quantity: Decimal.new("1"),
                   time_in_force: :gtc
                 },
                 account_number: "RH-1",
                 plug: capturing(%{"id" => "o-6"}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", _path, _query, raw}
      refute Map.has_key?(Jason.decode!(raw)["market_order_config"], "time_in_force")
    end

    test "a client order id is generated when absent and honoured when given" do
      # The venue treats it as an idempotency key: a retry of a request whose response was
      # never seen must reuse the same one rather than place a second order.
      me = self()

      order = %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: Decimal.new("1")}

      assert {:ok, _first} =
               Rest.place_order(@credentials, order,
                 account_number: "RH-1",
                 plug: capturing(%{"id" => "o-1"}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", _path, _query, raw}
      generated = Jason.decode!(raw)["client_order_id"]
      assert generated =~ ~r/^[0-9a-f-]{36}$/

      assert {:ok, _second} =
               Rest.place_order(@credentials, order,
                 account_number: "RH-1",
                 client_order_id: generated,
                 plug: capturing(%{"id" => "o-1"}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", _path, _query, raw2}
      assert Jason.decode!(raw2)["client_order_id"] == generated
    end

    test "two generated ids differ" do
      me = self()
      order = %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: Decimal.new("1")}

      for _attempt <- 1..2 do
        assert {:ok, _order} =
                 Rest.place_order(@credentials, order,
                   account_number: "RH-1",
                   plug: capturing(%{"id" => "o"}, me),
                   retry_attempts: 0
                 )
      end

      assert_receive {:request, "POST", _p1, _q1, first}
      assert_receive {:request, "POST", _p2, _q2, second}
      assert Jason.decode!(first)["client_order_id"] != Jason.decode!(second)["client_order_id"]
    end
  end

  describe "reading and cancelling orders" do
    test "an order's state maps to the contract's status" do
      # Shaped like the vendor's real `OrderResponse`/`V2CryptoOrder`: `limit_order_config`
      # carries `time_in_force` and `fee_charged` sits on the row itself, per Robinhood's
      # own OpenAPI schema — this used to be built with neither, which is the same wrong
      # assumption the code made.
      body = %{
        "id" => "o-1",
        "symbol" => "BTC-USD",
        "side" => "buy",
        "type" => "limit",
        "state" => "partially_filled",
        "filled_asset_quantity" => "0.25",
        "average_price" => "60000",
        "created_at" => "2026-09-01T12:00:00Z",
        "fee_charged" => "0.15",
        "estimated_fee_remaining" => "0.05",
        "limit_order_config" => %{
          "asset_quantity" => "0.5",
          "limit_price" => "60000",
          "time_in_force" => "gtc"
        }
      }

      assert {:ok, order} =
               Rest.get_order(@credentials, "o-1",
                 account_number: "RH-1",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert %Types.Order{} = order
      assert order.status == :partially_filled
      assert order.side == :buy
      assert order.order_type == :limit
      assert order.symbol == "BTC-USD"
      assert order.time_in_force == :gtc
      assert Decimal.equal?(order.fee, Decimal.new("0.15"))
      # The vendor's schema does not state a currency for `fee_charged` — not assumed to be
      # the quote currency.
      assert order.fee_currency == nil
    end

    test "the venue's gfd decodes to Core's :day, the closest real match" do
      body = %{
        "id" => "o-1",
        "state" => "open",
        "type" => "stop_loss",
        "stop_loss_order_config" => %{
          "asset_quantity" => "0.5",
          "stop_price" => "1000",
          "time_in_force" => "gfd"
        }
      }

      assert {:ok, order} =
               Rest.get_order(@credentials, "o-1",
                 account_number: "RH-1",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert order.time_in_force == :day
    end

    for wire <- ["gfw", "gfm"] do
      test "the venue's #{wire} decodes to nil — Core has no atom for it yet" do
        body = %{
          "id" => "o-1",
          "state" => "open",
          "type" => "limit",
          "limit_order_config" => %{
            "asset_quantity" => "0.5",
            "limit_price" => "1000",
            "time_in_force" => unquote(wire)
          }
        }

        assert {:ok, order} =
                 Rest.get_order(@credentials, "o-1",
                   account_number: "RH-1",
                   plug: responding(body),
                   retry_attempts: 0
                 )

        assert order.time_in_force == nil
      end
    end

    test "a market order's row carries no time_in_force, decoded honestly as nil" do
      body = %{
        "id" => "o-1",
        "state" => "open",
        "type" => "market",
        "market_order_config" => %{"asset_quantity" => "0.5"}
      }

      assert {:ok, order} =
               Rest.get_order(@credentials, "o-1",
                 account_number: "RH-1",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert order.time_in_force == nil
      assert order.fee == nil
    end

    for {venue, expected} <- [
          {"open", :open},
          {"partially_filled", :partially_filled},
          {"filled", :filled},
          {"canceled", :cancelled},
          {"failed", :rejected}
        ] do
      test "state #{venue} maps to #{expected}" do
        body = %{"id" => "o-1", "state" => unquote(venue)}

        assert {:ok, order} =
                 Rest.get_order(@credentials, "o-1",
                   account_number: "RH-1",
                   plug: responding(body),
                   retry_attempts: 0
                 )

        assert order.status == unquote(expected)
      end
    end

    test "a state this package does not know is nil, never the nearest" do
      # A caller branching on :filled must not be handed it for a word that looked close.
      body = %{"id" => "o-1", "state" => "pending_settlement"}

      assert {:ok, order} =
               Rest.get_order(@credentials, "o-1",
                 account_number: "RH-1",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert order.status == nil
    end

    test "an unfilled order's quantity comes from its own config" do
      body = %{
        "id" => "o-1",
        "state" => "open",
        "type" => "limit",
        "limit_order_config" => %{"asset_quantity" => "0.5", "limit_price" => "60000"}
      }

      assert {:ok, order} =
               Rest.get_order(@credentials, "o-1",
                 account_number: "RH-1",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(order.quantity, Decimal.new("0.5"))
    end

    test "the order list sends its filters under the venue's own names" do
      me = self()

      assert {:ok, []} =
               Rest.get_orders(@credentials,
                 account_number: "RH-1",
                 created_at_start: "2026-08-01T00:00:00Z",
                 symbol: "BTC-USD",
                 state: "open",
                 plug: capturing(%{"results" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/api/v2/crypto/trading/orders/"
      assert query =~ "created_at_start=2026-08-01T00%3A00%3A00Z"
      assert query =~ "symbol=BTC-USD"
      assert query =~ "state=open"
    end

    test "cancelling is a POST at its own path and takes no account number" do
      me = self()

      assert {:ok, _result} =
               Rest.cancel_order(@credentials, "o-1",
                 plug: capturing(%{"cancel_requested" => true}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", path, query, _raw}
      assert path == "/api/v2/crypto/trading/orders/o-1/cancel/"
      assert query == ""
    end

    test "a refusal on a write is a refusal, not an error" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          400,
          Jason.encode!(%{"errors" => [%{"detail" => "insufficient funds"}]})
        )
      end

      assert {:refused, _reason} =
               Rest.place_order(
                 @credentials,
                 %{
                   symbol: "BTC-USD",
                   side: :buy,
                   order_type: :market,
                   quantity: Decimal.new("1")
                 },
                 account_number: "RH-1",
                 plug: plug,
                 retry_attempts: 0
               )
    end
  end

  describe "the fake and the facade" do
    test "the fake's holdings show a balance held in an open order" do
      assert {:ok, [balance]} = Fake.get_balances(%{}, account_number: "RH-1")
      refute Decimal.equal?(balance.balance, balance.available_balance)
      assert balance.hold == nil
    end

    test "the fake's placed order is open, not filled" do
      assert {:ok, order} =
               Fake.place_order(
                 %{},
                 %{
                   symbol: "BTC-USD",
                   side: :buy,
                   order_type: :market,
                   quantity: Decimal.new("1")
                 },
                 account_number: "RH-1"
               )

      assert order.status == :open
      assert Decimal.equal?(order.filled_quantity, Decimal.new("0"))
    end

    test "the facade reaches the whole surface" do
      base = [credentials: @credentials, account_number: "RH-1", retry_attempts: 0]

      assert {:ok, [_account]} =
               DpExchange.Robinhood.get_accounts(
                 @credentials,
                 base ++ [plug: responding(%{"account_number" => "RH-1"})]
               )

      assert {:ok, []} =
               DpExchange.Robinhood.get_balances(
                 @credentials,
                 base ++ [plug: responding(%{"results" => []})]
               )

      assert {:ok, _order} =
               DpExchange.Robinhood.place_order(
                 @credentials,
                 %{
                   symbol: "BTC-USD",
                   side: :buy,
                   order_type: :market,
                   quantity: Decimal.new("1")
                 },
                 base ++ [plug: responding(%{"id" => "o-1"})]
               )

      assert {:ok, _order} =
               DpExchange.Robinhood.get_order(
                 @credentials,
                 "o-1",
                 base ++ [plug: responding(%{"id" => "o-1"})]
               )

      assert {:ok, []} =
               DpExchange.Robinhood.get_orders(
                 @credentials,
                 base ++ [plug: responding(%{"results" => []})]
               )

      assert {:ok, _cancelled} =
               DpExchange.Robinhood.cancel_order(
                 @credentials,
                 "o-1",
                 base ++ [plug: responding(%{"cancel_requested" => true})]
               )

      assert {:ok, _estimate} =
               DpExchange.Robinhood.get_estimated_price(
                 "BTC-USD",
                 "ask",
                 "0.1",
                 @credentials,
                 base ++ [plug: responding(%{})]
               )
    end
  end

  describe "the v1 to v2 migration" do
    test "market data reads v2's best_bid_ask" do
      # D5 makes v2 the surface. The package shipped these two on v1, which is why their
      # boxes stayed open in the coverage plan even though the functions existed.
      me = self()

      body = %{
        "results" => [
          %{
            "symbol" => "BTC-USD",
            "price" => "60000",
            "bid_inclusive_of_sell_spread" => "59990",
            "ask_inclusive_of_buy_spread" => "60010",
            "timestamp" => "2026-09-01T12:00:00Z"
          }
        ]
      }

      assert {:ok, _book} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", "/api/v2/crypto/marketdata/best_bid_ask/", _q, _r}
    end

    test "the catalogue reads v2's trading_pairs" do
      me = self()

      assert {:ok, _symbols} =
               Rest.get_symbols(@credentials,
                 plug: capturing(%{"results" => [%{"symbol" => "BTC-USD"}]}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", "/api/v2/crypto/trading/trading_pairs/", _q, _r}
    end

    test "no v1 path is left in the code" do
      # A path is the one thing in an HTTP call that cannot be verified by reading the
      # response: a v1 path still works, and would leave this package on a surface the
      # coverage plan says it has migrated off.
      source =
        File.read!(
          Path.join([__DIR__, "..", "..", "..", "lib"])
          |> Path.expand()
          |> Path.join("dp_exchange/robinhood/rest.ex")
        )

      refute source =~ "/api/v1/"
    end
  end
end
