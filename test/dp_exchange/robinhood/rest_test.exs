defmodule DpExchange.Robinhood.RestTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Types}
  alias DpExchange.Robinhood.Rest

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

  defp responding(body, status \\ 200) do
    fn conn -> Req.Test.json(%{conn | status: status}, body) end
  end

  # v2's `V2BestBidAsk` — the schema `/api/v2/crypto/marketdata/best_bid_ask/` actually
  # returns, confirmed against the vendor's own OpenAPI document, 2026-09-06 — is exactly
  # `symbol`, `bid`, `ask`. No spread-inclusive names, no `price`, no `timestamp`. An
  # earlier version of this fixture used v1's field names
  # (`bid_inclusive_of_sell_spread` / `ask_inclusive_of_buy_spread`) against the v2 path
  # this module actually calls — realistic-looking and wrong, so every test built on it
  # passed while `Rest.get_top_of_book/3` silently decoded `bid: nil, ask: nil` against the
  # real venue. See `Rest`'s own moduledoc, "v2's field names are not v1's."
  defp quote_body(overrides \\ %{}) do
    row = Map.merge(%{"symbol" => "BTC-USD", "bid" => "77840.00", "ask" => "77850.00"}, overrides)

    %{"results" => [row]}
  end

  describe "every call is signed, because there is no anonymous endpoint" do
    test "the three headers reach the wire even for a book" do
      plug = fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["k"]
        assert [_signature] = Plug.Conn.get_req_header(conn, "x-signature")
        assert [_timestamp] = Plug.Conn.get_req_header(conn, "x-timestamp")

        Req.Test.json(conn, quote_body())
      end

      assert {:ok, _top} =
               Rest.get_top_of_book("BTC-USD", @credentials, plug: plug, retry_attempts: 0)
    end

    test "without credentials it refuses rather than sending unsigned" do
      assert {:error, {:missing_credentials, :robinhood}} =
               Rest.get_top_of_book("BTC-USD", %{}, retry_attempts: 0)
    end

    test "the query string is part of the signed path" do
      plug = fn conn ->
        assert conn.query_string =~ "symbol=BTC-USD"
        Req.Test.json(conn, quote_body())
      end

      assert {:ok, _top} =
               Rest.get_top_of_book("BTC-USD", @credentials, plug: plug, retry_attempts: 0)
    end
  end

  describe "get_top_of_book/3" do
    test "returns a TopOfBook with Decimal numerics, from v2's plain bid/ask fields" do
      # v2's `V2BestBidAsk` names its two prices `bid` and `ask` — not v1's spread-inclusive
      # names. `Core.Types.Quote` has no bid or ask to put them on either way, which is why
      # there is no `get_price/3` here at all — see the moduledoc.
      assert {:ok, %Types.TopOfBook{} = top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(quote_body()),
                 retry_attempts: 0
               )

      assert top.symbol == "BTC-USD"
      assert top.provider == :robinhood
      assert Decimal.equal?(top.bid, Decimal.new("77840.00"))
      assert Decimal.equal?(top.ask, Decimal.new("77850.00"))
      refute Map.has_key?(top, :price)
    end

    test "a missing bid or ask decodes as nil, not as an error" do
      body = quote_body() |> put_in(["results"], [%{"symbol" => "BTC-USD"}])

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert top.bid == nil
      assert top.ask == nil
    end

    test "venue_time is nil against a real v2 response — the venue sends no timestamp here" do
      # `V2BestBidAsk` has exactly three properties: `symbol`, `bid`, `ask`. There is no
      # `timestamp` to read, so this is the honest, permanent answer for this endpoint —
      # not a parse failure on an occasionally-missing field.
      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(quote_body()),
                 retry_attempts: 0
               )

      assert top.venue_time == nil
    end

    test "an unparseable timestamp, if the venue ever sent one, would decode to nil rather than fail the call" do
      # Defensive coverage, not a documented v2 behaviour: `V2BestBidAsk` publishes no
      # `timestamp` today (see the test above), but `top_of_book_time/1` still tolerates a
      # present-and-unparseable one gracefully rather than refusing a real, current book
      # over a field the schema does not even promise.
      body = quote_body(%{"timestamp" => "whenever"})

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert top.venue_time == nil
    end

    test "an empty results list is a retryable error, NOT a refusal — DpCryptoManagement issue #25" do
      # An empty page is this specific request coming back with nothing — it is not the
      # venue stating the symbol does not exist. `{:refused, _}` is reported once and
      # never retried (`Core.PollingFeed`'s own contract), so treating silence as a
      # statement here is what turned 56 of 83 held refusals into a permanent verdict on
      # pairs — BTC-USD, ETH-USD, LTC-USD, LINK-USD, DOGE-USD among them — that answer
      # normally on the very next call.
      assert {:error, :empty_result} =
               Rest.get_top_of_book("NOPE-USD", @credentials,
                 plug: responding(%{"results" => []}),
                 retry_attempts: 0
               )
    end

    test "a 404 with a venue-stated detail is still a genuine refusal" do
      # The venue SAYING so — by status code and body — is the one case `{:refused, _}`
      # remains correct for, and this must not regress alongside the empty-page fix above.
      body = %{"detail" => "Symbol not found"}

      assert {:refused, {:venue_error, 404, "Symbol not found"}} =
               Rest.get_top_of_book("NOPE-USD", @credentials,
                 plug: responding(body, 404),
                 retry_attempts: 0
               )
    end

    test "a body with no results key is unreadable, not empty" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(%{}),
                 retry_attempts: 0
               )
    end

    test "a 401 is a refusal carrying the venue's own detail" do
      body = %{"detail" => "invalid signature"}

      assert {:refused, {:venue_error, 401, "invalid signature"}} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(body, 401),
                 retry_attempts: 0
               )
    end

    test "a refusal nested under errors is read too" do
      body = %{"errors" => [%{"detail" => "not tradable"}]}

      assert {:refused, {:venue_error, 400, "not tradable"}} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(body, 400),
                 retry_attempts: 0
               )
    end

    test "a 500 stays an error the caller may retry" do
      assert {:error, _reason} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(%{}, 500),
                 retry_attempts: 0
               )
    end
  end

  describe "timestamps — defensive coverage against a field v2 does not currently send" do
    test "an epoch in seconds or milliseconds both land in the right year" do
      for value <- [1_787_936_147, 1_787_936_147_000] do
        body = quote_body(%{"timestamp" => value})

        assert {:ok, top} =
                 Rest.get_top_of_book("BTC-USD", @credentials,
                   plug: responding(body),
                   retry_attempts: 0
                 )

        assert top.venue_time.year == 2026
      end
    end
  end

  describe "get_symbols/2 walks the pagination" do
    test "follows next until it runs out" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:path, conn.request_path <> "?" <> (conn.query_string || "")})

        case conn.query_string do
          "" ->
            Req.Test.json(conn, %{
              "results" => [%{"symbol" => "BTC-USD"}],
              "next" =>
                "https://trading.robinhood.com/api/v1/crypto/trading/trading_pairs/?cursor=2"
            })

          _second_page ->
            Req.Test.json(conn, %{"results" => [%{"symbol" => "ETH-USD"}], "next" => nil})
        end
      end

      assert {:ok, ["BTC-USD", "ETH-USD"]} =
               Rest.get_symbols(@credentials, plug: plug, retry_attempts: 0)
    end

    test "a next pointing at a page already fetched ends the walk" do
      # The hang this guards. A cursor walk trusts the venue to stop saying "next";
      # if it ever points back at a page already fetched, the caller blocks forever
      # with no error while the venue takes a signed request every few milliseconds.
      plug = fn conn ->
        Req.Test.json(conn, %{
          "results" => [%{"symbol" => "BTC-USD"}],
          "next" => "https://trading.robinhood.com/api/v1/crypto/trading/trading_pairs/"
        })
      end

      assert {:error, {:pagination_loop, _path}} =
               Rest.get_symbols(@credentials, plug: plug, retry_attempts: 0)
    end

    test "a cursor that never repeats a page is bounded, not walked forever" do
      # The hang the cycle guard above CANNOT catch, and the reason a page bound exists
      # alongside it. `seen` only fires when the venue hands back a path it already gave
      # us; a venue handing back a NEW path every time — `?cursor=1`, `?cursor=2`, … —
      # never repeats one, so nothing stops the walk. It would hold the caller and spend a
      # signed request per page until something else broke.
      #
      # Every other venue in this family already bounded its pagination; Robinhood was the
      # one walking a cursor with no bound at all.
      counter = :atomics.new(1, signed: false)

      plug = fn conn ->
        n = :atomics.add_get(counter, 1, 1)

        Req.Test.json(conn, %{
          "results" => [%{"symbol" => "BTC-USD"}],
          "next" =>
            "https://trading.robinhood.com/api/v1/crypto/trading/trading_pairs/?cursor=#{n}"
        })
      end

      assert {:error, :too_many_trading_pair_pages} =
               Rest.get_symbols(@credentials, plug: plug, retry_attempts: 0)

      # Bounded, and bounded where it says it is: the walk stopped at the page limit rather
      # than at whatever the test's patience happened to be.
      assert :atomics.get(counter, 1) <= 50
    end

    test "a single page needs no cursor" do
      body = %{"results" => [%{"symbol" => "BTC-USD"}]}

      assert {:ok, ["BTC-USD"]} =
               Rest.get_symbols(@credentials, plug: responding(body), retry_attempts: 0)
    end

    test "rows with no symbol are skipped rather than becoming nil entries" do
      body = %{"results" => [%{"symbol" => "BTC-USD"}, %{"id" => "x"}]}

      assert {:ok, ["BTC-USD"]} =
               Rest.get_symbols(@credentials, plug: responding(body), retry_attempts: 0)
    end

    test "a body with no results key is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_symbols(@credentials, plug: responding(%{}), retry_attempts: 0)
    end

    test "a refusal on the first page propagates" do
      assert {:refused, {:venue_error, 403, _detail}} =
               Rest.get_symbols(@credentials,
                 plug: responding(%{"detail" => "no access"}, 403),
                 retry_attempts: 0
               )
    end
  end

  describe "list_instruments/2" do
    @row %{
      "symbol" => "BTC-USD",
      "asset_code" => "BTC",
      "quote_code" => "USD",
      "status" => "tradable"
    }

    test "reads base and quote from asset_code/quote_code, not the symbol string" do
      body = %{"results" => [@row]}

      assert {:ok, [instrument]} =
               Rest.list_instruments(@credentials, plug: responding(body), retry_attempts: 0)

      assert instrument.symbol == "BTC-USD"
      assert instrument.base == "BTC"
      assert instrument.quote == "USD"
      assert instrument.instrument == :spot
      assert instrument.status == :tradable
    end

    test "a status this package has not seen is :unknown, not assumed delisted" do
      body = %{"results" => [%{@row | "status" => "trading_halted"}]}

      assert {:ok, [instrument]} =
               Rest.list_instruments(@credentials, plug: responding(body), retry_attempts: 0)

      assert instrument.status == :unknown
    end

    test "walks every page, same as get_symbols/2" do
      plug = fn conn ->
        case conn.query_string do
          "" ->
            Req.Test.json(conn, %{
              "results" => [@row],
              "next" =>
                "https://trading.robinhood.com/api/v1/crypto/trading/trading_pairs/?cursor=2"
            })

          _second_page ->
            Req.Test.json(conn, %{
              "results" => [%{@row | "symbol" => "ETH-USD", "asset_code" => "ETH"}],
              "next" => nil
            })
        end
      end

      assert {:ok, instruments} =
               Rest.list_instruments(@credentials, plug: plug, retry_attempts: 0)

      assert Enum.map(instruments, & &1.symbol) == ["BTC-USD", "ETH-USD"]
    end

    test "rows with no symbol are skipped, same as get_symbols/2" do
      body = %{"results" => [@row, %{"asset_code" => "no-symbol-here"}]}

      assert {:ok, [instrument]} =
               Rest.list_instruments(@credentials, plug: responding(body), retry_attempts: 0)

      assert instrument.symbol == "BTC-USD"
    end

    test "a refusal propagates, same as get_symbols/2" do
      assert {:refused, {:venue_error, 403, _detail}} =
               Rest.list_instruments(@credentials,
                 plug: responding(%{"detail" => "no access"}, 403),
                 retry_attempts: 0
               )
    end
  end

  describe "quantization/3" do
    @pair_row %{
      "symbol" => "BTC-USD",
      "asset_code" => "BTC",
      "quote_code" => "USD",
      "asset_increment" => "0.00000001",
      "quote_increment" => "0.01",
      "max_order_size" => "100",
      "min_order_amount" => "1.00",
      "status" => "tradable",
      "is_api_tradable" => true
    }

    test "reads increments and limits from the same trading_pairs row get_symbols/1 uses" do
      assert {:ok, quantum} =
               Rest.quantization("BTC-USD", @credentials,
                 plug: responding(%{"results" => [@pair_row]}),
                 retry_attempts: 0
               )

      assert Decimal.equal?(quantum.price_increment, Decimal.new("0.01"))
      assert Decimal.equal?(quantum.quantity_increment, Decimal.new("0.00000001"))
      assert Decimal.equal?(quantum.max_quantity, Decimal.new("100"))
      assert Decimal.equal?(quantum.min_quote_size, Decimal.new("1.00"))
      assert quantum.status == "tradable"
    end

    test "min_quantity is nil — the schema names no per-unit minimum" do
      # Robinhood's own OpenAPI schema for V2TradingPair has no min_order_size field,
      # despite different prose (beside estimated_price) naming one. Guessing at
      # min_order_amount (a CASH minimum) would answer a units question with a dollar
      # figure.
      assert {:ok, quantum} =
               Rest.quantization("BTC-USD", @credentials,
                 plug: responding(%{"results" => [@pair_row]}),
                 retry_attempts: 0
               )

      assert quantum.min_quantity == nil
    end

    test "an empty page is retryable, not a permanent not_listed verdict — issue #25" do
      assert {:error, :empty_result} =
               Rest.quantization("NOPE-USD", @credentials,
                 plug: responding(%{"results" => []}),
                 retry_attempts: 0
               )
    end

    test "a venue-stated 404 is still refused" do
      assert {:refused, {:venue_error, 404, "no such symbol"}} =
               Rest.quantization("NOPE-USD", @credentials,
                 plug: responding(%{"detail" => "no such symbol"}, 404),
                 retry_attempts: 0
               )
    end

    test "a non-numeric increment decodes to nil rather than a fabricated numeric guess" do
      row = %{@pair_row | "quote_increment" => "null"}

      assert {:ok, quantum} =
               Rest.quantization("BTC-USD", @credentials,
                 plug: responding(%{"results" => [row]}),
                 retry_attempts: 0
               )

      assert quantum.price_increment == nil
    end
  end

  describe "get_top_of_book_bulk/3 — the repeatable-symbol bulk form of best_bid_ask" do
    test "one signed request carries every symbol, via a repeated symbol param" do
      body = %{
        "results" => [
          %{"symbol" => "BTC-USD", "bid" => "77840.00", "ask" => "77850.00"},
          %{"symbol" => "ETH-USD", "bid" => "3200.00", "ask" => "3201.00"}
        ]
      }

      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:query, conn.query_string})
        Req.Test.json(conn, body)
      end

      assert {:ok, [top1, top2]} =
               Rest.get_top_of_book_bulk(["BTC-USD", "ETH-USD"], @credentials,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, query}
      assert query =~ "symbol=BTC-USD"
      assert query =~ "symbol=ETH-USD"
      # Exactly one request for both symbols — not one per symbol.
      refute_receive {:query, _second_request}, 100

      assert top1.symbol == "BTC-USD"
      assert Decimal.equal?(top1.bid, Decimal.new("77840.00"))
      assert top2.symbol == "ETH-USD"
      assert Decimal.equal?(top2.ask, Decimal.new("3201.00"))
    end

    test "a results array shorter than requested is not an error and not a refusal" do
      # The vendor's document does not say what happens when one symbol in a batch is
      # delisted, unlisted or malformed. A `results` row simply absent for one of the
      # symbols asked for is silence about THAT symbol on THIS request, not a statement
      # the symbol does not exist — the same principle `first_result/1` already applies
      # on the single-symbol path (DpCryptoManagement issue #25). This function must not
      # turn that silence into either an `:error` or a `:refused`.
      body = %{"results" => [%{"symbol" => "BTC-USD", "bid" => "1", "ask" => "2"}]}

      assert {:ok, [top]} =
               Rest.get_top_of_book_bulk(["BTC-USD", "ETH-USD", "LTC-USD"], @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert top.symbol == "BTC-USD"
    end

    test "a 400 on the bulk request is a refusal, same status handling as the single-symbol path" do
      body = %{"detail" => "Invalid symbol: NOPE-USD"}

      assert {:refused, {:venue_error, 400, "Invalid symbol: NOPE-USD"}} =
               Rest.get_top_of_book_bulk(["BTC-USD", "NOPE-USD"], @credentials,
                 plug: responding(body, 400),
                 retry_attempts: 0
               )
    end

    test "a 5xx on the bulk request is an ordinary retryable error" do
      assert {:error, _reason} =
               Rest.get_top_of_book_bulk(["BTC-USD", "ETH-USD"], @credentials,
                 plug: responding(%{}, 500),
                 retry_attempts: 0
               )
    end

    test "a row with no symbol is dropped rather than published under a fabricated key" do
      body = %{
        "results" => [
          %{"symbol" => "BTC-USD", "bid" => "1", "ask" => "2"},
          %{"bid" => "3", "ask" => "4"}
        ]
      }

      assert {:ok, [top]} =
               Rest.get_top_of_book_bulk(["BTC-USD", "ETH-USD"], @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert top.symbol == "BTC-USD"
    end

    test "a body with no results key is unreadable, same as the single-symbol path" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_top_of_book_bulk(["BTC-USD", "ETH-USD"], @credentials,
                 plug: responding(%{}),
                 retry_attempts: 0
               )
    end

    test "an empty symbol list returns {:ok, []} without a network call" do
      plug = fn _conn -> raise "no request should have been sent" end

      assert {:ok, []} = Rest.get_top_of_book_bulk([], @credentials, plug: plug)
    end
  end

  describe "rate_limit_blocking — DpCryptoManagement issue #16" do
    defmodule RecordingLimiter do
      @moduledoc false
      @behaviour DpExchange.Core.RateLimitBehaviour

      @impl true
      def acquire(_provider, _weight, _opts) do
        Process.put(:rate_limiter_call, :acquire)
        :ok
      end

      @impl true
      def check(_provider, _weight, _opts) do
        Process.put(:rate_limiter_call, :check)
        :ok
      end

      @impl true
      def record(_provider, _weight, _opts), do: :ok
    end

    test "rate_limit_blocking: true reaches Core.HttpClient as acquire/3, not check/3" do
      Config.put_override(:rate_limit_module, RecordingLimiter)

      assert {:ok, _top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(quote_body()),
                 retry_attempts: 0,
                 rate_limit_blocking: true
               )

      assert Process.get(:rate_limiter_call) == :acquire
    end

    test "rate_limit_blocking: false (or omitted) reaches Core.HttpClient as check/3" do
      Config.put_override(:rate_limit_module, RecordingLimiter)

      assert {:ok, _top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(quote_body()),
                 retry_attempts: 0
               )

      assert Process.get(:rate_limiter_call) == :check
    end
  end
end
