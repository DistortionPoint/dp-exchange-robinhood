defmodule DpExchange.Robinhood.FeedTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{DefaultRateLimiter, Notice}
  alias DpExchange.Robinhood.Feed

  @moduletag :capture_log

  @credentials %{api_key: "k", private_key: Base.encode64(:binary.copy(<<3>>, 32))}

  # v2's `V2BestBidAsk` — confirmed against the vendor's own OpenAPI document, 2026-09-06 —
  # is `symbol`, `bid`, `ask`. No spread-inclusive names, no `timestamp`. A v1-shaped
  # fixture here would decode to `bid: nil, ask: nil` silently, which is exactly the defect
  # `Rest.get_top_of_book/3` carried until this field-name fix, invisible to this suite
  # because every test below only matched on the struct's `symbol`, never its `bid`/`ask`.
  @good_book %{"results" => [%{"symbol" => "BTC-USD", "bid" => "0.99", "ask" => "1.01"}]}

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  # Every `symbol` value on a query string, in the order sent — a repeated key, which
  # `Plug.Conn`'s own parsed query params collapse to the LAST value only. This is how the
  # tests below tell a bulk request (more than one `symbol`) apart from a per-symbol
  # fallback request (exactly one), the same distinction `Rest.get_top_of_book_bulk/3` and
  # `Rest.get_top_of_book/3` themselves produce on the wire.
  defp query_symbols(query_string) do
    query_string
    |> URI.query_decoder()
    |> Enum.filter(fn {key, _value} -> key == "symbol" end)
    |> Enum.map(fn {_key, value} -> value end)
  end

  # Any status outside 200..299 and outside [400, 401, 403, 404] falls to `Rest`'s
  # `{:error, {:exchange_error, ...}}` branch rather than `{:refused, ...}` — an ordinary
  # fetch failure `PollingFeed` retries next tick, exactly what a real outage looks like.
  defp responding_error do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(500, Jason.encode!(%{"detail" => "boom"}))
    end
  end

  # Fails the first `fail_count` requests, then succeeds. Counted with `:counters` (not
  # `Agent` or process state) because the plug function runs inside `Req`'s own test
  # adapter process, not this test process — a closed-over counter reference is the
  # simplest thing both sides can see.
  defp flaky_then_ok(fail_count) do
    counter = :counters.new(1, [])

    fn conn ->
      attempt = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)

      conn = Plug.Conn.put_resp_content_type(conn, "application/json")

      if attempt < fail_count do
        Plug.Conn.resp(conn, 500, Jason.encode!(%{"detail" => "boom"}))
      else
        Plug.Conn.resp(conn, 200, Jason.encode!(@good_book))
      end
    end
  end

  # `rate_limit_blocking` now defaults to true (the fix under test), so every feed here
  # needs a reachable limiter even when a test has no opinion about rate limiting at
  # all — `acquire/3` against a limiter that was never started is
  # `{:error, :not_started}`, not a silent pass-through.
  defp permissive_limiter do
    name = :"limiter_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      DefaultRateLimiter.start_link(
        name: name,
        limits: %{default: %{limit: 1_000, per_ms: 1_000, burst: 1_000}}
      )

    name
  end

  defp start_feed(opts \\ []) do
    name = :"feed_#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      credentials: @credentials,
      symbols: ["BTC-USD"],
      start_delay_ms: 0,
      interval_ms: 60_000,
      subscriber: self(),
      limiter: permissive_limiter(),
      plug: responding(@good_book)
    ]

    {:ok, pid} = Feed.start_link(Keyword.merge(defaults, opts))

    # `Feed` traps exits (added for the crash-isolation fix), so it no longer dies
    # automatically when this test process does — before that fix, the implicit link
    # `start_link/1` creates was this suite's only cleanup, relied on silently. Stopped
    # explicitly now, and `:noproc` is swallowed rather than asserted on: `on_exit`
    # callbacks run after the test process itself has already exited, so `pid` may
    # already be gone by the time this runs regardless.
    on_exit(fn ->
      try do
        GenServer.stop(pid, :normal)
      catch
        :exit, _reason -> :ok
      end
    end)

    pid
  end

  # A limiter with a single, already-spent allowance: `record/3` commits usage the way
  # `acquire/3` does, without `acquire/3`'s own wait — so the bucket starts genuinely
  # empty, and the next request against it has to wait out one whole emission interval
  # (~300ms) regardless of which mode reaches it. That wait is the one observable
  # difference between blocking (`acquire/3`, which waits it out and then succeeds) and
  # fail-fast (`check/3`, which refuses immediately and never retries before the feed's
  # own 60-second next tick) — proving `rate_limit_blocking` actually reached
  # `Core.HttpClient` without needing to reach into a different process's `Config`
  # override, which a separately-started `PollingFeed` process would never see anyway.
  defp exhausted_limiter do
    name = :"limiter_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      DefaultRateLimiter.start_link(
        name: name,
        limits: %{default: %{limit: 1, per_ms: 300, burst: 0}}
      )

    :ok = DefaultRateLimiter.record(:robinhood, 1, limiter: name)
    name
  end

  describe "rate_limit_blocking — DpCryptoManagement issue #16" do
    test "defaults to blocking, matching this feed's own documented design: a slow cycle, not a missing price" do
      limiter = exhausted_limiter()
      start_feed(limiter: limiter)

      # check/3 would refuse immediately and never retry inside this window (the next
      # tick is 60s away) — only acquire/3 (the default) delivers here at all.
      assert_receive {:dp_exchange, :robinhood,
                      %DpExchange.Core.Types.TopOfBook{symbol: "BTC-USD"}},
                     1_000
    end

    test "a caller can still opt into fail-fast explicitly, and it costs the symbol this cycle" do
      limiter = exhausted_limiter()
      start_feed(limiter: limiter, rate_limit_blocking: false)

      refute_receive {:dp_exchange, :robinhood, %DpExchange.Core.Types.TopOfBook{}}, 1_000
    end
  end

  describe "a dead notice subscriber is dropped, not walked forever" do
    # `Core.Fanout.resolve/1` already skipped a dead subscriber at send time, so no NOTICES
    # accumulated — but nothing removed the pid, so a supervised watcher that restarts left
    # one behind on every restart, for the life of this feed. Measured in Core 0.3.3 on the
    # streaming venues, where the same set is on the data path: 0.095 us per fan-out against
    # a clean set, 22.8 us against one carrying a thousand dead pids.
    test "a notice subscriber that dies is removed" do
      feed = start_feed(symbols: [], start_delay_ms: 60_000)
      watcher = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Feed.subscribe_notices(feed, to: watcher)
      assert MapSet.member?(:sys.get_state(feed).notice_subscribers, watcher)

      ref = Process.monitor(watcher)
      Process.exit(watcher, :kill)
      assert_receive {:DOWN, ^ref, :process, ^watcher, _reason}

      # A call is answered only after the feed's own `:DOWN` has been handled.
      _settled = :sys.get_state(feed)

      state = :sys.get_state(feed)
      refute MapSet.member?(state.notice_subscribers, watcher)
      refute Map.has_key?(state.monitors, watcher)
    end

    test "the configured :subscriber is never pruned, even when its holder dies" do
      # The half that must NOT be pruned, and this venue is where the distinction bites.
      # `state.subscriber` is configuration: it arrives in `start_link/1`'s opts and no call
      # can change it. Dropping it would leave a feed that can never deliver again with
      # nothing able to repair it short of restarting the tree. It cannot leak either, being
      # one pid rather than a set that accumulates.
      consumer = spawn(fn -> Process.sleep(:infinity) end)
      feed = start_feed(subscriber: consumer, symbols: [], start_delay_ms: 60_000)

      ref = Process.monitor(consumer)
      Process.exit(consumer, :kill)
      assert_receive {:DOWN, ^ref, :process, ^consumer, _reason}
      _settled = :sys.get_state(feed)

      assert :sys.get_state(feed).subscriber == consumer
      assert Process.alive?(feed)
    end

    test "a REGISTERED NAME is never monitored" do
      # A name is not a process: it outlives the process holding it, and pruning on that
      # holder's death would silently unsubscribe a consumer its supervisor is about to
      # restart under the same name.
      feed = start_feed(symbols: [], start_delay_ms: 60_000)
      name = :"named_watcher_#{System.unique_integer([:positive])}"
      holder = spawn(fn -> Process.sleep(:infinity) end)
      Process.register(holder, name)

      :ok = Feed.subscribe_notices(feed, to: name)
      assert :sys.get_state(feed).monitors == %{}

      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, _reason}
      _settled = :sys.get_state(feed)

      assert MapSet.member?(:sys.get_state(feed).notice_subscribers, name)
    end
  end

  describe "back-pressure — a slow subscriber does not get an unbounded mailbox" do
    # `Core.Venue`'s `subscribe/2` doc promised this from the day the contract was written,
    # and no venue in this family implemented any of it: every one fanned out with a bare
    # `send/2` and had never looked at a subscriber's mailbox. Implemented in `Core.Fanout`
    # 0.2.6 and wired here.
    #
    # This venue polls rather than streams, so its rate is its own `interval_ms` and not a
    # venue firehose. The bound still belongs here: a consumer stalled for long enough still
    # grows an unbounded mailbox, and a guarantee that holds only on the venues where it is
    # most obviously needed is a contract guarantee with holes in it.

    # A subscriber that never consumes, so everything sent to it stays queued.
    defp stalled_subscriber do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    defp queued(pid) do
      {:message_queue_len, len} = Process.info(pid, :message_queue_len)
      len
    end

    test "past its bound, a subscriber stops being sent to and its mailbox stops growing" do
      slow = stalled_subscriber()
      feed = start_feed(subscriber: slow, max_queue_len: 3, symbols: [], start_delay_ms: 60_000)

      for _each <- 1..10, do: send(feed, {:dp_exchange, :robinhood, book_for("BTC-USD")})
      # A call is answered only after every send above has been handled.
      _settled = :sys.get_state(feed)

      # Three payloads got through, then the bound stopped it — not ten, and, the point,
      # not unbounded. The fourth message is the `:degraded` notice announcing the drop:
      # this venue puts its data subscriber in `notice_subscribers` at `init/1`, so the
      # same pid gets both. That it arrives at all is the property, not an accident —
      # notices are deliberately NOT subject to the bound, because the notice saying a
      # subscriber is being dropped must not be the first casualty of that same
      # subscriber being dropped.
      assert queued(slow) == 4
    end

    test "a stalled subscriber is reported once, not once per dropped message" do
      slow = stalled_subscriber()
      feed = start_feed(subscriber: slow, max_queue_len: 1, symbols: [], start_delay_ms: 60_000)
      :ok = Feed.subscribe_notices(feed, to: self())

      for _each <- 1..2, do: send(feed, {:dp_exchange, :robinhood, book_for("BTC-USD")})
      _settled = :sys.get_state(feed)

      assert_receive {:dp_exchange, :robinhood,
                      %Notice{kind: :degraded, severity: :warning, details: details}}

      assert details.bound == 1
      assert details.dropping == :newest
      assert details.subscriber == inspect(slow)

      for _each <- 1..5, do: send(feed, {:dp_exchange, :robinhood, book_for("BTC-USD")})
      _settled = :sys.get_state(feed)
      refute_receive {:dp_exchange, :robinhood, %Notice{kind: :degraded}}, 100
    end

    test "an invalid bound fails at init, loudly, rather than falling back to the default" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Feed.start_link(
                 name: :"bad_bound_#{System.unique_integer([:positive])}",
                 credentials: @credentials,
                 symbols: [],
                 max_queue_len: "3"
               )

      assert message =~ ":robinhood"
      assert message =~ ":max_queue_len"
    end

    defp book_for(symbol) do
      %DpExchange.Core.Types.TopOfBook{
        symbol: symbol,
        bid: Decimal.new("1"),
        ask: Decimal.new("2"),
        venue_time: ~U[2026-09-10 00:00:00Z],
        observed_at: ~U[2026-09-10 00:00:00Z],
        provider: :robinhood
      }
    end
  end

  describe "delivery" do
    test "a book reaches the subscriber with real bid/ask, not nils from a field-name mismatch" do
      # Matching only on `symbol` here would pass even if `Rest.get_top_of_book/3` decoded
      # v2's `bid`/`ask` against v1's field names and delivered `bid: nil, ask: nil` on
      # every real poll — the exact defect this asserts against.
      start_feed()

      assert_receive {:dp_exchange, :robinhood, %DpExchange.Core.Types.TopOfBook{} = book}, 1_000
      assert book.symbol == "BTC-USD"
      assert Decimal.equal?(book.bid, Decimal.new("0.99"))
      assert Decimal.equal?(book.ask, Decimal.new("1.01"))
    end
  end

  # `docs/design/ideas/bulk-best-bid-ask-fetch.md`: `best_bid_ask`'s `symbol` query
  # parameter is documented as repeatable, and `Core.PollingFeed` gained an `on_refusal`
  # path for its own `:fetch_all` mode — the second of the idea's two blocking conditions.
  # This venue's feed now polls in bulk, and these tests prove the design that makes the
  # FIRST condition (the vendor's document never says what a partial-bad batch does) not
  # matter: no single bad symbol can permanently deny the rest.
  describe "bulk fetch — one signed request per cycle, not one per symbol" do
    test "every symbol arrives from ONE request" do
      body = %{
        "results" => [
          %{"symbol" => "BTC-USD", "bid" => "1", "ask" => "2"},
          %{"symbol" => "ETH-USD", "bid" => "3", "ask" => "4"}
        ]
      }

      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:request, query_symbols(conn.query_string)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      start_feed(symbols: ["BTC-USD", "ETH-USD"], plug: plug)

      assert_receive {:request, symbols}, 1_000
      assert Enum.sort(symbols) == ["BTC-USD", "ETH-USD"]

      assert_receive {:dp_exchange, :robinhood,
                      %DpExchange.Core.Types.TopOfBook{symbol: "BTC-USD"}},
                     1_000

      assert_receive {:dp_exchange, :robinhood,
                      %DpExchange.Core.Types.TopOfBook{symbol: "ETH-USD"}},
                     1_000

      # `interval_ms` defaults to 60s in `start_feed/1` — a second request inside this
      # window would mean this venue fell back to per-symbol calls with nothing wrong.
      refute_receive {:request, _second_request}, 200
    end

    test "a symbol absent from every bulk response is uncovered and retried, never refused" do
      # The vendor's document does not say a delisted/unlisted symbol is DROPPED from
      # `results` rather than causing a whole-batch refusal — this venue's feed must not
      # assume it is, and must not manufacture a refusal from the assumption either. A row
      # simply missing is silence, and `PollingFeed` already treats silence as
      # uncovered-and-retried on its own (see `publish_and_record/2`); this proves this
      # venue's own wiring does not undo that.
      body = %{"results" => [%{"symbol" => "BTC-USD", "bid" => "1", "ask" => "2"}]}

      feed =
        start_feed(
          symbols: ["BTC-USD", "ETH-USD"],
          interval_ms: 50,
          retry_attempts: 0,
          plug: responding(body)
        )

      assert_receive {:dp_exchange, :robinhood,
                      %DpExchange.Core.Types.TopOfBook{symbol: "BTC-USD"}},
                     1_000

      # Several more ticks pass at 50ms — long enough to prove ETH-USD's absence never
      # becomes a refusal, not just that it wasn't one on the very first attempt.
      refute_receive {:dp_exchange, :robinhood, {:refused, "ETH-USD", _reason}}, 300

      assert Feed.coverage(feed) == %{"BTC-USD" => :internal_poll}
    end

    test "a bulk refusal falls back per symbol: the bad one is refused once, the good ones publish the same cycle" do
      # The shape this venue's rate-limit history (issues #16, #25) makes plausible: one
      # bad symbol mixed into a live batch. The vendor's document never says whether the
      # venue drops that row and 200s the rest or 400s the whole request — this plug
      # simulates the WORSE of the two (whole-batch 400) precisely because that is the
      # case a naive `:fetch_all` would have no safe answer for.
      bad_symbol = "LTC-USD"
      test_pid = self()

      plug = fn conn ->
        symbols = query_symbols(conn.query_string)
        send(test_pid, {:request, symbols})

        conn = Plug.Conn.put_resp_content_type(conn, "application/json")

        case symbols do
          [_one, _two | _rest] ->
            Plug.Conn.resp(
              conn,
              400,
              Jason.encode!(%{"detail" => "Invalid symbol: #{bad_symbol}"})
            )

          [^bad_symbol] ->
            Plug.Conn.resp(conn, 404, Jason.encode!(%{"detail" => "Symbol not found"}))

          [symbol] ->
            body = %{"results" => [%{"symbol" => symbol, "bid" => "1", "ask" => "2"}]}
            Plug.Conn.resp(conn, 200, Jason.encode!(body))
        end
      end

      start_feed(
        symbols: ["BTC-USD", "ETH-USD", bad_symbol],
        interval_ms: 500,
        retry_attempts: 0,
        plug: plug
      )

      assert_receive {:dp_exchange, :robinhood, {:refused, ^bad_symbol, _reason}}, 1_000

      assert_receive {:dp_exchange, :robinhood,
                      %DpExchange.Core.Types.TopOfBook{symbol: "BTC-USD"}},
                     1_000

      assert_receive {:dp_exchange, :robinhood,
                      %DpExchange.Core.Types.TopOfBook{symbol: "ETH-USD"}},
                     1_000
    end

    test "dropping the refused symbol restores the one-request bulk cost on the next cycle" do
      bad_symbol = "LTC-USD"
      test_pid = self()

      plug = fn conn ->
        symbols = query_symbols(conn.query_string)
        send(test_pid, {:request, symbols})

        conn = Plug.Conn.put_resp_content_type(conn, "application/json")

        case symbols do
          [_one, _two | _rest] ->
            Plug.Conn.resp(
              conn,
              400,
              Jason.encode!(%{"detail" => "Invalid symbol: #{bad_symbol}"})
            )

          [^bad_symbol] ->
            Plug.Conn.resp(conn, 404, Jason.encode!(%{"detail" => "Symbol not found"}))

          [symbol] ->
            body = %{"results" => [%{"symbol" => symbol, "bid" => "1", "ask" => "2"}]}
            Plug.Conn.resp(conn, 200, Jason.encode!(body))
        end
      end

      feed =
        start_feed(
          symbols: ["BTC-USD", "ETH-USD", bad_symbol],
          interval_ms: 300,
          retry_attempts: 0,
          plug: plug
        )

      assert_receive {:dp_exchange, :robinhood, {:refused, ^bad_symbol, _reason}}, 1_000
      :ok = Feed.update_symbols(feed, ["BTC-USD", "ETH-USD"])

      assert_bulk_request_for(["BTC-USD", "ETH-USD"])
    end

    test "a bulk request that merely errors (a 5xx) is retried plainly, never fanned out per symbol" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:request, query_symbols(conn.query_string)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"detail" => "boom"}))
      end

      start_feed(
        symbols: ["BTC-USD", "ETH-USD"],
        interval_ms: 60,
        retry_attempts: 0,
        plug: plug
      )

      assert_receive {:request, symbols}, 1_000
      assert Enum.sort(symbols) == ["BTC-USD", "ETH-USD"]

      # A second bulk-shaped request on the next tick — never a per-symbol fallback pair —
      # is what proves an ordinary outage was left to `PollingFeed`'s own retry rather than
      # multiplied into 86 requests for no gain.
      assert_receive {:request, next_symbols}, 1_000
      assert Enum.sort(next_symbols) == ["BTC-USD", "ETH-USD"]
    end

    # Drains `{:request, _}` messages already queued (e.g. from a fallback cycle sent
    # before a symbol was dropped) until one matches the wanted set, rather than asserting
    # on the very next message — the next tick after `update_symbols/2` is not
    # necessarily the next message already in this process's mailbox.
    defp assert_bulk_request_for(wanted, attempts \\ 20)

    defp assert_bulk_request_for(wanted, 0) do
      flunk("no request for #{inspect(wanted)} arrived — wanted: #{inspect(wanted)}")
    end

    defp assert_bulk_request_for(wanted, attempts) do
      receive do
        {:request, symbols} ->
          if Enum.sort(symbols) == Enum.sort(wanted) do
            :ok
          else
            assert_bulk_request_for(wanted, attempts - 1)
          end
      after
        2_000 -> flunk("no request arrived at all — wanted: #{inspect(wanted)}")
      end
    end
  end

  # DpCryptoManagement issue #21: this venue's feed delivered nothing for a whole
  # deployment and the only trace was `PollingFeed`'s own `Logger.warning` — a sentence
  # nobody was grepping for. `dp_exchange_core` 0.1.50 gives `PollingFeed.start_link/1`
  # an `:on_notice` callback for exactly this, and `Feed.start_link/1` now forwards it
  # into this process, which fans it out to every registered notice subscriber.
  #
  # These tests prove that wiring, not `PollingFeed`'s own latching logic — that belongs
  # to `dp_exchange_core` and is covered there. What matters here is narrower and just as
  # load-bearing: a consumer that started this venue's supervision tree and is the
  # `subscriber:` named in its child spec receives the notice `PollingFeed` emits. The
  # describe block below this one proves the OTHER half — a pid registered through
  # `Feed.subscribe_notices/2` (and, at the facade, `DpExchange.Robinhood.subscribe_notices/1`)
  # rather than through `start_link/1`'s `:subscriber` receives it too.
  describe "on_notice — coverage outage escalation (DpCryptoManagement issue #21)" do
    test "a %Notice{kind: :coverage_change, severity: :warning} reaches the subscriber when the feed crosses into delivering nothing" do
      start_feed(interval_ms: 40, retry_attempts: 0, plug: responding_error())

      assert_receive {:dp_exchange, :robinhood,
                      %Notice{kind: :coverage_change, severity: :warning} = notice},
                     2_000

      assert notice.provider == "robinhood"
      assert notice.message =~ "delivered nothing"
    end

    test "it fires only once across multiple consecutive failed ticks, not once per tick" do
      start_feed(interval_ms: 40, retry_attempts: 0, plug: responding_error())

      assert_receive {:dp_exchange, :robinhood,
                      %Notice{kind: :coverage_change, severity: :warning}},
                     2_000

      # At 40ms/tick this window spans several more failed attempts. `PollingFeed`
      # latches to `:dead` on the first crossing and does not re-fire until recovery, so
      # nothing further should arrive here.
      refute_receive {:dp_exchange, :robinhood, %Notice{kind: :coverage_change}}, 200
    end

    test "recovery emits a second notice, severity info, mentioning it has resumed delivering" do
      start_feed(interval_ms: 40, retry_attempts: 0, plug: flaky_then_ok(2))

      assert_receive {:dp_exchange, :robinhood,
                      %Notice{kind: :coverage_change, severity: :warning}},
                     2_000

      assert_receive {:dp_exchange, :robinhood,
                      %Notice{kind: :coverage_change, severity: :info} = recovered},
                     1_000

      assert recovered.message =~ "has resumed delivering"
      assert recovered.message =~ "consecutive failures"
    end
  end

  # This is the regression proper: before this change, `Feed` had no registry at all —
  # `subscribe_notices/1` on the facade above it was a documented `:ok` no-op, and the
  # ONLY pid that could ever receive a `Core.Notice` was whatever `:subscriber` was named
  # at `start_link/1`. A second, independent process — the shape a monitoring process
  # kept apart from the data consumer actually takes — registering through
  # `Feed.subscribe_notices/2` got nothing, silently, forever.
  describe "notice registry — a pid other than the fixed :subscriber can register" do
    test "a subscriber added through subscribe_notices/2 receives a notice, and the fixed subscriber still does too" do
      feed = start_feed(interval_ms: 40, retry_attempts: 0, plug: responding_error())

      monitor = self()
      task = Task.async(fn -> receive(do: (message -> {monitor, message})) end)

      :ok = Feed.subscribe_notices(feed, to: task.pid)

      assert_receive {:dp_exchange, :robinhood,
                      %Notice{kind: :coverage_change, severity: :warning}},
                     2_000

      assert {^monitor,
              {:dp_exchange, :robinhood, %Notice{kind: :coverage_change, severity: :warning}}} =
               Task.await(task, 2_000)
    end

    test "subscribe_notices/2 defaults :to to the caller" do
      feed = start_feed(interval_ms: 40, retry_attempts: 0, plug: responding_error())

      parent = self()

      {:ok, registrant} =
        Task.start(fn ->
          :ok = Feed.subscribe_notices(feed)
          send(parent, :registered)

          receive do
            {:dp_exchange, :robinhood, %Notice{}} = message -> send(parent, {:relayed, message})
          end
        end)

      assert_receive :registered
      assert Process.alive?(registrant)

      assert_receive {:relayed,
                      {:dp_exchange, :robinhood,
                       %Notice{kind: :coverage_change, severity: :warning}}},
                     2_000
    end

    test "a registered name that is not alive is skipped rather than crashing the feed" do
      feed = start_feed(interval_ms: 40, retry_attempts: 0, plug: responding_error())

      :ok = Feed.subscribe_notices(feed, to: :no_such_registered_process)

      # The fixed subscriber (this test process) still gets the notice — a bad registrant
      # costs nothing but its own delivery.
      assert_receive {:dp_exchange, :robinhood,
                      %Notice{kind: :coverage_change, severity: :warning}},
                     2_000

      assert Process.alive?(feed)
    end
  end

  describe "a crashed poller is isolated, not fatal" do
    # `PollingFeed.start_link/1` runs inside `Feed`'s own `init/1`, which links the
    # poller to `Feed` the way `start_link` always does — the real relationship this
    # test recreates by linking `crash_pid` into a RUNNING `Feed` via `:sys.replace_
    # state/2`, which runs the given function INSIDE the target process, so `Process.
    # link/1` inside it creates a link owned by `feed`, not by this test.
    defp link_poller_into_feed(feed, poller) do
      :sys.replace_state(feed, fn state ->
        Process.link(poller)
        state
      end)
    end

    test "the feed survives its linked poller being killed" do
      feed = start_feed()
      poller = :sys.get_state(feed).poller

      crash_pid = spawn(fn -> Process.sleep(:infinity) end)
      link_poller_into_feed(feed, crash_pid)

      # `:kill`, not `:normal` — a non-trapping process ignores a peer's normal exit,
      # which would prove nothing about the trap_exit flag this test exists to check.
      # `crash_pid`, not the real `poller`, is what gets killed: killing the real one
      # would also be a fine proof, but this isolates the claim under test (does `Feed`
      # survive ANY linked EXIT) from `PollingFeed`'s own shutdown behaviour.
      ref = Process.monitor(feed)
      Process.exit(crash_pid, :kill)
      refute_receive {:DOWN, ^ref, :process, ^feed, _reason}, 500
      assert Process.alive?(feed)
      # The real poller, never touched, is still the one `Feed` is using.
      assert :sys.get_state(feed).poller == poller
    end

    test "a :link_down notice fires, the poller restarts, and coverage recovers" do
      # The plug serves or fails according to a flag this test flips. That is not
      # ceremony — it is what makes the `coverage/1 == %{}` assertion below deterministic.
      #
      # This test used to kill the poller and then assert coverage was empty. The feed
      # restarts its poller immediately and that poller polls immediately, so the
      # assertion raced the very thing it had just restarted: win, and coverage is `%{}`;
      # lose by a scheduler slice, and the replacement has already delivered and coverage
      # reads `%{"BTC-USD" => :internal_poll}`. It passed because the race was usually
      # won — the worst kind of passing test, proving its claim only on the runs where it
      # happens to look before the answer changes.
      #
      # Blocking the fetch instead was tried and is WRONG here: `coverage/1` is served by
      # the poller, so a poller held inside the plug cannot answer, and the query times
      # out. Failing the fetch is the non-blocking equivalent — with the replacement's
      # fetches erroring, coverage is empty whether or not it has polled yet, so the
      # assertion is true by construction rather than by timing.
      gate = :atomics.new(1, signed: false)
      :atomics.put(gate, 1, 1)

      gated_plug = fn conn ->
        case :atomics.get(gate, 1) do
          1 -> responding(@good_book).(conn)
          0 -> Plug.Conn.resp(conn, 500, ~s({"error":"gated"}))
        end
      end

      feed = start_feed(plug: gated_plug)
      old_poller = :sys.get_state(feed).poller

      assert_receive {:dp_exchange, :robinhood,
                      %DpExchange.Core.Types.TopOfBook{symbol: "BTC-USD"}},
                     3_000

      assert Feed.coverage(feed) == %{"BTC-USD" => :internal_poll}

      :ok = Feed.subscribe_notices(feed, to: self())
      link_poller_into_feed(feed, old_poller)

      # Close the gate BEFORE the crash, so the replacement poller cannot deliver
      # anything no matter how promptly it starts polling.
      :atomics.put(gate, 1, 0)

      Process.exit(old_poller, :kill)

      assert_receive {:dp_exchange, :robinhood, %Notice{kind: :link_down}}, 500
      assert Process.alive?(feed)

      new_poller = :sys.get_state(feed).poller
      assert is_pid(new_poller)
      refute new_poller == old_poller
      assert Process.alive?(new_poller)

      # Coverage being empty here is the claim this test exists for — `coverage/1`
      # reports the truth right after a crash rather than the stale `:internal_poll` a
      # leftover cache would keep reporting. With the gate closed the replacement cannot
      # have delivered, so the other answer is impossible rather than merely unlikely.
      assert Feed.coverage(feed) == %{}

      # And it recovers on its own — restarted with `state.symbols`, not an empty set,
      # so this needs no `subscribe/2`-equivalent call from this test.
      :atomics.put(gate, 1, 1)

      assert_receive {:dp_exchange, :robinhood,
                      %DpExchange.Core.Types.TopOfBook{symbol: "BTC-USD"}},
                     3_000

      assert Feed.coverage(feed) == %{"BTC-USD" => :internal_poll}
    end

    test "a symbol added after boot survives the crash, because Feed tracks it too" do
      feed = start_feed(symbols: [])
      :ok = Feed.update_symbols(feed, ["BTC-USD"])

      assert_receive {:dp_exchange, :robinhood,
                      %DpExchange.Core.Types.TopOfBook{symbol: "BTC-USD"}},
                     3_000

      poller = :sys.get_state(feed).poller
      link_poller_into_feed(feed, poller)
      Process.exit(poller, :kill)

      # Recovers with "BTC-USD" — never in this feed's ORIGINAL start opts, only added
      # afterward via `update_symbols/2` — proving the restart rebuilds from `state.
      # symbols`, not from the static opts `start_link/1` was given.
      assert_receive {:dp_exchange, :robinhood,
                      %DpExchange.Core.Types.TopOfBook{symbol: "BTC-USD"}},
                     3_000
    end
  end

  describe "a coverage read cannot kill the feed (dp-exchange-core #28)" do
    test "an unresponsive poller yields %{} and a notice, and the Feed survives" do
      # The reported outage: `handle_call(:coverage, ...)` delegated straight into the
      # poller with `GenServer.call/2`'s default 5s timeout, the poller could not answer
      # while a fetch was in flight, and the resulting exit propagated out of `handle_call`
      # and killed `Feed`. It restarted from static opts that never carry a consumer's
      # later `subscribe/3`, so the venue went to zero coverage and stayed there while
      # every liveness probe passed.
      #
      # The poller is swapped for a dead pid rather than suspended, so the exit is an
      # immediate `:noproc` instead of a five-second timeout — same `catch :exit` path,
      # deterministic, and it does not add five seconds to the suite. `:sys.replace_state/2`
      # is the seam because `Feed` starts its own poller inside `init/1` and takes no
      # injection point for one.
      feed = start_feed()
      Feed.subscribe_notices(feed, to: self())

      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}, 500

      :sys.replace_state(feed, fn state -> %{state | poller: dead} end)

      # Before the fix this call did not return a value at all — it exited, taking `Feed`
      # with it.
      assert Feed.coverage(feed) == %{}
      assert Process.alive?(feed)

      # `%{}` alone would be indistinguishable from a venue that is simply delivering
      # nothing. The notice is what says "we could not ask", which is a different fact.
      assert_receive {:dp_exchange, :robinhood, notice}, 500
      assert notice.kind == :link_down
      assert notice.severity == :warning
      assert notice.message =~ "did not answer a coverage read"

      # Still serving: the Feed is not merely alive, it still answers.
      assert is_map(Feed.coverage(feed))
    end
  end

  describe "the link reports itself on the metrics channel too" do
    # This venue holds no socket — its link is the poller — and `Core.PollingFeed` 0.2.8
    # emits `[:dp_exchange, :link, …]` for it. Without that, a fleet dashboard reading those
    # events would show this package disconnected forever, which is the same failure as an
    # unimplemented spec wearing the shape of a dead venue. What carries the route is
    # package-internal; a consumer should not have to know which venues hold a socket.
    test "a delivered payload is a link event, with NO bytes rather than a fake zero" do
      # A poll has no frame, so there is no point at which a byte count means what it does
      # on a socket. Absent and zero are different claims and only one is true: a consumer
      # summing `:bytes` across a mixed fleet must get the streaming venues' throughput, not
      # a total depressed by every poller reporting a confident zero.
      test_pid = self()
      handler_id = "rh-link-#{System.unique_integer([:positive])}"
      # This feed hardcodes its PollingFeed label, so the handler scopes to that rather than
      # a unique one. Safe here because the assertion is positive: a stray event from another
      # concurrent robinhood test satisfies the same three properties being asserted.
      label = "robinhood"

      :telemetry.attach(
        handler_id,
        [:dp_exchange, :link, :event],
        fn event, measurements, metadata, _config ->
          # Scoped by provider: `:telemetry` handlers are global to the VM.
          if metadata.provider == label do
            send(test_pid, {:telemetry, event, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      start_feed([])

      assert_receive {:telemetry, [:dp_exchange, :link, :event], measurements, metadata}, 2_000
      assert measurements.count == 1
      refute Map.has_key?(measurements, :bytes)
      # The struct names its own kind — never a channel name, never a subscription intent.
      assert metadata.type == "TopOfBook"
    end
  end
end
