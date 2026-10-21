defmodule DpExchange.Robinhood.TickAqTest do
  @moduledoc """
  Tick AQ: numbers and identifiers from venue text (S), configuration and start-up (T), and
  unbounded state (U).

    * An order amount is sent in full notation, never rounded, and refused past what the vendor
      documents (18 fractional digits) or the family bounds (34 digits); a venue number past 34
      digits is unreadable, not a number to compute with.
    * A symbol is validated before it is signed into a request line, and a wanted set past a
      bound is refused.
    * A tree that could never poll (a malformed Ed25519 seed, an unknown or mistyped option, a
      cleartext `base_url`) refuses to start instead of starting and failing every cycle.
    * Subscribers are bounded, a refused call keeps nothing (not even a monitor), and an
      add/remove cycle returns the feed's state, and its poller's, to where it began.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Robinhood
  alias DpExchange.Robinhood.{Credentials, Fake, Feed, Rest}
  alias DpExchange.Robinhood.Supervisor, as: RobinhoodSupervisor

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
  @account [account_number: "RH-1"]
  @market %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: "1"}

  @digits_34 String.duplicate("9", 34)
  @digits_35 String.duplicate("9", 35)
  @digits_40 String.duplicate("9", 40)

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp responding(body), do: fn conn -> Req.Test.json(conn, body) end

  # --- S: an amount the venue's limits make impossible is refused, never sent or rounded ----

  describe "an order amount is bounded by what the vendor documents" do
    test "18 fractional digits are the most: the 18th is sent as written, the 19th is refused" do
      eighteen = "0." <> String.duplicate("0", 17) <> "1"
      nineteen = "0." <> String.duplicate("0", 18) <> "1"

      assert {:ok, %{quantity: ^eighteen}} =
               Rest.normalize_order_request(%{@market | quantity: eighteen})

      assert Rest.normalize_order_request(%{@market | quantity: nineteen}) ==
               {:error, {:invalid_quantity, nineteen}}

      # In scientific notation, as a Decimal, and with trailing zeros: the same verdict. Padding
      # is not stripped for the caller, whose value `"0.1"` is what to send.
      assert {:ok, %{quantity: ^eighteen}} =
               Rest.normalize_order_request(%{@market | quantity: "1e-18"})

      assert {:error, {:invalid_quantity, "1e-19"}} =
               Rest.normalize_order_request(%{@market | quantity: "1e-19"})

      decimal = Decimal.new(nineteen)

      assert Rest.normalize_order_request(%{@market | quantity: decimal}) ==
               {:error, {:invalid_quantity, decimal}}

      padded = "0.1" <> String.duplicate("0", 18)

      assert Rest.normalize_order_request(%{@market | quantity: padded}) ==
               {:error, {:invalid_quantity, padded}}
    end

    test "34 digits in all are the most, whole or fractional" do
      assert {:ok, %{quantity: @digits_34}} =
               Rest.normalize_order_request(%{@market | quantity: @digits_34})

      assert Rest.normalize_order_request(%{@market | quantity: @digits_35}) ==
               {:error, {:invalid_quantity, @digits_35}}

      # 20 whole + 15 fractional digits is 35.
      mixed = String.duplicate("9", 20) <> "." <> String.duplicate("9", 15)

      assert Rest.normalize_order_request(%{@market | quantity: mixed}) ==
               {:error, {:invalid_quantity, mixed}}
    end

    test "the price and the stop price are judged the same way, under their own tags" do
      too_fine = "0." <> String.duplicate("0", 18) <> "1"
      limit = Map.merge(@market, %{order_type: :limit, time_in_force: :gtc})
      stop = Map.merge(@market, %{order_type: :stop, time_in_force: :gtc})

      assert Rest.normalize_order_request(Map.put(limit, :price, too_fine)) ==
               {:error, {:invalid_price, too_fine}}

      assert Rest.normalize_order_request(Map.put(stop, :stop_price, @digits_35)) ==
               {:error, {:invalid_stop_price, @digits_35}}
    end

    test "the Fake and the estimate request refuse exactly what the real path refuses" do
      too_fine = "0." <> String.duplicate("0", 18) <> "1"
      request = %{@market | quantity: too_fine}
      expected = Rest.normalize_order_request(request)

      assert {:error, {:invalid_quantity, ^too_fine}} = expected
      assert Fake.place_order(@credentials, request, @account) == expected

      assert Rest.estimate_request("BTC-USD", :ask, too_fine) ==
               {:error, {:invalid_field, :quantity}}

      assert Fake.get_estimated_price("BTC-USD", :ask, too_fine, @credentials) ==
               {:error, {:invalid_field, :quantity}}
    end

    test "nothing is sent for a refused amount, and an accepted one is not rounded" do
      test_pid = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:sent, raw})
        Req.Test.json(conn, %{"id" => "o-1"})
      end

      opts = @account ++ [plug: plug, retry_attempts: 0]
      too_fine = "0." <> String.duplicate("0", 18) <> "1"

      assert {:error, {:invalid_quantity, ^too_fine}} =
               Rest.place_order(@credentials, %{@market | quantity: too_fine}, opts)

      refute_received {:sent, _raw}

      exact = "0.123456789012345678"
      assert {:ok, _order} = Rest.place_order(@credentials, %{@market | quantity: exact}, opts)

      assert_receive {:sent, raw}
      assert Jason.decode!(raw)["market_order_config"] == %{"asset_quantity" => exact}
    end
  end

  # --- S: a venue number is bounded to 34 digits ---------------------------------------------

  describe "a venue number past 34 digits is unreadable, not a number" do
    defp book(bid, ask) do
      %{"results" => [%{"symbol" => "BTC-USD", "bid" => bid, "ask" => ask}]}
    end

    test "a book side of 40 digits, as text or as a JSON integer, refuses the book" do
      for ask <- [@digits_40, 10 ** 40] do
        assert {:error, {:invalid_decimal, :ask, shown}} =
                 Rest.get_top_of_book("BTC-USD", @credentials,
                   plug: responding(book("1", ask)),
                   retry_attempts: 0
                 )

        assert shown == ask
      end
    end

    test "34 digits is still a price" do
      assert {:ok, %{ask: ask}} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(book("1", @digits_34)),
                 retry_attempts: 0
               )

      assert Decimal.equal?(ask, Decimal.new(@digits_34))
    end

    test "a holding, an account's cash and an order's size and fee are refused the same way" do
      holdings = %{"results" => [%{"asset_code" => "BTC", "total_quantity" => @digits_40}]}

      assert {:error, {:invalid_decimal, :balance, @digits_40}} =
               Rest.get_balances(@credentials,
                 account_number: "RH-1",
                 plug: responding(holdings),
                 retry_attempts: 0
               )

      order = %{
        "id" => "o-1",
        "state" => "open",
        "type" => "limit",
        "limit_order_config" => %{"asset_quantity" => @digits_40, "limit_price" => "1"}
      }

      assert {:error, {:invalid_decimal, :quantity, @digits_40}} =
               Rest.get_order(@credentials, "o-1",
                 account_number: "RH-1",
                 plug: responding(order),
                 retry_attempts: 0
               )

      fee = %{"id" => "o-1", "state" => "filled", "fee_charged" => @digits_40}

      assert {:error, {:invalid_decimal, :fee, @digits_40}} =
               Rest.get_order(@credentials, "o-1",
                 account_number: "RH-1",
                 plug: responding(fee),
                 retry_attempts: 0
               )
    end

    test "an increment or a size limit of 40 digits is stated as nil, not truncated" do
      row = %{
        "symbol" => "BTC-USD",
        "quote_increment" => "0.01",
        "asset_increment" => "0.00000001",
        "max_order_size" => @digits_40
      }

      assert {:ok, rules} =
               Rest.quantization("BTC-USD", @credentials,
                 plug: responding(%{"results" => [row]}),
                 retry_attempts: 0
               )

      assert rules.max_quantity == nil
      assert Decimal.equal?(rules.price_increment, Decimal.new("0.01"))
    end

    test "an estimate row carrying a 40 digit number refuses the answer" do
      body = %{"results" => [%{"symbol" => "BTC-USD", "est_fee" => @digits_40}]}

      assert {:error, {:invalid_decimal, "est_fee", @digits_40}} =
               Rest.get_estimated_price("BTC-USD", "ask", "1", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end
  end

  # --- S: a symbol is validated before it is signed into a request line ------------------------

  describe "a symbol is 1 to 32 characters of letters, digits and - _ ." do
    @refused_symbols [
      " BTC-USD",
      "BTC-USD ",
      "BTC USD",
      "BTC-USD\n",
      "BTC&symbol=ETH-USD",
      "BTC-USD#x",
      "BTC/USD",
      "BTC-USD?x=1",
      "BTC%2DUSD",
      "BTCÜ-USD",
      "",
      "   "
    ]

    test "anything else is {:invalid_symbols, list} from the check, the Fake and the facade" do
      for bad <- @refused_symbols do
        expected = {:error, {:invalid_symbols, [bad]}}

        assert Feed.canonical_symbols([bad]) == expected
        assert Fake.subscribe([bad], []) == expected
        assert Robinhood.subscribe([bad], feed: :no_such_feed_aq) == expected
        assert Robinhood.update_symbols([bad], feed: :no_such_feed_aq) == expected
        assert Robinhood.unsubscribe([bad], feed: :no_such_feed_aq) == expected
      end
    end

    test "too long is refused at 33 characters and kept at 32" do
      long = String.duplicate("A", 33)
      edge = String.duplicate("A", 32)

      assert Feed.canonical_symbols([long]) == {:error, {:invalid_symbols, [long]}}
      assert Feed.canonical_symbols([edge]) == {:ok, [edge]}
    end

    test "a real pair, a digit-led one and a lower-case one are kept, upper-cased once" do
      assert Feed.canonical_symbols(["btc-usd", "BTC-USD", "1inch-usd", "SHIB-USD"]) ==
               {:ok, ["BTC-USD", "1INCH-USD", "SHIB-USD"]}
    end

    test "a feed started with one stops, as it does for any other bad symbol list" do
      Process.flag(:trap_exit, true)

      for bad <- @refused_symbols do
        assert {:error, {:invalid_option, :symbols}} =
                 Feed.start_link(
                   name: unique_name(:feed_aq),
                   credentials: @credentials,
                   symbols: [bad],
                   start_delay_ms: 60_000
                 )
      end
    end
  end

  # --- T: a tree that could never poll refuses to start ---------------------------------------

  describe "DpExchange.Robinhood.start_link/1 judges its options and its credentials" do
    defp tree_opts(extra) do
      [
        name: unique_name(:rh_aq),
        symbols: [],
        start_delay_ms: 600_000,
        interval_ms: 600_000
      ] ++ extra
    end

    test "an option the tree does not read is {:unknown_option, key}, on the Fake too" do
      for module <- [Robinhood, Fake], key <- [:start_dely_ms, :symbls, :fetch_timeout_ms] do
        assert module.start_link([{key, 1}]) == {:error, {:unknown_option, key}}
      end
    end

    test "options that are not a keyword list are refused, bounded and without the secret" do
      for module <- [Robinhood, Fake] do
        assert {:error, {:invalid_options, shown}} =
                 module.start_link(%{credentials: @credentials, name: :x})

        refute inspect(shown) =~ @credentials.private_key
      end
    end

    test "environment: :sandbox is refused, there being no sandbox to go to" do
      for module <- [Robinhood, Fake] do
        assert module.start_link(environment: :sandbox) ==
                 {:error, {:unsupported_option, :environment}}
      end
    end

    test "every key the tree reads is accepted by the key check" do
      opts = [
        name: :n,
        feed: :f,
        ledger: :l,
        limiter: :m,
        symbols: [],
        subscriber: nil,
        interval_ms: 1,
        start_delay_ms: 1,
        bisect_budget_ms: 1,
        max_queue_len: 1,
        environment: :production,
        rate_limit_blocking: true,
        plug: nil,
        adapter: nil,
        req_adapter: nil,
        base_url: nil,
        retry_attempts: 0,
        retry_delay: 1,
        timeout: 1,
        log_requests: false,
        weight: 1,
        max_retry_after_s: 1,
        max_body_bytes: 1,
        credentials: nil
      ]

      assert Rest.validate_opts(opts, :start_link) == :ok
    end

    test "a malformed private key is refused at start with the signer's own reason" do
      canary = "SECRET-CANARY-aq"

      cases = [
        {%{api_key: "k", private_key: "not base64!!"}, {:invalid_private_key, :not_base64}},
        {%{api_key: "k", private_key: Base.encode64(:binary.copy(<<1>>, 64))},
         {:invalid_private_key, {:expected_32_bytes, 64}}},
        {%{api_key: "k", private_key: Base.encode64(:binary.copy(<<1>>, 31))},
         {:invalid_private_key, {:expected_32_bytes, 31}}},
        {%{api_key: "k", private_key: 5}, {:invalid_private_key, :not_a_string}},
        {%{api_key: "", private_key: ""}, {:missing_credentials, :robinhood}},
        {%{api_key: canary, private_key: nil}, {:missing_credentials, :robinhood}},
        {%{api_key: nil, private_key: Base.encode64(:binary.copy(<<1>>, 32))},
         {:missing_credentials, :robinhood}},
        {%{api_key: canary <> "\n", private_key: Base.encode64(:binary.copy(<<1>>, 32))},
         {:invalid_credentials, :robinhood}},
        {%{api_key: "k", private_key: Base.encode64(:binary.copy(<<1>>, 32)) <> "\n"},
         {:invalid_credentials, :robinhood}}
      ]

      for module <- [Robinhood, Fake], {credentials, reason} <- cases do
        opts = tree_opts(credentials: credentials)
        name = Keyword.fetch!(opts, :name)

        assert module.start_link(opts) == {:error, reason}, inspect(reason)

        # Refused whole: no tree was started under the name it was given.
        assert Process.whereis(name) == nil
      end
    end

    test "an error names no secret" do
      canary = "SECRET-CANARY-aq"

      assert {:error, reason} =
               Robinhood.start_link(
                 tree_opts(credentials: %{api_key: canary <> "\n", private_key: "x"})
               )

      refute inspect(reason) =~ canary
    end

    test "a valid pair, an absent one and an empty one still start" do
      for credentials <- [@credentials, nil, %{}] do
        assert {:ok, sup} = Robinhood.start_link(tree_opts(credentials: credentials))
        Supervisor.stop(sup)
      end

      assert {:ok, sup} = Robinhood.start_link(tree_opts([]))
      Supervisor.stop(sup)

      assert Fake.start_link(tree_opts(credentials: @credentials)) == :ignore
    end

    test "a forwarded name: nil is the default name in every child spec" do
      assert %{id: DpExchange.Robinhood} = Robinhood.child_spec(name: nil)
      assert %{id: RobinhoodSupervisor} = RobinhoodSupervisor.child_spec(name: nil)
      assert %{id: Feed} = Feed.child_spec(name: nil)
      assert %{id: Fake} = Fake.child_spec(name: nil)

      assert %{id: :named} = Robinhood.child_spec(name: :named)
    end

    test "Credentials.check_opt/1 leaves a shape the feed refuses itself to the feed" do
      assert Credentials.check_opt([]) == :ok
      assert Credentials.check_opt(credentials: nil) == :ok
      assert Credentials.check_opt(credentials: %{}) == :ok
      assert Credentials.check_opt(credentials: [api_key: "k", private_key: "x"]) == :ok
      assert Credentials.check_opt(credentials: @credentials) == :ok

      assert Credentials.check_opt(credentials: %{api_key: "k", private_key: "x"}) ==
               {:error, {:invalid_private_key, :not_base64}}
    end
  end

  describe "a feed refuses a request option it would fail on every cycle" do
    # `extra` replaces a default of the same key: `Config.opt/3` reads the FIRST of a repeated
    # key, so a plain `++` would leave the default winning.
    defp feed_opts(extra) do
      Keyword.merge(
        [
          name: unique_name(:feed_aq),
          credentials: @credentials,
          symbols: [],
          start_delay_ms: 600_000
        ],
        extra
      )
    end

    test "a base_url that is cleartext, schemeless or not a string stops the feed at start" do
      Process.flag(:trap_exit, true)

      for bad <- ["http://trading.example.test", "//trading.example.test", "ftp://x", 5, :x] do
        assert {:error, {:invalid_option, :base_url}} =
                 Feed.start_link(feed_opts(base_url: bad))
      end
    end

    test "https, a loopback http url and none all start" do
      for good <- ["https://trading.example.test", "http://localhost:4000", nil] do
        pid = start_supervised!({Feed, feed_opts(base_url: good)}, id: make_ref())
        assert Process.alive?(pid)
      end
    end

    test "a value Core.HttpClient would raise on stops the feed, naming the key" do
      Process.flag(:trap_exit, true)

      bad = [
        timeout: -1,
        timeout: "5",
        timeout: 1.5,
        retry_attempts: -1,
        retry_attempts: "3",
        retry_delay: -5,
        retry_delay: 1.0,
        max_body_bytes: 0,
        max_body_bytes: "big",
        weight: 0,
        weight: "1",
        max_retry_after_s: -1,
        max_retry_after_s: 4_294_968,
        log_requests: "yes",
        rate_limit_blocking: 1
      ]

      for {key, value} <- bad do
        result = Feed.start_link(feed_opts([{key, value}]))

        assert result == {:error, {:invalid_option, key}}, "#{key}: #{inspect(value)}"
      end
    end

    test "the values it accepts, nil (absent) included, start" do
      good = [
        timeout: :infinity,
        timeout: 0,
        timeout: nil,
        retry_attempts: 0,
        retry_delay: 0,
        max_body_bytes: 1,
        weight: 1,
        max_retry_after_s: 0,
        max_retry_after_s: 4_294_967,
        log_requests: true,
        rate_limit_blocking: false
      ]

      for option <- good do
        pid = start_supervised!({Feed, feed_opts([option])}, id: make_ref())
        assert Process.alive?(pid)
      end
    end
  end

  # --- U: a wanted set and its subscribers are bounded ----------------------------------------

  describe "the wanted set is bounded, and a refused call keeps nothing" do
    defp symbols(count), do: for(n <- 1..count, do: "S#{n}-USD")

    defp start_feed(extra \\ []) do
      spec = {Feed, feed_opts(Keyword.merge([subscriber: nil], extra))}

      start_supervised!(spec, id: make_ref())
    end

    test "1,000 symbols are held and the 1,001st distinct one is refused whole" do
      feed = start_feed()
      assert :ok = Feed.update_symbols(feed, symbols(1_000))

      other = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(other, :kill) end)

      assert Feed.add_symbols(feed, ["EXTRA-USD"], other) == {:error, {:too_many_symbols, 1_000}}

      # Refused whole: the set is as it was, and `other` is neither registered nor monitored.
      state = :sys.get_state(feed)
      assert length(state.symbols) == 1_000
      refute "EXTRA-USD" in state.symbols
      assert MapSet.size(state.data_subscribers) == 0
      assert state.monitors == %{}

      # A symbol already wanted adds nothing to the set, so it is not refused.
      assert :ok = Feed.add_symbols(feed, ["S1-USD"], other)
      assert MapSet.member?(:sys.get_state(feed).data_subscribers, other)
    end

    test "a list past the bound is refused by update, remove and the boot list too" do
      feed = start_feed(symbols: ["BTC-USD"])
      too_many = symbols(1_001)

      assert Feed.update_symbols(feed, too_many) == {:error, {:too_many_symbols, 1_000}}
      assert Feed.remove_symbols(feed, too_many) == {:error, {:too_many_symbols, 1_000}}
      assert Feed.wanted(feed) == ["BTC-USD"]

      Process.flag(:trap_exit, true)

      assert {:error, {:invalid_option, :symbols}} =
               Feed.start_link(feed_opts(symbols: too_many))
    end

    test "the facade and the Fake refuse alike, and the Fake keeps nothing from the refusal" do
      feed_name = unique_name(:feed_aq)
      _feed = start_supervised!({Feed, feed_opts(name: feed_name)}, id: make_ref())
      too_many = symbols(1_001)
      expected = {:error, {:too_many_symbols, 1_000}}

      assert Robinhood.subscribe(too_many, feed: feed_name) == expected
      assert Robinhood.update_symbols(too_many, feed: feed_name) == expected
      assert Robinhood.wanted(feed: feed_name) == []

      assert Fake.subscribe(too_many, []) == expected
      assert Fake.update_symbols(too_many, []) == expected
      assert Fake.wanted() == []

      assert :ok = Fake.subscribe(symbols(1_000), [])
      assert Fake.subscribe(["EXTRA-USD"], []) == expected
      assert length(Fake.wanted()) == 1_000
    end
  end

  describe "subscribers are bounded, registered names included" do
    test "the 1,001st distinct notice subscriber is refused and a known one is not" do
      feed = start_feed()
      prefix = unique_name(:aq_notice)
      names = for n <- 1..1_000, do: :"#{prefix}_#{n}"

      for name <- names, do: assert(:ok = Feed.subscribe_notices(feed, to: name))

      assert Feed.subscribe_notices(feed, to: :"#{prefix}_extra") ==
               {:error, {:too_many_subscribers, 1_000}}

      assert :ok = Feed.subscribe_notices(feed, to: hd(names))
      assert MapSet.size(:sys.get_state(feed).notice_subscribers) == 1_000
    end

    test "the 1,001st data subscriber is refused before it is monitored" do
      feed = start_feed()
      prefix = unique_name(:aq_data)

      for n <- 1..1_000, do: assert(:ok = Feed.add_symbols(feed, [], :"#{prefix}_#{n}"))

      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)

      assert Feed.add_symbols(feed, ["BTC-USD"], pid) == {:error, {:too_many_subscribers, 1_000}}

      state = :sys.get_state(feed)
      assert MapSet.size(state.data_subscribers) == 1_000
      assert state.monitors == %{}
      assert state.symbols == []
    end

    test "the Fake refuses a 1,001st distinct subscriber and keeps the registered ones" do
      prefix = unique_name(:aq_fake)

      for n <- 1..1_000, do: assert(:ok = Fake.subscribe([], to: :"#{prefix}_#{n}"))

      assert Fake.subscribe([], to: :"#{prefix}_extra") ==
               {:error, {:too_many_subscribers, 1_000}}

      assert :ok = Fake.subscribe([], to: :"#{prefix}_1")
    end
  end

  # --- U: an add/remove cycle returns the state to where it began ------------------------------

  describe "an add/remove cycle leaves no residue in the feed or its poller" do
    defp sizes(feed) do
      state = :sys.get_state(feed)
      poller = :sys.get_state(state.poller)

      %{
        symbols: length(state.symbols),
        symbol_set: MapSet.size(state.symbol_set),
        added: MapSet.size(state.added),
        refused: MapSet.size(state.refused),
        data_subscribers: MapSet.size(state.data_subscribers),
        notice_subscribers: MapSet.size(state.notice_subscribers),
        dropping: MapSet.size(state.dropping),
        monitors: map_size(state.monitors),
        poller_symbols: MapSet.size(poller.symbols),
        poller_scheduled: MapSet.size(poller.scheduled),
        poller_refused: MapSet.size(poller.refused),
        poller_last_ok: map_size(poller.last_ok),
        poller_timers: map_size(poller.timers)
      }
    end

    defp kill_and_wait(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end

    test "symbols, refusals, subscribers and monitors all return to the starting sizes" do
      feed = start_feed()
      baseline = sizes(feed)

      subscribers = for _n <- 1..3, do: spawn(fn -> Process.sleep(:infinity) end)
      wanted = symbols(60)

      for {pid, index} <- Enum.with_index(subscribers) do
        assert :ok = Feed.add_symbols(feed, Enum.slice(wanted, index * 20, 20), pid)
      end

      # A refusal the venue delivered for a wanted symbol is remembered while it is wanted.
      refused = Enum.take(wanted, 5)

      for symbol <- refused do
        send(feed, {:dp_exchange, :robinhood, {:refused, symbol, {:venue_error, 404}}})
      end

      grown = sizes(feed)
      assert grown.symbols == 60
      assert grown.symbol_set == 60
      assert grown.added == 60
      assert grown.refused == 5
      assert grown.data_subscribers == 3
      assert grown.monitors == 3
      assert grown.poller_symbols == 60

      # Unsubscribing every symbol empties what is keyed by symbol, in the feed and the poller.
      assert :ok = Feed.remove_symbols(feed, wanted)

      after_unsubscribe = sizes(feed)
      assert after_unsubscribe.symbols == baseline.symbols
      assert after_unsubscribe.symbol_set == baseline.symbol_set
      assert after_unsubscribe.added == baseline.added
      assert after_unsubscribe.refused == baseline.refused
      assert after_unsubscribe.poller_symbols == baseline.poller_symbols
      assert after_unsubscribe.poller_scheduled == baseline.poller_scheduled
      assert after_unsubscribe.poller_refused == baseline.poller_refused
      assert after_unsubscribe.poller_last_ok == baseline.poller_last_ok
      assert after_unsubscribe.poller_timers == baseline.poller_timers

      # The subscribers die: what is keyed by subscriber empties too.
      Enum.each(subscribers, &kill_and_wait/1)
      _settled = :sys.get_state(feed)

      assert sizes(feed) == baseline
    end

    test "the cycle repeated does not accumulate" do
      feed = start_feed()
      baseline = sizes(feed)

      for round <- 1..5 do
        pid = spawn(fn -> Process.sleep(:infinity) end)
        assert :ok = Feed.add_symbols(feed, symbols(10), pid)
        assert :ok = Feed.remove_symbols(feed, symbols(10))
        kill_and_wait(pid)
        _settled = :sys.get_state(feed)

        assert sizes(feed) == baseline, "round #{round} left state behind"
      end
    end
  end
end
