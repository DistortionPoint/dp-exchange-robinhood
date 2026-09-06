defmodule DpExchange.Robinhood.FeedTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{DefaultRateLimiter, Notice}
  alias DpExchange.Robinhood.Feed

  @moduletag :capture_log

  @credentials %{api_key: "k", private_key: Base.encode64(:binary.copy(<<3>>, 32))}

  @good_book %{
    "results" => [
      %{
        "bid_inclusive_of_sell_spread" => "0.99",
        "ask_inclusive_of_buy_spread" => "1.01",
        "timestamp" => "2026-08-28T12:00:00Z"
      }
    ]
  }

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
      plug:
        responding(%{
          "results" => [
            %{
              "bid_inclusive_of_sell_spread" => "0.99",
              "ask_inclusive_of_buy_spread" => "1.01",
              "timestamp" => "2026-08-28T12:00:00Z"
            }
          ]
        })
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
    test "a book reaches the subscriber" do
      start_feed()

      assert_receive {:dp_exchange, :robinhood,
                      %DpExchange.Core.Types.TopOfBook{symbol: "BTC-USD"}},
                     1_000
    end
  end

  # DpCryptoManagement issue #21: this venue's feed delivered nothing for a whole
  # deployment and the only trace was `PollingFeed`'s own `Logger.warning` — a sentence
  # nobody was grepping for. `dp_exchange_core` 0.1.50 gives `PollingFeed.start_link/1`
  # an `:on_notice` callback for exactly this, and `Feed.start_link/1` now forwards it to
  # `subscriber` the same way `on_refusal` already is.
  #
  # These tests prove that wiring, not `PollingFeed`'s own latching logic — that belongs
  # to `dp_exchange_core` and is covered there. What matters here is narrower and just as
  # load-bearing: a consumer that started this venue's supervision tree and is the
  # `subscriber:` named in its child spec — the only kind of subscriber this
  # single-fixed-subscriber venue has, since `subscribe_notices/1` is a documented no-op
  # rather than a registry (see `DpExchange.Robinhood.subscribe_notices/1`) — actually
  # receives the notice `PollingFeed` emits.
  describe "on_notice — coverage outage escalation (DpCryptoManagement issue #21)" do
    test "a %Notice{kind: :coverage_change, severity: :warning} reaches the subscriber when the feed crosses into delivering nothing" do
      start_feed(interval_ms: 40, retry_attempts: 0, plug: responding_error())

      assert_receive {:dp_exchange, :robinhood,
                      %Notice{kind: :coverage_change, severity: :warning} = notice},
                     500

      assert notice.provider == "robinhood"
      assert notice.message =~ "delivered nothing"
    end

    test "it fires only once across multiple consecutive failed ticks, not once per tick" do
      start_feed(interval_ms: 40, retry_attempts: 0, plug: responding_error())

      assert_receive {:dp_exchange, :robinhood,
                      %Notice{kind: :coverage_change, severity: :warning}},
                     500

      # At 40ms/tick this window spans several more failed attempts. `PollingFeed`
      # latches to `:dead` on the first crossing and does not re-fire until recovery, so
      # nothing further should arrive here.
      refute_receive {:dp_exchange, :robinhood, %Notice{kind: :coverage_change}}, 200
    end

    test "recovery emits a second notice, severity info, mentioning it has resumed delivering" do
      start_feed(interval_ms: 40, retry_attempts: 0, plug: flaky_then_ok(2))

      assert_receive {:dp_exchange, :robinhood,
                      %Notice{kind: :coverage_change, severity: :warning}},
                     500

      assert_receive {:dp_exchange, :robinhood,
                      %Notice{kind: :coverage_change, severity: :info} = recovered},
                     1_000

      assert recovered.message =~ "has resumed delivering"
      assert recovered.message =~ "consecutive failures"
    end
  end
end
