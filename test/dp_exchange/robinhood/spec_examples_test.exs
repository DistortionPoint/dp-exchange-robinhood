defmodule DpExchange.Robinhood.SpecExamplesTest do
  @moduledoc """
  Every endpoint this package calls, driven end to end from a fixture built strictly
  against the vendor's own committed OpenAPI document —
  `docs/reference/robinhood/openapi/crypto-trading.openapi.json` — never from a hand-typed
  body written to agree with `Rest`'s decoding.

  ## Why this suite exists, and what it is not

  This family's worst bugs have been fixtures that quietly drifted from the vendor: a
  passing test whose body was never real. The Robinhood v1/v2 `best_bid_ask` field-name
  defect (`Rest`'s own moduledoc) is the canonical instance — every hand-built fixture in
  `rest_test.exs` happened to use the right field names, so nothing caught the real
  response's actual shape until it was checked against the spec by hand.

  This suite is the checked version, made permanent. Every fixture under
  `test/fixtures/spec_examples/` cites, in that folder's `README.md` (JSON has no
  comments), the exact spec path and JSON pointer it was built from — an
  `example`/`examples` on the response where the spec carries one, and otherwise **every**
  documented property of the schema, since no schema called here declares a `required`
  array on its response side at all (checked with `jq` against every schema this file
  touches, 2026-09-29). That is noted per-file in the README rather than asserted blind.

  It duplicates none of `rest_test.exs` or `trading_test.exs`'s edge-case coverage
  (pagination loops, malformed rows, refusals, NaN guards) — those tests already own that
  ground. This one asks a narrower question of every endpoint: fed the vendor's own
  documented shape, unmodified, does the real public function return `{:ok, _}` with the
  example's own values actually on it, and does the request this package sends match what
  the spec's `parameters`/`requestBody` say it should?

  ## Two real mismatches this suite found (see `Rest.order_struct/1`)

  Building `api_v2_crypto_trading_orders_get_one.json` and
  `api_v2_crypto_trading_cancel_order.json` strictly from
  `#/components/schemas/OrderResponse` — a `limit_price`/`stop_price` inside the type-named
  `*_order_config`, an `updated_at` on the row itself — surfaced two fields
  `Core.Types.Order` has dedicated slots for that `order_struct/1` never read at all:
  `price`/`stop_price` (nothing populated either key, ever) and `updated_at` (silently
  dropped in favour of `created_at` alone). Both are read now; see `Rest`'s own comments at
  the fix for the citation. Every existing hand-built fixture in `trading_test.exs` simply
  never asked for either field, which is exactly the failure mode this suite exists to
  close off.

  ## The vendor's own schema and its own worked example disagree

  `AddOrderV2`'s `market_order_config.asset_quantity` (and the sibling configs'
  `limit_price`/`stop_price`) are declared `type: number` in the formal schema — but the
  spec's own `info.description` embeds a full worked Python client whose
  `place_order`/`get_estimated_price` calls build these as **strings**
  (`{"asset_quantity": "0.0001"}`), and every quantity/price this package sends is a
  string too (`Rest.decimal_string/1`, `"full notation, never scientific"`). That is not a
  gap this suite treats as a bug: a string avoids the float precision loss a JSON number
  would risk for money, matches the vendor's own worked example exactly, and every sibling
  venue in this family sends decimals as strings for the same reason. The request-side
  tests below assert the string form the package actually sends and cite this
  self-contradiction rather than silently picking a side.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.{Config, Instrument, Types}
  alias DpExchange.Robinhood.Rest

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

  @credentials %{api_key: "rh-spec-key", private_key: Base.encode64(:binary.copy(<<7>>, 32))}

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "spec_examples"])

  defp fixture!(name) do
    @fixtures_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  # Responds with a fixture body and, optionally, captures the request this package
  # actually sent so the REQUEST side (path, method, query and body parameter names) can
  # be checked against the spec's own `parameters`/`requestBody`, not only the response.
  defp responding(body, status \\ 200) do
    fn conn -> Req.Test.json(%{conn | status: status}, body) end
  end

  defp capturing(body, status, test_pid) do
    fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:spec_request, conn.method, conn.request_path, conn.query_string, raw_body}
      )

      Req.Test.json(%{conn | status: status}, body)
    end
  end

  defp query_params(query_string), do: URI.decode_query(query_string || "")

  # `get_balances/2` also calls `get_accounts/2` for the account's cash (dp-exchange-core
  # issue #35), through the same `opts[:plug]` — routed here by request path so a
  # holdings-example body never has to answer for the accounts call too. Defaults to the
  # vendor's own committed accounts example, so the cash row this drives is itself spec-built.
  defp holdings_and_accounts(holdings_body, accounts_body \\ nil) do
    fn conn ->
      if String.contains?(conn.request_path, "/holdings/") do
        Req.Test.json(conn, holdings_body)
      else
        Req.Test.json(conn, accounts_body || fixture!("api_v2_crypto_trading_accounts.json"))
      end
    end
  end

  defp capturing_holdings(holdings_body, status, test_pid, accounts_body \\ nil) do
    fn conn ->
      if String.contains?(conn.request_path, "/holdings/") do
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)

        send(
          test_pid,
          {:spec_request, conn.method, conn.request_path, conn.query_string, raw_body}
        )

        Req.Test.json(%{conn | status: status}, holdings_body)
      else
        Req.Test.json(conn, accounts_body || fixture!("api_v2_crypto_trading_accounts.json"))
      end
    end
  end

  describe "GET best_bid_ask — /api/v2/crypto/marketdata/best_bid_ask/ (V2BestBidAskResponse)" do
    test "request: the spec's one required query parameter, `symbol`" do
      me = self()

      assert {:ok, _top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: capturing(fixture!("api_v2_crypto_marketdata_best_bid_ask.json"), 200, me),
                 retry_attempts: 0
               )

      assert_receive {:spec_request, "GET", path, query, _body}
      assert path == "/api/v2/crypto/marketdata/best_bid_ask/"
      assert query_params(query) == %{"symbol" => "BTC-USD"}
    end

    test "response: the example's bid/ask — sent as JSON numbers per V2BestBidAsk, not strings" do
      assert {:ok, %Types.TopOfBook{} = top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(fixture!("api_v2_crypto_marketdata_best_bid_ask.json")),
                 retry_attempts: 0
               )

      assert top.symbol == "BTC-USD"
      assert top.provider == :robinhood
      assert Decimal.equal?(top.bid, Decimal.new("77840.5"))
      assert Decimal.equal?(top.ask, Decimal.new("77850.75"))
      # V2BestBidAsk has no `timestamp` property at all — the honest, permanent answer.
      assert top.venue_time == nil
    end
  end

  describe "GET trading_pairs — /api/v2/crypto/trading/trading_pairs/ (V2TradingPairsResponse)" do
    test "request: get_symbols/2 and list_instruments/2 send no filter at all" do
      me = self()

      assert {:ok, _symbols} =
               Rest.get_symbols(@credentials,
                 plug: capturing(fixture!("api_v2_crypto_trading_trading_pairs.json"), 200, me),
                 retry_attempts: 0
               )

      assert_receive {:spec_request, "GET", path, query, _body}
      assert path == "/api/v2/crypto/trading/trading_pairs/"
      assert query == ""
    end

    test "request: quantization/3 filters by the spec's optional `symbol` query parameter" do
      me = self()

      assert {:ok, _quantum} =
               Rest.quantization("BTC-USD", @credentials,
                 plug: capturing(fixture!("api_v2_crypto_trading_trading_pairs.json"), 200, me),
                 retry_attempts: 0
               )

      assert_receive {:spec_request, "GET", path, query, _body}
      assert path == "/api/v2/crypto/trading/trading_pairs/"
      assert query_params(query) == %{"symbol" => "BTC-USD"}
    end

    test "response: get_symbols/2 returns the example's canonical symbol" do
      assert {:ok, ["BTC-USD"]} =
               Rest.get_symbols(@credentials,
                 plug: responding(fixture!("api_v2_crypto_trading_trading_pairs.json")),
                 retry_attempts: 0
               )
    end

    test "response: list_instruments/2 reads base/quote/status off the same example row" do
      assert {:ok, [%Instrument{} = instrument]} =
               Rest.list_instruments(@credentials,
                 plug: responding(fixture!("api_v2_crypto_trading_trading_pairs.json")),
                 retry_attempts: 0
               )

      assert instrument.symbol == "BTC-USD"
      assert instrument.base == "BTC"
      assert instrument.quote == "USD"
      assert instrument.instrument == :spot
      assert instrument.status == :tradable
    end

    test "response: quantization/3 reads every increment/limit field off the same example row" do
      assert {:ok, quantum} =
               Rest.quantization("BTC-USD", @credentials,
                 plug: responding(fixture!("api_v2_crypto_trading_trading_pairs.json")),
                 retry_attempts: 0
               )

      assert Decimal.equal?(quantum.quantity_increment, Decimal.new("0.00000001"))
      assert Decimal.equal?(quantum.price_increment, Decimal.new("0.01"))
      assert Decimal.equal?(quantum.max_quantity, Decimal.new("100.00000000"))
      assert Decimal.equal?(quantum.min_quote_size, Decimal.new("1.00"))
      # The schema names no per-unit minimum at all — see `Rest.quantization/3`'s own doc.
      assert quantum.min_quantity == nil
      assert quantum.status == "tradable"
    end
  end

  describe "GET accounts — /api/v2/crypto/trading/accounts/ (V2AccountsResponse)" do
    test "request: no required query parameter — path and method only" do
      me = self()

      assert {:ok, _accounts} =
               Rest.get_accounts(@credentials,
                 plug: capturing(fixture!("api_v2_crypto_trading_accounts.json"), 200, me),
                 retry_attempts: 0
               )

      assert_receive {:spec_request, "GET", path, "", _body}
      assert path == "/api/v2/crypto/trading/accounts/"
    end

    test "response: the example account row, returned unmodified — there is no Core struct for it" do
      assert {:ok, [account]} =
               Rest.get_accounts(@credentials,
                 plug: responding(fixture!("api_v2_crypto_trading_accounts.json")),
                 retry_attempts: 0
               )

      assert account["account_number"] == "5QR89701"
      assert account["status"] == "active"
      assert account["buying_power"] == "1000.00"
      assert account["buying_power_currency"] == "USD"
      assert account["account_type"] == "individual"
      assert account["is_api_tradable"] == true
      assert account["fee_tier_status"]["fee_ratio"] == 0.0035
      assert account["fee_tier_status"]["thirty_day_volume"] == 12_500.5
      assert account["fee_tier_status"]["next_fee_tier_ratio"] == 0.002
      assert account["fee_tier_status"]["next_fee_tier_threshold"] == 50_000.0
    end
  end

  describe "GET holdings — /api/v2/crypto/trading/holdings/ (V2HoldingsResponse)" do
    test "request: the spec's required `account_number` and optional `asset_code`" do
      me = self()

      assert {:ok, _balances} =
               Rest.get_balances(@credentials,
                 account_number: "5QR89701",
                 asset_codes: ["BTC"],
                 plug:
                   capturing_holdings(fixture!("api_v2_crypto_trading_holdings.json"), 200, me),
                 retry_attempts: 0
               )

      assert_receive {:spec_request, "GET", path, query, _body}
      assert path == "/api/v2/crypto/trading/holdings/"
      assert query_params(query) == %{"account_number" => "5QR89701", "asset_code" => "BTC"}
    end

    test "response: the example holding decodes to a real Balance, hold left nil" do
      # Plus the account's cash (dp-exchange-core issue #35), derived from the vendor's own
      # committed accounts example — `api_v2_crypto_trading_accounts.json`'s
      # `buying_power`/`buying_power_currency`, "1000.00" / "USD".
      assert {:ok, [%Types.Balance{} = balance, %Types.Balance{} = cash]} =
               Rest.get_balances(@credentials,
                 account_number: "5QR89701",
                 plug: holdings_and_accounts(fixture!("api_v2_crypto_trading_holdings.json")),
                 retry_attempts: 0
               )

      assert balance.currency == "BTC"
      assert Decimal.equal?(balance.balance, Decimal.new("0.50000000"))
      assert Decimal.equal?(balance.available_balance, Decimal.new("0.25000000"))
      # The venue publishes no hold figure — subtracting would state a number it never sent.
      assert balance.hold == nil
      assert balance.provider == :robinhood

      assert cash.currency == "USD"
      assert cash.balance == nil
      assert Decimal.equal?(cash.available_balance, Decimal.new("1000.00"))
      assert cash.hold == nil
      assert cash.provider == :robinhood
    end
  end

  describe "GET estimated_price — operationId names it `marketdata`, the path is `/trading/`" do
    test "request: the spec's three required query parameters, symbol/side/quantity" do
      me = self()

      assert {:ok, _estimate} =
               Rest.get_estimated_price(
                 "BTC-USD",
                 "ask",
                 "0.1",
                 @credentials,
                 plug:
                   capturing(fixture!("api_v2_crypto_marketdata_estimated_price.json"), 200, me),
                 retry_attempts: 0
               )

      assert_receive {:spec_request, "GET", path, query, _body}
      assert path == "/api/v2/crypto/trading/estimated_price/"

      assert query_params(query) == %{
               "symbol" => "BTC-USD",
               "side" => "ask",
               "quantity" => "0.1"
             }
    end

    test "response: the example row's values; numbers come back as Decimal, not float" do
      assert {:ok, body} =
               Rest.get_estimated_price(
                 "BTC-USD",
                 "ask",
                 "0.1",
                 @credentials,
                 plug: responding(fixture!("api_v2_crypto_marketdata_estimated_price.json")),
                 retry_attempts: 0
               )

      assert [row] = body["results"]
      assert row["symbol"] == "BTC-USD"
      assert row["side"] == "ask"
      assert row["timestamp"] == "2026-09-06T12:34:56Z"

      # Money is not a float: each number comes back as the decimal the wire carried.
      expected = %{
        "quantity" => "0.1",
        "bid" => "77800.25",
        "ask" => "77850.75",
        "fee_ratio" => "0.0035",
        "est_fee" => "27.25",
        "est_total_cost" => "7812.5",
        "est_total_credit" => "7780"
      }

      for {key, text} <- expected do
        assert %Decimal{} = row[key]
        assert Decimal.equal?(row[key], Decimal.new(text))
      end
    end
  end

  describe "POST orders — /api/v2/crypto/trading/orders/ (AddOrderV2 → V2CryptoOrder, 201)" do
    test "request: AddOrderV2's required fields and the type-named config key" do
      me = self()

      assert {:ok, _order} =
               Rest.place_order(
                 @credentials,
                 %{
                   symbol: "BTC-USD",
                   side: :buy,
                   order_type: :market,
                   quantity: Decimal.new("0.001")
                 },
                 account_number: "5QR89701",
                 plug: capturing(fixture!("api_v2_crypto_trading_orders_post.json"), 201, me),
                 retry_attempts: 0
               )

      assert_receive {:spec_request, "POST", path, query, raw_body}
      assert path == "/api/v2/crypto/trading/orders/"
      assert query_params(query) == %{"account_number" => "5QR89701"}

      body = Jason.decode!(raw_body)
      # `AddOrderV2.required`: exactly these four.
      assert body["symbol"] == "BTC-USD"
      assert body["side"] == "buy"
      assert body["type"] == "market"
      assert is_binary(body["client_order_id"])
      assert body["client_order_id"] =~ ~r/^[0-9a-f-]{36}$/
      # `market_order_config.asset_quantity` is declared `type: number` in the formal
      # schema; this package sends it as a string, matching the spec's OWN worked Python
      # sample rather than the formal type — see this module's moduledoc.
      assert body["market_order_config"] == %{"asset_quantity" => "0.001"}
      refute Map.has_key?(body, "limit_order_config")
    end

    test "response: the example's filled market order — including the two fields this suite found missing" do
      assert {:ok, %Types.Order{} = order} =
               Rest.place_order(
                 @credentials,
                 %{
                   symbol: "BTC-USD",
                   side: :buy,
                   order_type: :market,
                   quantity: Decimal.new("0.001")
                 },
                 account_number: "5QR89701",
                 plug: responding(fixture!("api_v2_crypto_trading_orders_post.json"), 201),
                 retry_attempts: 0
               )

      assert order.id == "5b1f0a02-9e3b-4a54-9a1c-6b0e6a6b6a10"
      assert order.symbol == "BTC-USD"
      assert order.side == :buy
      assert order.order_type == :market
      assert Decimal.equal?(order.quantity, Decimal.new("0.001"))
      assert Decimal.equal?(order.filled_quantity, Decimal.new("0.001"))
      assert Decimal.equal?(order.average_price, Decimal.new("77845.0"))
      assert order.status == :filled
      assert Decimal.equal?(order.fee, Decimal.new("0.27"))
      assert order.fee_currency == nil
      # A market order has no price at either config key.
      assert order.price == nil
      assert order.stop_price == nil
      assert order.created_at == ~U[2026-09-06 12:35:00Z]
      # `updated_at` — silently dropped before this suite's fix; see the moduledoc.
      assert order.updated_at == ~U[2026-09-06 12:35:01Z]
      assert order.provider == :robinhood
    end
  end

  describe "POST cancel — /api/v2/crypto/trading/orders/{id}/cancel/ (V2CryptoOrder, 200)" do
    @order_id "5b1f0a02-9e3b-4a54-9a1c-6b0e6a6b6a10"

    test "request: the spec's required path parameter `id`, and an empty body" do
      me = self()

      assert {:ok, _order} =
               Rest.cancel_order(@credentials, @order_id,
                 plug: capturing(fixture!("api_v2_crypto_trading_cancel_order.json"), 200, me),
                 retry_attempts: 0
               )

      assert_receive {:spec_request, "POST", path, _query, raw_body}
      assert path == "/api/v2/crypto/trading/orders/#{@order_id}/cancel/"
      assert raw_body == ""
    end

    test "response: the example's canceled limit order — its nullable average_price, and its limit_price read back" do
      assert {:ok, %Types.Order{} = order} =
               Rest.cancel_order(@credentials, @order_id,
                 plug: responding(fixture!("api_v2_crypto_trading_cancel_order.json")),
                 retry_attempts: 0
               )

      assert order.id == @order_id
      assert order.status == :cancelled
      assert order.order_type == :limit
      # `average_price` is `nullable: true` on the spec; a canceled order genuinely has none.
      assert order.average_price == nil
      assert Decimal.equal?(order.filled_quantity, Decimal.new("0.0"))
      # `limit_order_config.limit_price`, read into `Order.price` — this suite's fix.
      assert Decimal.equal?(order.price, Decimal.new("70000.0"))
      assert order.stop_price == nil
      assert order.updated_at == ~U[2026-09-06 12:36:00Z]
    end
  end

  describe "GET one order — path absent from the committed spec's `paths`, decoded via V2CryptoOrder" do
    # Confirmed absent (`jq '.paths | keys'` against the committed document, 2026-09-29):
    # only `.../orders/{id}/cancel/` is a formally documented single-order path. This
    # package's own `Rest.get_order/3` calls `.../orders/{order_id}/` regardless — named in
    # `docs/reference/robinhood/endpoint-inventory.md` and in the spec's own embedded
    # getting-started Python sample (`get_order(account_number, order_id)`), just not in
    # `paths`. See `test/fixtures/spec_examples/README.md` for the full citation; the
    # fixture reuses `V2CryptoOrder`, the schema `to_order/1` actually decodes with,
    # because there is no better-documented shape to build it from.
    @order_id "77777777-7777-4777-8777-777777777777"

    test "request: account_number carried as a query parameter, same convention as the other v2 order calls" do
      me = self()

      assert {:ok, _order} =
               Rest.get_order(@credentials, @order_id,
                 account_number: "5QR89701",
                 plug: capturing(fixture!("api_v2_crypto_trading_orders_get_one.json"), 200, me),
                 retry_attempts: 0
               )

      assert_receive {:spec_request, "GET", path, query, _body}
      assert path == "/api/v2/crypto/trading/orders/#{@order_id}/"
      assert query_params(query) == %{"account_number" => "5QR89701"}
    end

    test "response: a partially-filled stop-limit order — both limit_price and stop_price on one row" do
      assert {:ok, %Types.Order{} = order} =
               Rest.get_order(@credentials, @order_id,
                 account_number: "5QR89701",
                 plug: responding(fixture!("api_v2_crypto_trading_orders_get_one.json")),
                 retry_attempts: 0
               )

      assert order.id == @order_id
      assert order.symbol == "BTC-USD"
      assert order.side == :sell
      assert order.order_type == :stop_limit
      assert order.status == :partially_filled
      assert Decimal.equal?(order.quantity, Decimal.new("0.01"))
      assert Decimal.equal?(order.filled_quantity, Decimal.new("0.005"))
      assert Decimal.equal?(order.average_price, Decimal.new("76550.0"))
      assert Decimal.equal?(order.price, Decimal.new("76500.0"))
      assert Decimal.equal?(order.stop_price, Decimal.new("76600.0"))
      assert order.time_in_force == :gtc
      assert Decimal.equal?(order.fee, Decimal.new("0.19"))
      assert order.created_at == ~U[2026-09-05 07:55:00Z]
      assert order.updated_at == ~U[2026-09-05 08:00:00Z]
    end
  end

  describe "GET orders — /api/v2/crypto/trading/orders/ (V2OrdersResponse)" do
    test "request: the spec's required account_number and its optional created_at_start/state filters" do
      me = self()

      assert {:ok, _orders} =
               Rest.get_orders(@credentials,
                 account_number: "5QR89701",
                 created_at_start: "2026-08-01T00:00:00Z",
                 state: "open",
                 plug: capturing(fixture!("api_v2_crypto_trading_orders_get.json"), 200, me),
                 retry_attempts: 0
               )

      assert_receive {:spec_request, "GET", path, query, _body}
      assert path == "/api/v2/crypto/trading/orders/"

      assert query_params(query) == %{
               "account_number" => "5QR89701",
               "created_at_start" => "2026-08-01T00:00:00Z",
               "state" => "open"
             }
    end

    test "response: two example rows — the response-side time_in_force asymmetry the spec itself documents" do
      assert {:ok, [limit_order, stop_loss_order]} =
               Rest.get_orders(@credentials,
                 account_number: "5QR89701",
                 plug: responding(fixture!("api_v2_crypto_trading_orders_get.json")),
                 retry_attempts: 0
               )

      assert limit_order.symbol == "ETH-USD"
      assert limit_order.order_type == :limit
      assert limit_order.status == :open
      assert Decimal.equal?(limit_order.quantity, Decimal.new("2.0"))
      assert Decimal.equal?(limit_order.price, Decimal.new("3400.5"))
      # `OrderResponse.limit_order_config` carries no `time_in_force` at all on a response —
      # confirmed against the schema, see `Rest`'s own moduledoc.
      assert limit_order.time_in_force == nil

      assert stop_loss_order.symbol == "BTC-USD"
      assert stop_loss_order.order_type == :stop
      assert stop_loss_order.status == :filled
      assert Decimal.equal?(stop_loss_order.quantity, Decimal.new("0.01"))
      assert Decimal.equal?(stop_loss_order.stop_price, Decimal.new("76600.0"))
      assert stop_loss_order.price == nil
      # `stop_loss_order_config` DOES echo `time_in_force` on a response.
      assert stop_loss_order.time_in_force == :gtc
    end
  end
end
