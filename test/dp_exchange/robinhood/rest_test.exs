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
    test "returns a Quote with bid, ask and Decimal numerics" do
      assert {:ok, %Types.Quote{} = quote_struct} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(quote_body()),
                 retry_attempts: 0
               )

      assert quote_struct.symbol == "BTC-USD"
      assert Decimal.equal?(quote_struct.bid, Decimal.new("77840.00"))
      assert Decimal.equal?(quote_struct.ask, Decimal.new("77850.00"))
      assert quote_struct.provider == :robinhood
    end

    test "the price is the ASK when the venue sends no separate price" do
      # A real quoted number and the one a buyer pays — but not a mid, so a series built
      # from it sits a spread above a mid-based series from another venue.
      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(quote_body()),
                 retry_attempts: 0
               )

      assert Decimal.equal?(quote_struct.price, quote_struct.ask)
    end

    test "an explicit price wins over the ask" do
      body = quote_body(%{"price" => "77845.00"})

      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(quote_struct.price, Decimal.new("77845.00"))
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
      body = quote_body() |> put_in(["results"], [%{"ask_inclusive_of_buy_spread" => "1"}])

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

    test "a row with neither price nor ask is unreadable" do
      body = %{"results" => [%{"timestamp" => "2026-08-28T17:00:01Z"}]}

      assert {:error, :unexpected_response_shape} =
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
end
