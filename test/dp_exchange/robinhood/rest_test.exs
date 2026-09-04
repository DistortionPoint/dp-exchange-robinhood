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
          # Nothing here reads "price" — the venue's `best_bid_ask` response shape, kept
          # for realism even though this package no longer looks at the field.
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
    test "returns a TopOfBook with Decimal numerics, spread-inclusive as the venue sent them" do
      # The venue publishes spread-inclusive prices — what a caller would transact at — and
      # they are carried as sent. `Core.Types.Quote` has no bid or ask to put them on, which
      # is why there is no `get_price/3` here at all — see the moduledoc.
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
      body = quote_body() |> put_in(["results"], [%{"timestamp" => "2026-08-28T17:00:01Z"}])

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert top.bid == nil
      assert top.ask == nil
    end

    test "a venue timestamp this package cannot parse is nil, not a failed call" do
      # Unlike a trade price, a book with an unreadable venue_time is still a real,
      # current book — `top_of_book_time/1` swallows the parse failure into `nil` rather
      # than refusing the whole read.
      body = quote_body(%{"timestamp" => "whenever"})

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert top.venue_time == nil
    end

    test "an empty results list is a refusal — the venue does not carry it" do
      assert {:refused, :not_listed} =
               Rest.get_top_of_book("NOPE-USD", @credentials,
                 plug: responding(%{"results" => []}),
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

  describe "timestamps" do
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
