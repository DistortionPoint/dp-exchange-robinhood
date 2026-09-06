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

    test "top_of_book is streamable even though there is no stream" do
      # The claim §6.0 makes: both endpoints always exist. What arrives is identical to a
      # socket venue's; only `coverage/1` says how. Not `:quotes` — this venue has no
      # last-trade endpoint at all, see `get_price/2`'s entry in `venue_does_not_serve/0`.
      assert :top_of_book in Robinhood.capabilities().streamable
      refute :quotes in Robinhood.capabilities().streamable
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
      assert {:get_price, 2} in Robinhood.venue_does_not_serve()
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

    test "subscribe_notices registers against a running feed", %{name: name} do
      assert Robinhood.subscribe_notices(feed: name) == :ok
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

    test "subscribing to notices says so too, rather than answering :ok with nothing behind it" do
      assert Robinhood.subscribe_notices(feed: :no_such_feed) == {:error, :feed_not_started}
    end
  end

  # Regression for the defect this fix closes: `subscribe_notices/1` used to answer `:ok`
  # unconditionally and never touch the feed at all — a caller registering a pid here got
  # `:ok` back and then nothing, ever, because the only pid the feed would ever send a
  # `Core.Notice` to was the fixed `:subscriber` named at `Feed.start_link/1`. Against the
  # PRE-FIX facade, the second test below fails: `assert_receive` times out, because the
  # old `subscribe_notices/1` discarded `to: self()` instead of registering it anywhere.
  describe "subscribe_notices/1 registers through the facade, not just Feed.start_link/1's :subscriber" do
    defp permissive_notice_limiter do
      name = :"rh_notice_limiter_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        DpExchange.Core.DefaultRateLimiter.start_link(
          name: name,
          limits: %{default: %{limit: 1_000, per_ms: 1_000, burst: 1_000}}
        )

      name
    end

    defp responding_error do
      fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"detail" => "boom"}))
      end
    end

    test "a pid registered ONLY through DpExchange.Robinhood.subscribe_notices/1 receives a coverage-outage notice" do
      unique = System.unique_integer([:positive])
      name = :"rh_notice_regression_feed_#{unique}"

      # A live pid that relays nothing, ever — deliberately NOT this test process. If the
      # notice below still reaches the test process, it can only have arrived through the
      # facade's own registry, not through this feed's fixed `:subscriber`. Without this,
      # omitting `:subscriber` would default it to whichever process happened to call
      # `start_link/1` and make the test pass for the wrong reason.
      inert_subscriber = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(inert_subscriber, :kill) end)

      {:ok, _feed} =
        Feed.start_link(
          name: name,
          subscriber: inert_subscriber,
          credentials: @credentials,
          symbols: ["BTC-USD"],
          start_delay_ms: 0,
          interval_ms: 40,
          retry_attempts: 0,
          limiter: permissive_notice_limiter(),
          plug: responding_error()
        )

      assert Robinhood.subscribe_notices(to: self(), feed: name) == :ok

      assert_receive {:dp_exchange, :robinhood,
                      %DpExchange.Core.Notice{kind: :coverage_change, severity: :warning} =
                        notice},
                     500

      assert notice.message =~ "delivered nothing"
    end
  end

  describe "market data without credentials refuses before any request" do
    test "get_top_of_book and get_symbols both refuse" do
      assert Robinhood.get_top_of_book("BTC-USD") == {:error, {:missing_credentials, :robinhood}}
      assert Robinhood.get_symbols() == {:error, {:missing_credentials, :robinhood}}
    end

    test "get_price is unsupported regardless of credentials" do
      assert Robinhood.get_price("BTC-USD") == {:error, :not_supported}
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
      assert Fake.get_top_of_book("BTC-USD") == {:refused, :missing_credentials}
      assert Fake.get_symbols() == {:refused, :missing_credentials}
    end

    test "get_price is unsupported regardless of credentials, matching the real venue" do
      # This used to answer with a Quote whose price fell back to the ask — mirroring a
      # fallback in the real adapter that was removed. A fake that reproduces a defect
      # makes the defect untestable, the suite agrees with itself and both are wrong.
      # DpCryptoManagement's issue #21 is what happens when that removal only landed in
      # the real package: the fake kept answering, so nothing here caught that `get_price`
      # had become permanently non-functional against the real venue's response shape.
      assert Fake.get_price("BTC-USD", credentials: @credentials) == {:error, :not_supported}
    end

    test "the book comes back from the fake's get_top_of_book/2" do
      assert {:ok, top} = Fake.get_top_of_book("BTC-USD", credentials: @credentials)

      assert Decimal.lt?(top.bid, top.ask)
    end

    test "coverage reports :internal_poll, never :stream" do
      # The one place a consumer can see this venue has no socket — and it is visible as
      # what is arriving, not as how.
      :ok = Fake.subscribe(["BTC-USD"], to: self())

      assert Fake.coverage() == %{"BTC-USD" => :internal_poll}
      assert_receive {:dp_exchange, :robinhood, %DpExchange.Core.Types.TopOfBook{}}
    end

    test "coverage_by_kind reports a delivering symbol under :top_of_book" do
      # This fake's `get_top_of_book/2` produces exclusively `Types.TopOfBook`, so a
      # symbol that delivers a quote must appear under `:top_of_book` here — the same
      # struct-derived fact `coverage/1` already reports, split by kind.
      :ok = Fake.subscribe(["BTC-USD"], to: self())

      assert Fake.coverage_by_kind() == %{top_of_book: %{"BTC-USD" => :internal_poll}}
      assert_receive {:dp_exchange, :robinhood, %DpExchange.Core.Types.TopOfBook{}}
    end

    test "coverage_by_kind's symbol union equals coverage/1's keys exactly" do
      # The family-wide invariant: whatever `coverage/1` reports, `coverage_by_kind/1`'s
      # values must union back to precisely the same symbol set — never more, never
      # fewer.
      :ok = Fake.subscribe(["BTC-USD", "ETH-USD"], to: self())

      coverage_symbols = Fake.coverage() |> Map.keys() |> MapSet.new()

      union =
        Fake.coverage_by_kind()
        |> Map.values()
        |> Enum.flat_map(&Map.keys/1)
        |> MapSet.new()

      assert union == coverage_symbols
    end

    test "the one kind reported is declared streamable" do
      :ok = Fake.subscribe(["BTC-USD"], to: self())

      reported_kinds = Fake.coverage_by_kind() |> Map.keys() |> MapSet.new()
      declared = MapSet.new(Robinhood.capabilities().streamable)

      assert MapSet.subset?(reported_kinds, declared)
    end

    test "coverage_by_kind has exactly one key — a single-kind venue is a single-key map" do
      # Robinhood streams only one kind, delivered by poll. Documenting the map's shape
      # directly: this is the honest, structurally-derived answer for a venue with one
      # delivery path, not an accident of only writing one branch.
      :ok = Fake.subscribe(["BTC-USD"], to: self())

      assert Map.keys(Fake.coverage_by_kind()) == [:top_of_book]
    end

    test "unsubscribe and update_symbols narrow coverage" do
      :ok = Fake.subscribe(["BTC-USD", "ETH-USD"], to: self())
      :ok = Fake.update_symbols(["BTC-USD"])
      assert Fake.coverage() == %{"BTC-USD" => :internal_poll}

      :ok = Fake.unsubscribe(["BTC-USD"])
      assert Fake.coverage() == %{}
    end

    test "an unlisted symbol is refused, and subscribing to one pushes nothing" do
      assert Fake.get_top_of_book("NOPE-USD", credentials: @credentials) ==
               {:refused, :not_listed}

      :ok = Fake.subscribe(["NOPE-USD"], to: self())
      assert Fake.coverage() == %{}
      refute_receive {:dp_exchange, :robinhood, _anything}, 50
    end

    test "everything the venue does not serve says so" do
      assert Fake.get_historical_prices("BTC-USD", "1d", [], []) == {:error, :not_supported}
      assert Fake.get_order_book("BTC-USD", []) == {:error, :not_supported}
      assert Fake.get_market_overview([]) == {:error, :not_supported}
      assert Fake.list_instruments([]) == {:error, :not_supported}
      # The account, order and holdings surface landed on 2026-09-01. What refuses now is a
      # v2 call without the account number v2 requires, which is a different assertion and
      # a better one: it is the shape of the mistake a v1 habit produces.
      assert Fake.get_balances(@credentials, []) ==
               {:error, {:account_number_required, :robinhood}}

      assert {:ok, [_account]} = Fake.get_accounts(@credentials, [])

      assert Fake.place_order(@credentials, %{}, []) ==
               {:error, {:account_number_required, :robinhood}}

      # `:open`, not `:cancelled`: the venue acknowledges the request and reports no outcome.
      assert {:ok, %{status: :open}} = Fake.cancel_order(@credentials, "id", [])

      assert Fake.get_order(@credentials, "id", []) ==
               {:error, {:account_number_required, :robinhood}}

      assert Fake.get_orders(@credentials, []) ==
               {:error, {:account_number_required, :robinhood}}

      assert Fake.get_trade_history(@credentials, []) == {:error, :not_supported}
      assert Fake.test_connection(@credentials, []) == {:error, :not_supported}
      assert Fake.get_rate_limit_status(@credentials, []) == {:error, :not_supported}
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
    {:get_top_of_book, 2} => ["BTC-USD", []],
    {:get_price, 2} => ["BTC-USD", []]
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
