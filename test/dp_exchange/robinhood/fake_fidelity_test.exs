defmodule DpExchange.Robinhood.FakeFidelityTest do
  @moduledoc """
  The fake refuses what the real path refuses, from the real path's own rules, and the
  facade and the feed hand the rate limiter and its blocking flag to `Core.HttpClient`
  consistently even when a caller forwards `nil`.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Robinhood
  alias DpExchange.Robinhood.{Auth, Fake, Feed, Rest}

  @moduletag :capture_log

  @credentials %{api_key: "k", private_key: Base.encode64(:binary.copy(<<9>>, 32))}
  @account [account_number: "RH-1"]
  @order %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: "1"}

  defmodule RecordingLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, opts) do
      Process.put(:limiter_opts, opts)
      :ok
    end

    @impl true
    def check(_provider, _weight, opts) do
      Process.put(:limiter_opts, opts)
      :ok
    end

    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  describe "get_symbols ordering and non-atom feed names" do
    test "the fake lists symbols sorted, as Rest.get_symbols/2 does" do
      assert {:ok, symbols} = Fake.get_symbols(credentials: @credentials)
      assert symbols == Enum.sort(symbols)
    end

    test "a {:global, _} feed name that is not running answers empty instead of raising" do
      feed = {:global, {:robinhood_absent_feed, make_ref()}}

      assert Robinhood.coverage(feed: feed) == %{}
      assert Robinhood.wanted(feed: feed) == []
      assert Robinhood.coverage_by_kind(feed: feed) == %{}
    end
  end

  describe "credentials: the fake applies Auth's rules, not a shape check" do
    test "a blank api key is refused as missing, like the real signer" do
      bad = %{@credentials | api_key: "  "}

      assert Auth.validate_credentials(bad) == {:error, {:missing_credentials, :robinhood}}
      assert Fake.get_accounts(bad, []) == {:error, {:missing_credentials, :robinhood}}
      assert Fake.get_top_of_book("BTC-USD", credentials: bad) == Fake.get_accounts(bad, [])
    end

    test "a private key that is not the base64 32-byte seed is refused, like the real signer" do
      bad = %{@credentials | private_key: "not a seed"}
      expected = {:error, {:invalid_private_key, :not_base64}}

      assert Auth.validate_credentials(bad) == expected
      assert Fake.get_accounts(bad, []) == expected
      assert Fake.get_balances(bad, @account) == expected
    end

    test "a nil private key is missing credentials, as in the real signer" do
      bad = %{@credentials | private_key: nil}

      assert Fake.get_accounts(bad, []) == {:error, {:missing_credentials, :robinhood}}
      assert Auth.validate_credentials(bad) == {:error, {:missing_credentials, :robinhood}}
    end

    test "a private key of another type is not_a_string" do
      bad = %{@credentials | private_key: 5}

      assert Fake.get_accounts(bad, []) == {:error, {:invalid_private_key, :not_a_string}}
    end

    test "valid credentials pass both" do
      assert Auth.validate_credentials(@credentials) == :ok
      assert {:ok, _accounts} = Fake.get_accounts(@credentials, [])
    end
  end

  describe "place_order/3: the fake validates the order as Rest does, in the same order" do
    test "an empty request is refused with the field the real path names" do
      assert Rest.validate_order_request(%{}) == {:error, {:missing_field, :symbol}}
      assert Fake.place_order(@credentials, %{}, @account) == {:error, {:missing_field, :symbol}}
    end

    test "a limit order without a price is refused" do
      request = %{@order | order_type: :limit}

      assert Fake.place_order(@credentials, request, @account) ==
               {:error, {:missing_field, :price}}
    end

    test "an unsupported order type and an unrepresentable time in force are refused" do
      assert Fake.place_order(@credentials, %{@order | order_type: :trailing}, @account) ==
               {:error, {:unsupported_order_type, :trailing}}

      limit = Map.merge(@order, %{order_type: :limit, price: "1", time_in_force: :ioc})

      assert Fake.place_order(@credentials, limit, @account) ==
               {:error, {:unsupported_time_in_force, :ioc}}
    end

    test "the account is checked first and the credentials last" do
      assert Fake.place_order(%{}, %{}, []) == {:error, {:account_number_required, :robinhood}}
      assert Fake.place_order(%{}, %{}, @account) == {:error, {:missing_field, :symbol}}

      assert Fake.place_order(%{}, @order, @account) ==
               {:error, {:missing_credentials, :robinhood}}
    end

    test "place -> get -> cancel round-trips on a UUID id, a new one per order" do
      uuid = ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

      assert {:ok, first} = Fake.place_order(@credentials, @order, @account)
      assert {:ok, second} = Fake.place_order(@credentials, @order, @account)

      # `OrderResponse.id` is `format: uuid`, and unique per order.
      assert first.id =~ uuid
      assert second.id =~ uuid
      refute first.id == second.id

      assert {:ok, read} = Fake.get_order(@credentials, first.id, @account)
      assert read.id == first.id

      assert {:ok, cancelled} = Fake.cancel_order(@credentials, first.id, @account)
      assert cancelled.id == first.id
      assert cancelled.status == :cancelled
    end

    test "get_order, get_orders and cancel_order describe the order that was placed" do
      eth = %{
        symbol: "ETH-USD",
        side: :sell,
        order_type: :limit,
        quantity: "2",
        price: "3000",
        time_in_force: :gtc
      }

      assert {:ok, placed} = Fake.place_order(@credentials, eth, @account)
      assert {:ok, _other} = Fake.place_order(@credentials, @order, @account)

      assert {:ok, read} = Fake.get_order(@credentials, placed.id, @account)
      assert read.symbol == "ETH-USD"
      assert read.side == :sell
      assert Decimal.equal?(read.quantity, Decimal.new("2"))
      assert Decimal.equal?(read.price, Decimal.new("3000"))
      assert read.status == :open

      assert {:ok, [_eth, _btc]} = Fake.get_orders(@credentials, @account)
      assert {:ok, [listed]} = Fake.get_orders(@credentials, @account ++ [symbol: "eth-usd"])
      assert listed.id == placed.id

      assert {:ok, cancelled} = Fake.cancel_order(@credentials, placed.id, @account)
      assert cancelled.status == :cancelled
      assert cancelled.symbol == "ETH-USD"

      assert {:ok, %{status: :cancelled, symbol: "ETH-USD"}} =
               Fake.get_order(@credentials, placed.id, @account)

      assert {:ok, [still_open]} = Fake.get_orders(@credentials, @account ++ [state: "open"])
      refute still_open.id == placed.id
    end

    test "an id the fake never issued is the venue's 404, on a read and on a cancel" do
      assert Fake.get_order(@credentials, "never-issued", @account) ==
               {:refused, {:venue_error, 404}}

      assert Fake.cancel_order(@credentials, "never-issued", @account) ==
               {:refused, {:venue_error, 404}}
    end

    test "a valid order is still accepted as open" do
      assert Rest.validate_order_request(@order) == :ok
      assert {:ok, %{status: :open}} = Fake.place_order(@credentials, @order, @account)
    end
  end

  describe "symbols: the fake canonicalises as the real path does" do
    test "a lower-case listed symbol is served under its canonical name" do
      assert {:ok, book} = Fake.get_top_of_book("btc-usd", credentials: @credentials)
      assert book.symbol == "BTC-USD"
    end

    test "quantization refuses an unlisted symbol instead of inventing increments" do
      # The real venue's measured answer for an unlisted symbol, not an invented
      # `:not_listed` the real package never returns.
      assert Fake.quantization("NOPE-USD", credentials: @credentials) ==
               {:refused, {:venue_error, 400, "Invalid symbol: NOPE-USD"}}

      assert {:ok, _quantum} = Fake.quantization("btc-usd", credentials: @credentials)
    end
  end

  describe "get_orders/2: the :type and :state filters narrow as the venue's do" do
    test ":type narrows, taking the contract's :stop or the venue's stop_loss" do
      limit = Map.merge(@order, %{order_type: :limit, price: "1", time_in_force: :gtc})
      stop = Map.merge(@order, %{order_type: :stop, stop_price: "1", time_in_force: :gtc})

      assert {:ok, market} = Fake.place_order(@credentials, @order, @account)
      assert {:ok, limit} = Fake.place_order(@credentials, limit, @account)
      assert {:ok, stop} = Fake.place_order(@credentials, stop, @account)

      ids = fn filter ->
        {:ok, orders} = Fake.get_orders(@credentials, @account ++ filter)
        orders |> Enum.map(& &1.id) |> Enum.sort()
      end

      assert ids.(type: :market) == [market.id]
      assert ids.(type: "limit") == [limit.id]
      assert ids.(type: :stop) == [stop.id]
      assert ids.(type: "stop_loss") == [stop.id]
      assert ids.(type: :stop_limit) == []
      assert ids.([]) == Enum.sort([market.id, limit.id, stop.id])
    end

    test "a cancelled order is found under :cancelled and under :canceled" do
      assert {:ok, placed} = Fake.place_order(@credentials, @order, @account)
      assert {:ok, _cancelled} = Fake.cancel_order(@credentials, placed.id, @account)

      for state <- [:cancelled, :canceled, "canceled"] do
        assert {:ok, [found]} = Fake.get_orders(@credentials, @account ++ [state: state])
        assert found.id == placed.id
      end

      assert {:ok, []} = Fake.get_orders(@credentials, @account ++ [state: :open])
    end
  end

  describe "get_orders/2: date filters, :cursor and :limit" do
    test "created_at and updated_at windows narrow, for DateTimes and ISO 8601 strings" do
      assert {:ok, placed} = Fake.place_order(@credentials, @order, @account)

      past = DateTime.add(DateTime.utc_now(), -3_600, :second)
      future = DateTime.add(DateTime.utc_now(), 3_600, :second)

      ids = fn filter ->
        {:ok, orders} = Fake.get_orders(@credentials, @account ++ filter)
        Enum.map(orders, & &1.id)
      end

      assert ids.(created_at_start: past, created_at_end: future) == [placed.id]
      assert ids.(created_at_start: DateTime.to_iso8601(past)) == [placed.id]
      assert ids.(created_at_start: future) == []
      assert ids.(created_at_end: DateTime.to_iso8601(past)) == []
      assert ids.(updated_at_start: past, updated_at_end: future) == [placed.id]
      assert ids.(updated_at_start: DateTime.to_iso8601(future)) == []
    end

    test "a cancel moves updated_at but not created_at" do
      assert {:ok, placed} = Fake.place_order(@credentials, @order, @account)
      assert {:ok, cancelled} = Fake.cancel_order(@credentials, placed.id, @account)

      assert cancelled.created_at == placed.created_at
      assert DateTime.compare(cancelled.updated_at, placed.updated_at) != :lt
    end

    test "an unparseable date string is refused exactly as Rest refuses it" do
      for key <- [:created_at_start, :created_at_end, :updated_at_start, :updated_at_end] do
        opts = @account ++ [{key, "yesterday"}]

        assert Fake.get_orders(@credentials, opts) == {:error, {:invalid_field, key}}
        assert Rest.validate_order_filters(opts) == {:error, {:invalid_field, key}}
      end
    end

    test "a cursor is refused, the fake having issued none; :limit changes nothing" do
      assert {:ok, placed} = Fake.place_order(@credentials, @order, @account)

      assert Fake.get_orders(@credentials, @account ++ [cursor: "page-2"]) ==
               {:error, {:invalid_field, :cursor}}

      assert {:ok, [only]} = Fake.get_orders(@credentials, @account ++ [limit: 1])
      assert only.id == placed.id
    end
  end

  describe "subscribe/2: a symbol the venue does not list is refused, as the feed refuses it" do
    test "the refusal is delivered and the symbol is not covered" do
      :ok = Fake.subscribe(["nope-usd", "BTC-USD"])

      assert_receive {:dp_exchange, :robinhood,
                      {:refused, "NOPE-USD", {:venue_error, 400, "Invalid symbol: NOPE-USD"}}},
                     5_000

      assert_receive {:dp_exchange, :robinhood, %DpExchange.Core.Types.TopOfBook{}}, 5_000
      assert Fake.coverage() == %{"BTC-USD" => :internal_poll}
    end
  end

  describe "get_balances/2: :asset_codes narrows the holdings, not only the cash" do
    test "asking for an asset the fake does not hold returns no holding" do
      opts = @account ++ [asset_codes: ["ETH"]]

      assert {:ok, []} = Fake.get_balances(@credentials, opts)
    end

    test "asking for BTC returns the holding without the cash row" do
      opts = @account ++ [asset_codes: ["BTC"]]

      assert {:ok, [holding]} = Fake.get_balances(@credentials, opts)
      assert holding.currency == "BTC"
    end

    test "asking for the cash currency returns only the cash row" do
      assert {:ok, [cash]} = Fake.get_balances(@credentials, @account ++ [asset_codes: "USD"])
      assert cash.currency == "USD"
    end

    test "no narrowing returns both" do
      assert {:ok, [_holding, _cash]} = Fake.get_balances(@credentials, @account)
    end

    test "an entry that is not a non-blank string is refused, as Rest refuses it" do
      for bad <- [[nil], [""], ["BTC", 5], [%{}], "  "] do
        opts = @account ++ [asset_codes: bad]

        assert {:error, {:invalid_field, :asset_codes}} = Fake.get_balances(@credentials, opts)
        assert {:error, {:invalid_field, :asset_codes}} = Rest.asset_codes(opts)
      end
    end
  end

  describe "place_order/3: client_order_id is an idempotency key, as on the venue" do
    test "re-sending the same key returns the original order, not a second one" do
      key = "11111111-2222-4333-a444-555555555555"
      request = Map.put(@order, :client_order_id, key)

      assert {:ok, first} = Fake.place_order(@credentials, request, @account)
      assert {:ok, second} = Fake.place_order(@credentials, request, @account)

      assert second.id == first.id
      assert {:ok, [_only_one]} = Fake.get_orders(@credentials, @account)
    end

    test "the key may travel in opts, and the original shows a cancel made since" do
      opts = @account ++ [client_order_id: "11111111-2222-4333-a444-555555555556"]

      assert {:ok, first} = Fake.place_order(@credentials, @order, opts)
      assert {:ok, _cancelled} = Fake.cancel_order(@credentials, first.id, @account)
      assert {:ok, again} = Fake.place_order(@credentials, @order, opts)

      assert again.id == first.id
      assert again.status == :cancelled
    end

    test "no key, or a different key, places a new order each time" do
      assert {:ok, one} = Fake.place_order(@credentials, @order, @account)
      assert {:ok, two} = Fake.place_order(@credentials, @order, @account)
      assert one.id != two.id

      keyed = Map.put(@order, :client_order_id, "11111111-2222-4333-a444-555555555557")
      other = Map.put(@order, :client_order_id, "11111111-2222-4333-a444-555555555558")
      assert {:ok, three} = Fake.place_order(@credentials, keyed, @account)
      assert {:ok, four} = Fake.place_order(@credentials, other, @account)
      assert three.id != four.id
    end

    test "a UUID differing only in case is the same key" do
      lower = Map.put(@order, :client_order_id, "abcdefab-2222-4333-a444-555555555559")
      upper = Map.put(@order, :client_order_id, "ABCDEFAB-2222-4333-A444-555555555559")

      assert {:ok, first} = Fake.place_order(@credentials, lower, @account)
      assert {:ok, again} = Fake.place_order(@credentials, upper, @account)
      assert again.id == first.id
    end

    test "a key that is not a UUID is refused, as Rest refuses it" do
      request = Map.put(@order, :client_order_id, "not-a-uuid")

      assert {:error, {:invalid_field, :client_order_id}} =
               Fake.place_order(@credentials, request, @account)

      assert {:error, {:invalid_field, :client_order_id}} =
               Rest.supplied_client_order_id(request, @account)

      assert {:ok, nil} = Rest.supplied_client_order_id(@order, @account)
      assert {:ok, nil} = Rest.supplied_client_order_id(@order, client_order_id: "")
    end

    test "credentials with a trailing newline are refused by field name" do
      bad = %{@credentials | api_key: "k\n"}

      assert {:error, {:invalid_api_key, :surrounding_whitespace_or_control_characters}} =
               Fake.place_order(bad, @order, @account)
    end
  end

  describe "the facade names this venue's limiter even for a forwarded `limiter: nil`" do
    test "a REST call reaches the limiter under the supervisor's name" do
      Config.put_override(:rate_limit_module, RecordingLimiter)

      row = %{"symbol" => "BTC-USD", "bid" => "1", "ask" => "2"}
      plug = fn conn -> Req.Test.json(conn, %{"results" => [row]}) end

      assert {:ok, _book} =
               Robinhood.get_top_of_book("BTC-USD",
                 credentials: @credentials,
                 plug: plug,
                 retry_attempts: 0,
                 limiter: nil
               )

      assert Keyword.get(Process.get(:limiter_opts), :limiter) ==
               DpExchange.Robinhood.Supervisor.limiter_name([])
    end
  end

  describe "the feed's request options" do
    defp request_opts(extra) do
      name = :"feed_#{System.unique_integer([:positive])}"

      base = [name: name, credentials: @credentials, symbols: [], start_delay_ms: 600_000]
      {:ok, pid} = Feed.start_link(base ++ extra)

      on_exit(fn ->
        try do
          GenServer.stop(pid, :normal)
        catch
          :exit, _reason -> :ok
        end
      end)

      :sys.get_state(pid).request_opts
    end

    test "a forwarded `rate_limit_blocking: nil` still defaults to blocking" do
      assert request_opts(rate_limit_blocking: nil)[:rate_limit_blocking] == true
    end

    test "an explicit `rate_limit_blocking: false` is honoured" do
      assert request_opts(rate_limit_blocking: false)[:rate_limit_blocking] == false
    end

    test "`:timeout` and `:log_requests` reach the poll's requests" do
      opts = request_opts(timeout: 4_321, log_requests: false)

      assert opts[:timeout] == 4_321
      assert opts[:log_requests] == false
    end
  end
end
