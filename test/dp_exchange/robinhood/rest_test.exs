defmodule DpExchange.Robinhood.RestTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Types}
  alias DpExchange.Robinhood.Rest
  alias DpExchange.Robinhood.Test.SignatureCheck

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

  @seed :binary.copy(<<3>>, 32)
  @credentials %{api_key: "k", private_key: Base.encode64(@seed)}

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
    # `bid` and `ask` are JSON numbers (`type: number, format: double`) in `V2BestBidAsk`.
    row = Map.merge(%{"symbol" => "BTC-USD", "bid" => 77_840.0, "ask" => 77_850.0}, overrides)

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

    test "a retry is signed again rather than replaying the first attempt's signature" do
      # The venue accepts a signature's `x-timestamp` for about 30 seconds, and a first
      # attempt that timed out has used its whole `:timeout`. A retry re-sending those same
      # headers went out stale and was refused as unauthorised. Here the first attempt is
      # held past a second boundary and fails, so a re-signed retry carries a later stamp.
      test_pid = self()
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        [timestamp] = Plug.Conn.get_req_header(conn, "x-timestamp")
        send(test_pid, {:attempt, :counters.get(counter, 1), timestamp})

        if :counters.get(counter, 1) == 1 do
          Process.sleep(1_100)
          Plug.Conn.resp(conn, 503, "busy")
        else
          Req.Test.json(conn, quote_body())
        end
      end

      assert {:ok, _top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: plug,
                 retry_attempts: 2,
                 retry_delay: 1
               )

      assert_received {:attempt, 1, first}
      assert_received {:attempt, 2, second}
      assert String.to_integer(second) > String.to_integer(first)
    end

    test "a pinned :timestamp signs the first attempt only; a retry reads the clock" do
      # Pinned ten seconds back, inside the venue's window so the check below can verify the
      # signature, and distinguishable from a fresh stamp. Replayed on the retry (the bug) the
      # second attempt would carry the pin again, however late it went out.
      pinned = System.system_time(:second) - 10
      test_pid = self()
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        [timestamp] = Plug.Conn.get_req_header(conn, "x-timestamp")
        send(test_pid, {:attempt, :counters.get(counter, 1), timestamp})
        verdict = SignatureCheck.verify(conn, "k", @seed, "")
        send(test_pid, {:verified, :counters.get(counter, 1), verdict})

        if :counters.get(counter, 1) == 1,
          do: Plug.Conn.resp(conn, 503, "busy"),
          else: Req.Test.json(conn, quote_body())
      end

      assert {:ok, _top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: plug,
                 retry_attempts: 2,
                 retry_delay: 1,
                 timestamp: pinned
               )

      assert_received {:attempt, 1, first}
      assert_received {:attempt, 2, second}
      assert first == Integer.to_string(pinned)
      assert String.to_integer(second) > pinned
      assert_received {:verified, 2, :ok}
    end

    test "without credentials it refuses rather than sending unsigned" do
      assert {:error, {:missing_credentials, :robinhood}} =
               Rest.get_top_of_book("BTC-USD", %{}, retry_attempts: 0)
    end

    test "the query string is part of the signed path" do
      # Verified the way the venue verifies it: the signature is recomputed over the path AND
      # query string as they arrived, under the public key the seed derives. Asserting only
      # that the query reached the wire proved nothing about what the signature covers.
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:query, conn.query_string})
        send(test_pid, {:signature, SignatureCheck.verify(conn, "k", @seed, "")})
        Req.Test.json(conn, quote_body())
      end

      assert {:ok, _top} =
               Rest.get_top_of_book("BTC-USD", @credentials, plug: plug, retry_attempts: 0)

      assert_receive {:query, query}
      assert query =~ "symbol=BTC-USD"
      assert_receive {:signature, :ok}
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

    test "both sides missing is an error, not an empty book (changed 2026-10-10)" do
      # This used to pin `{:ok, %TopOfBook{bid: nil, ask: nil}}`, the exact shape the v1→v2
      # field rename produced every poll. One missing side is still a one-sided book.
      body = quote_body() |> put_in(["results"], [%{"symbol" => "BTC-USD"}])

      assert {:error, {:missing_required_field, :bid_ask}} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )
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

    test "a zero or negative timestamp decodes to nil rather than to 1970" do
      # `DateTime.from_unix/2` answers `{:ok, ~U[1970-01-01 00:00:00Z]}` for 0 and a 1969
      # instant for negatives. Both are valid `DateTime`s, which is why they are the
      # dangerous case rather than the obvious one: `venue_time` is documented as the venue's
      # own instant or `nil`, never invented, and a 1970 stamp is indistinguishable from a
      # real one to every consumer that only checks for `nil`. `0` is a common venue sentinel
      # for "unknown".
      #
      # A 1970 stamp is not "loud": a consumer computing an age gets fifty-six years and may
      # skip the row, but one that logs or charts the timestamp shows 1970 and calls it data.
      # (A number is no longer read as an epoch at all; this pins that `0` stays nil.)
      for bad <- [0, -1, "0"] do
        assert {:ok, top} =
                 Rest.get_top_of_book("BTC-USD", @credentials,
                   plug: responding(quote_body(%{"timestamp" => bad})),
                   retry_attempts: 0
                 )

        assert top.venue_time == nil, "a timestamp of #{inspect(bad)} must decode to nil"
      end
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
    test "an epoch is not a documented spelling and its unit is never guessed" do
      # Seconds and milliseconds used to be told apart by magnitude. The vendor documents
      # only `date-time`, so a number is nil, not a guessed year.
      for value <- [1_787_936_147, 1_787_936_147_000, "1787936147"] do
        body = quote_body(%{"timestamp" => value})

        assert {:ok, top} =
                 Rest.get_top_of_book("BTC-USD", @credentials,
                   plug: responding(body),
                   retry_attempts: 0
                 )

        assert top.venue_time == nil, "#{inspect(value)} must not become an instant"
      end
    end

    test "an ISO instant with an offset is converted to UTC, and one with no zone is nil" do
      with_offset = quote_body(%{"timestamp" => "2026-10-20T12:00:00+02:00"})
      no_zone = quote_body(%{"timestamp" => "2026-10-20T12:00:00"})

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(with_offset),
                 retry_attempts: 0
               )

      assert top.venue_time == ~U[2026-10-20 10:00:00Z]

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(no_zone),
                 retry_attempts: 0
               )

      assert top.venue_time == nil
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
                "https://trading.robinhood.com/api/v2/crypto/trading/trading_pairs/?cursor=2"
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
          "next" => "https://trading.robinhood.com/api/v2/crypto/trading/trading_pairs/"
        })
      end

      assert {:error, {:pagination_loop, _path}} =
               Rest.get_symbols(@credentials, plug: plug, retry_attempts: 0)
    end

    test "a next naming a different endpoint is refused, not followed" do
      # A holdings cursor handed back from a trading-pairs walk would be decoded as
      # trading pairs; the vendor describes `next` as the same request with the next cursor.
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:hit, conn.request_path})

        Req.Test.json(conn, %{
          "results" => [%{"symbol" => "BTC-USD"}],
          "next" => "https://trading.robinhood.com/api/v2/crypto/trading/holdings/?cursor=2"
        })
      end

      assert {:error, {:unexpected_next_path, "/api/v2/crypto/trading/holdings/"}} =
               Rest.get_symbols(@credentials, plug: plug, retry_attempts: 0)

      assert_received {:hit, "/api/v2/crypto/trading/trading_pairs/"}
      refute_received {:hit, "/api/v2/crypto/trading/holdings/"}
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
            "https://trading.robinhood.com/api/v2/crypto/trading/trading_pairs/?cursor=#{n}"
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

  describe "is_api_tradable — a symbol the venue's own v2 endpoints refuse" do
    # `V2TradingPair.is_api_tradable`: "Indicates whether the trading pair is supported on
    # API trading v2 endpoints" — confirmed against the vendor's OpenAPI document,
    # 2026-09-29. `best_bid_ask`, `estimated_price` and `orders` all answer 400 for a symbol
    # where this is `false`, regardless of what `status` itself says.
    test "get_symbols/2 excludes a pair the venue marks is_api_tradable: false" do
      body = %{
        "results" => [
          %{"symbol" => "BTC-USD", "is_api_tradable" => true},
          %{"symbol" => "NOPE-USD", "is_api_tradable" => false}
        ]
      }

      assert {:ok, ["BTC-USD"]} =
               Rest.get_symbols(@credentials, plug: responding(body), retry_attempts: 0)
    end

    test "get_symbols/2 keeps a pair where is_api_tradable is simply absent" do
      # Absent, not `false`, is unmeasured — the venue did not say, and the row is kept
      # exactly as before this field existed to this package.
      body = %{"results" => [%{"symbol" => "BTC-USD"}]}

      assert {:ok, ["BTC-USD"]} =
               Rest.get_symbols(@credentials, plug: responding(body), retry_attempts: 0)
    end

    test "list_instruments/2 keeps the row but marks it :unknown, not :tradable" do
      # Unlike `get_symbols/2`, this does NOT exclude the row — a consumer building a
      # catalogue may still want to know the pair is listed. `Core.Instrument` has no
      # status finer than :tradable/:delisted/:unknown for "listed but API-refused", so
      # :unknown is the closest honest reading rather than a fourth value invented here.
      body = %{
        "results" => [
          %{
            "symbol" => "NOPE-USD",
            "asset_code" => "NOPE",
            "quote_code" => "USD",
            "status" => "tradable",
            "is_api_tradable" => false
          }
        ]
      }

      assert {:ok, [instrument]} =
               Rest.list_instruments(@credentials, plug: responding(body), retry_attempts: 0)

      assert instrument.symbol == "NOPE-USD"
      assert instrument.status == :unknown
    end

    test "list_instruments/2 stays :tradable when is_api_tradable is absent" do
      body = %{
        "results" => [
          %{
            "symbol" => "BTC-USD",
            "asset_code" => "BTC",
            "quote_code" => "USD",
            "status" => "tradable"
          }
        ]
      }

      assert {:ok, [instrument]} =
               Rest.list_instruments(@credentials, plug: responding(body), retry_attempts: 0)

      assert instrument.status == :tradable
    end
  end

  describe "a response value of the wrong type is refused or skipped, never raised on" do
    # Found by mutating real response bodies, 2026-09-27. Each of these raised inside the
    # CALLER's process.
    test "an instrument row whose symbol is not a string is skipped" do
      body = %{"results" => [%{"symbol" => 0}, %{"symbol" => "BTC-USD", "asset_code" => "BTC"}]}

      assert {:ok, [only]} =
               Rest.list_instruments(@credentials, plug: responding(body), retry_attempts: 0)

      assert only.symbol == "BTC-USD"

      assert {:ok, ["BTC-USD"]} =
               Rest.get_symbols(@credentials, plug: responding(body), retry_attempts: 0)
    end

    test "a holdings row that is not an object is refused" do
      body = %{"results" => [true]}

      assert {:error, :unexpected_response_shape} =
               Rest.get_balances(@credentials,
                 account_number: "RH-1",
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "an order whose symbol is not a string has no symbol, not a raise" do
      body = %{"id" => "o-1", "state" => "filled", "symbol" => %{}}

      assert {:ok, order} =
               Rest.get_order(@credentials, "o-1",
                 account_number: "RH-1",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert order.symbol == nil
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
                "https://trading.robinhood.com/api/v2/crypto/trading/trading_pairs/?cursor=2"
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

    test "the facade reaches it too, not only Rest" do
      # `DpExchange.Robinhood.quantization/2` threads `credentials/1` and `with_limiter/1`
      # into this call and no test had ever gone through it — every assertion above talks to
      # `Rest` directly. A delegate wired to the wrong `Rest` function, or one dropping the
      # limiter wrap, compiles and type-checks, and the whole suite stays green.
      #
      # Found by reading which lines of `DpExchange.Robinhood` the suite never executes.
      assert {:ok, quantum} =
               DpExchange.Robinhood.quantization("BTC-USD",
                 credentials: @credentials,
                 plug: responding(%{"results" => [@pair_row]}),
                 retry_attempts: 0
               )

      assert Decimal.equal?(quantum.quantity_increment, Decimal.new("0.00000001"))
      assert Decimal.equal?(quantum.price_increment, Decimal.new("0.01"))
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

  describe "get_top_of_book/3 — a book with no readable price is refused" do
    test "renamed fields refuse rather than returning bid: nil, ask: nil" do
      body = %{"results" => [%{"symbol" => "BTC-USD", "bid_price" => "1", "ask_price" => "2"}]}

      assert {:error, {:missing_required_field, :bid_ask}} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "NaN on both sides refuses, naming the first unreadable side" do
      body = %{"results" => [%{"symbol" => "BTC-USD", "bid" => "NaN", "ask" => "Inf"}]}

      assert {:error, {:invalid_decimal, :bid, "NaN"}} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "a present side that is unreadable or negative refuses, whichever side (MD6)" do
      for {bid, ask, expected} <- [
            {"", "2", {:invalid_decimal, :bid, ""}},
            {"1", "abc", {:invalid_decimal, :ask, "abc"}},
            {"-1", "2", {:invalid_decimal, :bid, "-1"}},
            {"1", "-2", {:invalid_decimal, :ask, "-2"}}
          ] do
        body = %{"results" => [%{"symbol" => "BTC-USD", "bid" => bid, "ask" => ask}]}

        assert {:error, ^expected} =
                 Rest.get_top_of_book("BTC-USD", @credentials,
                   plug: responding(body),
                   retry_attempts: 0
                 )
      end
    end

    test "one absent side is still a real one-sided book" do
      body = %{"results" => [%{"symbol" => "BTC-USD", "bid" => nil, "ask" => "2"}]}

      assert {:ok, %{bid: nil, ask: ask}} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(ask, Decimal.new(2))
    end

    test "a bid or ask of 0 means no resting order on that side: nil" do
      for zero <- ["0", "0.00", 0] do
        body = %{"results" => [%{"symbol" => "BTC-USD", "bid" => zero, "ask" => "2"}]}

        assert {:ok, %{bid: nil, ask: ask}} =
                 Rest.get_top_of_book("BTC-USD", @credentials,
                   plug: responding(body),
                   retry_attempts: 0
                 )

        assert Decimal.equal?(ask, Decimal.new(2))
      end

      # Both sides empty is a legitimately empty book, not a parser that stopped understanding.
      both = %{"results" => [%{"symbol" => "BTC-USD", "bid" => "0", "ask" => "0"}]}

      assert {:ok, %{bid: nil, ask: nil}} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(both),
                 retry_attempts: 0
               )
    end
  end

  describe "get_top_of_book_bulk/3 — the repeatable-symbol bulk form of best_bid_ask" do
    test "one signed request carries every symbol, via a repeated symbol param" do
      body = %{
        "results" => [
          %{"symbol" => "BTC-USD", "bid" => 77_840.0, "ask" => 77_850.0},
          %{"symbol" => "ETH-USD", "bid" => 3200.0, "ask" => 3201.0}
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
      # Exactly one request for both symbols — not one per symbol. The call has returned, so
      # a second request would already be in the mailbox.
      refute_received {:query, _second_request}

      assert top1.symbol == "BTC-USD"
      assert Decimal.equal?(top1.bid, Decimal.new("77840.00"))
      assert top2.symbol == "ETH-USD"
      assert Decimal.equal?(top2.ask, Decimal.new("3201.00"))
    end

    test "a results array shorter than requested is not an error and not a refusal" do
      # The vendor's document does not say what happens when one symbol in a batch is
      # delisted, unlisted or malformed. A `results` row simply absent for one of the
      # symbols asked for is silence about THAT symbol on THIS request, not a statement
      # the symbol does not exist — the same principle `result_for/2` already applies
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

    test "a row with an unreadable or negative side is dropped, not published as nil (MD6)" do
      body = %{
        "results" => [
          %{"symbol" => "BTC-USD", "bid" => "1", "ask" => "2"},
          %{"symbol" => "ETH-USD", "bid" => "NaN", "ask" => "3"},
          %{"symbol" => "LTC-USD", "bid" => "4", "ask" => "-5"}
        ]
      }

      assert {:ok, [top]} =
               Rest.get_top_of_book_bulk(["BTC-USD", "ETH-USD", "LTC-USD"], @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      # The refused rows are absent, so a poller never records those symbols as delivered
      # and its coverage lets them age out as uncovered.
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

    test "an unrequested symbol's row is dropped and a repeated one is returned once" do
      body = %{
        "results" => [
          %{"symbol" => "BTC-USD", "bid" => "1", "ask" => "2"},
          %{"symbol" => "DOGE-USD", "bid" => "5", "ask" => "6"},
          %{"symbol" => "BTC-USD", "bid" => "9", "ask" => "10"},
          %{"symbol" => "eth-usd", "bid" => "3", "ask" => "4"}
        ]
      }

      assert {:ok, [btc, eth]} =
               Rest.get_top_of_book_bulk(["BTC-USD", "ETH-USD"], @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert btc.symbol == "BTC-USD"
      assert Decimal.equal?(btc.bid, Decimal.new(1))
      assert eth.symbol == "ETH-USD"
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

    test "a row whose bid and ask are both unreadable is dropped, not published as empty" do
      body = %{
        "results" => [
          %{"symbol" => "BTC-USD", "bid" => "1", "ask" => "2"},
          %{"symbol" => "ETH-USD", "bid_price" => "3", "ask_price" => "4"},
          %{"symbol" => "LTC-USD", "bid" => "NaN", "ask" => ""}
        ]
      }

      assert {:ok, [top]} =
               Rest.get_top_of_book_bulk(["BTC-USD", "ETH-USD", "LTC-USD"], @credentials,
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
      # dp_exchange_core 0.3.52: a non-blocking request reserves with `acquire/3` and a zero
      # timeout (it never waits), where it used to `check/3` first and race other callers.
      def acquire(_provider, _weight, opts) do
        call = if Keyword.get(opts, :timeout) == 0, do: :acquire_without_waiting, else: :acquire
        Process.put(:rate_limiter_call, call)
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

    test "rate_limit_blocking: false, nil or omitted reaches Core.HttpClient as acquire/3 with no wait" do
      Config.put_override(:rate_limit_module, RecordingLimiter)

      for extra <- [[], [rate_limit_blocking: false], [rate_limit_blocking: nil]] do
        Process.delete(:rate_limiter_call)

        assert {:ok, _top} =
                 Rest.get_top_of_book(
                   "BTC-USD",
                   @credentials,
                   [plug: responding(quote_body()), retry_attempts: 0] ++ extra
                 )

        assert Process.get(:rate_limiter_call) == :acquire_without_waiting,
               "with #{inspect(extra)}"
      end
    end
  end

  describe "get_balances/2 asset_codes" do
    test "an entry that is not a non-blank string is refused before anything is signed" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:hit, conn.request_path})
        Req.Test.json(conn, %{"results" => []})
      end

      for bad <- [[nil], [""], ["BTC", 5], [%{}]] do
        assert {:error, {:invalid_field, :asset_codes}} =
                 Rest.get_balances(@credentials,
                   account_number: "RH-1",
                   asset_codes: bad,
                   plug: plug,
                   retry_attempts: 0
                 )
      end

      refute_received {:hit, _path}
    end
  end
end
