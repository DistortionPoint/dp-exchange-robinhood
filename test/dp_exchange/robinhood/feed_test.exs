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
end
