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

  defp quote_body(overrides \\ %{}) do
    row =
      Map.merge(
        %{
          "symbol" => "BTC-USD",
          # A traded price, deliberately inside the spread and equal to neither side: if a
          # test can pass with price == ask, it is not testing what it claims to.
          "price" => "77845.00",
          "bid_inclusive_of_sell_spread" => "77840.00",
          "ask_inclusive_of_buy_spread" => "77850.00",
          "timestamp" => "2026-08-28T17:00:01Z"
        },
        overrides
      )

    %{"results" => [row]}
  end

  describe "every call is signed, because there is no anonymous endpoint" do
    test "the three headers reach the wire even for a quote" do
      plug = fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["k"]
        assert [_signature] = Plug.Conn.get_req_header(conn, "x-signature")
        assert [_timestamp] = Plug.Conn.get_req_header(conn, "x-timestamp")

        Req.Test.json(conn, quote_body())
      end

      assert {:ok, _quote} =
               Rest.get_price("BTC-USD", @credentials, plug: plug, retry_attempts: 0)
    end

    test "without credentials it refuses rather than sending unsigned" do
      assert {:error, {:missing_credentials, :robinhood}} =
               Rest.get_price("BTC-USD", %{}, retry_attempts: 0)
    end

    test "the query string is part of the signed path" do
      plug = fn conn ->
        assert conn.query_string =~ "symbol=BTC-USD"
        Req.Test.json(conn, quote_body())
      end

      assert {:ok, _quote} =
               Rest.get_price("BTC-USD", @credentials, plug: plug, retry_attempts: 0)
    end
  end

  describe "get_price/3" do
    test "returns a Quote with Decimal numerics" do
      assert {:ok, %Types.Quote{} = quote_struct} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(quote_body()),
                 retry_attempts: 0
               )

      assert quote_struct.symbol == "BTC-USD"
      assert quote_struct.provider == :robinhood
    end

    test "the book comes back from get_top_of_book/3, not on the Quote" do
      # The venue publishes spread-inclusive prices — what a caller would transact at — and
      # they are carried as sent. `Core.Types.Quote` has no bid or ask to put them on.
      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(quote_body()),
                 retry_attempts: 0
               )

      assert Decimal.equal?(top.bid, Decimal.new("77840.00"))
      assert Decimal.equal?(top.ask, Decimal.new("77850.00"))
      assert top.observed_at
      refute Map.has_key?(top, :price)
    end

    test "an ask is never used as the price" do
      # This test used to assert the opposite — that `price` falls back to the ask when the
      # venue sends no separate price — and it passed, which is how the substitution
      # survived review. An ask is a resting order: what a seller is *willing* to take. A
      # price is what actually traded. They coincide only when that order fills.
      #
      # A consumer computing a position value or a stop from an ask believes it has a trade
      # price, and the gap between them is widest exactly when the book is thin.
      body =
        quote_body() |> put_in(["results"], [Map.delete(hd(quote_body()["results"]), "price")])

      assert {:error, :no_trade_price_in_response} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)
    end

    test "an explicit price is used as given" do
      body = quote_body(%{"price" => "77845.00"})

      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(quote_struct.price, Decimal.new("77845.00"))
    end

    test "a non-numeric price refuses the quote rather than delivering price: nil" do
      # Decimal.new/1 used to raise here. The fix must not trade a crash for a Quote whose
      # required :price is silently nil, which is the same substitution wearing a
      # quieter shape.
      body = quote_body(%{"price" => "null"})

      assert {:error, {:invalid_decimal, :price, "null"}} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)
    end

    test "volume is nil — the quote carries none and there is no candle endpoint" do
      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(quote_body()),
                 retry_attempts: 0
               )

      assert quote_struct.volume == nil
    end

    test "a quote with no venue timestamp FAILS rather than substituting now" do
      body =
        quote_body()
        |> put_in(["results"], [%{"price" => "1", "ask_inclusive_of_buy_spread" => "1"}])

      assert {:error, :missing_venue_timestamp} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)
    end

    test "an empty results list is a refusal — the venue does not carry it" do
      assert {:refused, :not_listed} =
               Rest.get_price("NOPE-USD", @credentials,
                 plug: responding(%{"results" => []}),
                 retry_attempts: 0
               )
    end

    test "a body with no results key is unreadable, not empty" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(%{}), retry_attempts: 0)
    end

    test "a row with no traded price is unreadable" do
      body = %{"results" => [%{"timestamp" => "2026-08-28T17:00:01Z"}]}

      assert {:error, :no_trade_price_in_response} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)
    end

    test "a 401 is a refusal carrying the venue's own detail" do
      body = %{"detail" => "invalid signature"}

      assert {:refused, {:venue_error, 401, "invalid signature"}} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(body, 401),
                 retry_attempts: 0
               )
    end

    test "a refusal nested under errors is read too" do
      body = %{"errors" => [%{"detail" => "not tradable"}]}

      assert {:refused, {:venue_error, 400, "not tradable"}} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(body, 400),
                 retry_attempts: 0
               )
    end

    test "a 500 stays an error the caller may retry" do
      assert {:error, _reason} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(%{}, 500),
                 retry_attempts: 0
               )
    end
  end

  describe "timestamps" do
    test "an epoch in seconds or milliseconds both land in the right year" do
      for value <- [1_787_936_147, 1_787_936_147_000] do
        body = quote_body(%{"timestamp" => value})

        assert {:ok, quote_struct} =
                 Rest.get_price("BTC-USD", @credentials,
                   plug: responding(body),
                   retry_attempts: 0
                 )

        assert quote_struct.timestamp.year == 2026
      end
    end

    test "an unparseable timestamp is an error, not a guess" do
      body = quote_body(%{"timestamp" => "whenever"})

      assert {:error, {:unparseable_venue_timestamp, "whenever"}} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)
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

    test "an unlisted symbol is refused rather than answered with an empty page" do
      assert {:refused, :not_listed} =
               Rest.quantization("NOPE-USD", @credentials,
                 plug: responding(%{"results" => []}),
                 retry_attempts: 0
               )
    end

    test "a non-numeric increment refuses rather than delivering a fabricated nil" do
      row = %{@pair_row | "quote_increment" => "null"}

      assert {:ok, quantum} =
               Rest.quantization("BTC-USD", @credentials,
                 plug: responding(%{"results" => [row]}),
                 retry_attempts: 0
               )

      assert quantum.price_increment == nil
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

      assert {:ok, _quote} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(quote_body()),
                 retry_attempts: 0,
                 rate_limit_blocking: true
               )

      assert Process.get(:rate_limiter_call) == :acquire
    end

    test "rate_limit_blocking: false (or omitted) reaches Core.HttpClient as check/3" do
      Config.put_override(:rate_limit_module, RecordingLimiter)

      assert {:ok, _quote} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(quote_body()),
                 retry_attempts: 0
               )

      assert Process.get(:rate_limiter_call) == :check
    end
  end
end
