defmodule DpExchange.RobinhoodTest do
  use ExUnit.Case, async: false

  alias DpExchange.Core.{Capabilities, Venue}
  alias DpExchange.Robinhood
  alias DpExchange.Robinhood.{Fake, Feed, Supervisor}

  @moduletag :capture_log

  @credentials %{api_key: "k", private_key: Base.encode64(:binary.copy(<<5>>, 32))}

  describe "the declaration" do
    test "names every callback exactly once" do
      declared = Robinhood.capabilities().endpoints |> Map.keys() |> Enum.sort()

      assert declared == Enum.sort(Venue.behaviour_info(:callbacks))
    end

    test "an endpoint declared :unsupported actually returns the atom" do
      for {{name, arity}, :unsupported} <- Robinhood.capabilities().endpoints do
        assert apply(Robinhood, name, unsupported_args(name, arity)) == {:error, :not_supported},
               "#{name}/#{arity} is declared :unsupported but did not say so"
      end
    end

    test "the FAKE says the same thing, for every declared-unsupported endpoint" do
      # The facade sweep above proves the real module agrees with its declaration. This
      # proves the fake does too — and it matters more than it looks: a consumer's test
      # suite runs against the fake, so a fake that answered differently would let a
      # consumer write a passing test against behaviour the real package does not have.
      #
      # It also keeps the stubs honest. Thirty-three callbacks arrived with Core 0.1.16 and
      # are declared, not implemented; without this they are uncovered lines that nothing
      # would notice going wrong.
      for {{name, arity}, :unsupported} <- Robinhood.capabilities().endpoints do
        assert apply(Robinhood.Fake, name, unsupported_args(name, arity)) ==
                 {:error, :not_supported},
               "#{name}/#{arity} is declared :unsupported but the fake did not say so"
      end
    end

    test "credentials are required — every call is signed, quotes included" do
      assert Robinhood.capabilities().credential_benefit == :required
    end

    test "historical_timeframes is EMPTY, because the venue publishes no candle endpoint" do
      # An empty list is the honest answer. A populated one with an :unsupported endpoint
      # behind it would be a declaration disagreeing with itself.
      assert Robinhood.capabilities().historical_timeframes == []
      assert Robinhood.capabilities().endpoints[{:get_historical_prices, 4}] == :unsupported
    end

    test "quotes are streamable even though there is no stream" do
      # The claim §6.0 makes: both endpoints always exist. What arrives is identical to a
      # socket venue's; only `coverage/1` says how.
      assert :quotes in Robinhood.capabilities().streamable
      assert Robinhood.capabilities().endpoints[{:subscribe, 2}] == :experimental
    end

    test "no trade volume is reported" do
      refute Robinhood.capabilities().reports_trade_volume
    end

    test "provenance separates what was read here from what was inherited" do
      caps = Robinhood.capabilities()

      assert caps.measured_at == ~D[2026-08-28]
      assert caps.measured_against =~ "INHERITED"
      assert caps.measured_against =~ "NOT probed"
    end

    test "the declaration survives Capabilities' own validation" do
      assert %Capabilities{} = Robinhood.capabilities()
    end
  end

  describe "what the venue does not serve, versus what is not ported" do
    test "the two are told apart, because they mean different things" do
      # A caller acts the same way on either, but anyone deciding what to build next needs
      # to know which is which.
      assert {:get_historical_prices, 4} in Robinhood.venue_does_not_serve()
      assert {:get_order_book, 2} in Robinhood.venue_does_not_serve()
      refute {:place_order, 3} in Robinhood.venue_does_not_serve()
    end

    test "everything named there is genuinely unsupported" do
      for endpoint <- Robinhood.venue_does_not_serve() do
        assert Robinhood.capabilities().endpoints[endpoint] == :unsupported
      end
    end
  end

  describe "identity" do
    test "provider is the atom, everywhere" do
      assert Robinhood.runtime_id() == :robinhood
      assert Robinhood.provider_name() == "Robinhood"
      assert Robinhood.asset_classes() == [:crypto]
      assert Robinhood.market_status([]) == {:ok, :open}
      assert "USD" in Robinhood.quotes()
    end
  end

  describe "the feed is a poll, and the facade routes to it" do
    setup do
      unique = System.unique_integer([:positive])
      name = :"rh_feed_#{unique}"

      # No symbols and a long start delay: this asserts routing, not fetching, and a fetch
      # would reach the venue.
      {:ok, feed} = Feed.start_link(name: name, symbols: [], start_delay_ms: 60_000)

      {:ok, feed: feed, name: name}
    end

    test "subscribe adds to the polled set", %{name: name} do
      assert :ok = Robinhood.subscribe(["BTC-USD"], feed: name)
    end

    test "unsubscribe and update_symbols route too", %{name: name} do
      assert :ok = Robinhood.update_symbols(["BTC-USD", "ETH-USD"], feed: name)
      assert :ok = Robinhood.unsubscribe(["ETH-USD"], feed: name)
    end

    test "coverage is empty until something actually arrives", %{name: name} do
      :ok = Robinhood.subscribe(["BTC-USD"], feed: name)

      # Observed, never intended. A symbol that has been asked for and never answered is
      # absent, because reporting it covered would assert a delivery that never happened.
      assert Robinhood.coverage(feed: name) == %{}
    end

    test "subscribe_notices always answers" do
      assert Robinhood.subscribe_notices([]) == :ok
    end
  end

  describe "the facade without a started feed" do
    test "subscribing says so rather than silently doing nothing" do
      assert Robinhood.subscribe(["BTC-USD"], feed: :no_such_feed) == {:error, :feed_not_started}

      assert Robinhood.update_symbols(["BTC-USD"], feed: :no_such_feed) ==
               {:error, :feed_not_started}
    end

    test "unsubscribing from nothing is :ok" do
      assert Robinhood.unsubscribe(["BTC-USD"], feed: :no_such_feed) == :ok
    end

    test "coverage is an empty map, not a crash" do
      assert Robinhood.coverage(feed: :no_such_feed) == %{}
    end
  end

  describe "market data without credentials refuses before any request" do
    test "get_price and get_symbols both refuse" do
      assert Robinhood.get_price("BTC-USD") == {:error, {:missing_credentials, :robinhood}}
      assert Robinhood.get_symbols() == {:error, {:missing_credentials, :robinhood}}
    end
  end

  describe "the supervision tree" do
    test "starts a limiter and a feed" do
      unique = System.unique_integer([:positive])

      opts = [
        name: :"sup_#{unique}",
        feed: :"sfeed_#{unique}",
        limiter: :"slim_#{unique}",
        symbols: [],
        start_delay_ms: 60_000
      ]

      assert {:ok, pid} = Robinhood.start_link(opts)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)

      assert length(Elixir.Supervisor.which_children(pid)) == 2
    end

    test "names default and are overridable" do
      assert Supervisor.limiter_name([]) == DpExchange.Robinhood.RateLimiter
      assert Supervisor.feed_name([]) == Feed
      assert Supervisor.limiter_name(limiter: :mine) == :mine
      assert Supervisor.feed_name(feed: :mine) == :mine
    end

    test "child_spec/1 takes its id from the name" do
      assert %{id: :custom} = Robinhood.child_spec(name: :custom)
      assert %{id: DpExchange.Robinhood} = Robinhood.child_spec([])
    end
  end

  describe "the fake" do
    test "refuses market data without credentials, as the real venue does" do
      assert Fake.get_price("BTC-USD") == {:refused, :missing_credentials}
      assert Fake.get_symbols() == {:refused, :missing_credentials}
    end

    test "answers with credentials, and the price is a traded price" do
      # This asserted `price == ask` until 2026-08-31, mirroring a fallback in the real
      # adapter that Phase 1 removed. A fake that reproduces a defect makes the defect
      # untestable — the suite agrees with itself and both are wrong.
      assert {:ok, quote_struct} = Fake.get_price("BTC-USD", credentials: @credentials)

      assert quote_struct.price
      assert quote_struct.volume == nil
      refute Map.has_key?(quote_struct, :ask)
    end

    test "the book comes back from the fake's get_top_of_book/2, straddling the price" do
      assert {:ok, quote_struct} = Fake.get_price("BTC-USD", credentials: @credentials)
      assert {:ok, top} = Fake.get_top_of_book("BTC-USD", credentials: @credentials)

      assert Decimal.lt?(top.bid, top.ask)
      # The traded price sits inside the spread and equals neither side, so a test that
      # passes only when they coincide fails here.
      assert Decimal.lt?(top.bid, quote_struct.price)
      assert Decimal.lt?(quote_struct.price, top.ask)
    end

    test "coverage reports :internal_poll, never :stream" do
      # The one place a consumer can see this venue has no socket — and it is visible as
      # what is arriving, not as how.
      :ok = Fake.subscribe(["BTC-USD"], to: self())

      assert Fake.coverage() == %{"BTC-USD" => :internal_poll}
      assert_receive {:dp_exchange, :robinhood, %DpExchange.Core.Types.Quote{}}
    end

    test "unsubscribe and update_symbols narrow coverage" do
      :ok = Fake.subscribe(["BTC-USD", "ETH-USD"], to: self())
      :ok = Fake.update_symbols(["BTC-USD"])
      assert Fake.coverage() == %{"BTC-USD" => :internal_poll}

      :ok = Fake.unsubscribe(["BTC-USD"])
      assert Fake.coverage() == %{}
    end

    test "an unlisted symbol is refused, and subscribing to one pushes nothing" do
      assert Fake.get_price("NOPE-USD", credentials: @credentials) == {:refused, :not_listed}

      :ok = Fake.subscribe(["NOPE-USD"], to: self())
      assert Fake.coverage() == %{}
      refute_receive {:dp_exchange, :robinhood, _anything}, 50
    end

    test "everything the venue does not serve says so" do
      assert Fake.get_historical_prices("BTC-USD", "1d", [], []) == {:error, :not_supported}
      assert Fake.get_order_book("BTC-USD", []) == {:error, :not_supported}
      assert Fake.get_market_overview([]) == {:error, :not_supported}
      assert Fake.list_instruments([]) == {:error, :not_supported}
      assert Fake.get_balances(@credentials, []) == {:error, :not_supported}
      assert Fake.get_accounts(@credentials, []) == {:error, :not_supported}
      assert Fake.get_fees(@credentials, []) == {:error, :not_supported}
      assert Fake.get_transfers(@credentials, []) == {:error, :not_supported}
      assert Fake.place_order(@credentials, %{}, []) == {:error, :not_supported}
      assert Fake.cancel_order(@credentials, "id", []) == {:error, :not_supported}
      assert Fake.get_order(@credentials, "id", []) == {:error, :not_supported}
      assert Fake.get_orders(@credentials, []) == {:error, :not_supported}
      assert Fake.get_trade_history(@credentials, []) == {:error, :not_supported}
      assert Fake.test_connection(@credentials, []) == {:error, :not_supported}
      assert Fake.get_rate_limit_status(@credentials, []) == {:error, :not_supported}
      assert Fake.quantization("BTC-USD") == {:error, :not_supported}
    end

    test "it declares the real venue's capabilities and starts nothing" do
      assert Fake.capabilities() == Robinhood.capabilities()
      assert Fake.start_link([]) == :ignore
      assert %{id: :fake} = Fake.child_spec(name: :fake)
      assert Fake.provider_name() == "Robinhood"
      assert Fake.runtime_id() == :robinhood
      assert Fake.asset_classes() == [:crypto]
      assert Fake.market_status([]) == {:ok, :open}
      assert Fake.subscribe_notices([]) == :ok
    end
  end

  # Argument shapes for the declared-unsupported sweep. A lookup rather than a case, so a
  # callback added to the facade adds a row instead of a branch.
  @wide_facade_args %{
    {:withdraw, 5} => ["BTC", "bitcoin", :one, "addr", []],
    {:estimate_withdrawal_fee, 4} => ["BTC", "bitcoin", :one, []],
    {:quote_conversion, 4} => ["BTC", "USD", :one, []],
    {:get_deposit_address, 3} => ["BTC", "bitcoin", []],
    {:create_watchlist, 3} => ["name", [], []],
    {:get_financials, 3} => ["BTC-USD", :balance_sheet, []],
    {:rename_account, 3} => ["id", "name", []],
    {:stake, 3} => ["BTC", :one, []],
    {:unstake, 3} => ["BTC", :one, []],
    {:get_funding, 2} => ["BTC-USD", []],
    {:get_contract_stats, 2} => ["BTC-USD", []],
    {:get_option_chain, 2} => ["BTC-USD", []],
    {:get_option_expirations, 2} => ["BTC-USD", []],
    {:get_option_greeks, 2} => ["id", []],
    {:get_watchlist, 2} => ["id", []],
    {:update_watchlist, 2} => ["id", []],
    {:delete_watchlist, 2} => ["id", []],
    {:get_filings, 2} => ["id", []],
    {:get_screener, 2} => ["id", []],
    {:commit_conversion, 2} => ["id", []],
    {:get_conversion, 2} => ["id", []],
    {:get_top_of_book, 2} => ["BTC-USD", []]
  }

  defp unsupported_args(name, arity) do
    case Map.fetch(@wide_facade_args, {name, arity}) do
      {:ok, args} ->
        Enum.map(args, fn
          :one -> Decimal.new("1")
          other -> other
        end)

      :error ->
        legacy_args(name, arity)
    end
  end

  defp legacy_args(name, arity) do
    case {name, arity} do
      {:quantization, 1} -> ["BTC-USD"]
      {:get_historical_prices, 4} -> ["BTC-USD", "1d", [], []]
      {:get_order_book, 2} -> ["BTC-USD", []]
      {:place_order, 3} -> [@credentials, %{}, []]
      # Every other arity-4 callback takes credentials, an id, a change map and opts.
      {_name, 4} -> [@credentials, "id", %{}, []]
      {_name, 3} -> [@credentials, "id", []]
      {_name, 2} -> [@credentials, []]
      {_name, 1} -> [[]]
    end
  end
end
