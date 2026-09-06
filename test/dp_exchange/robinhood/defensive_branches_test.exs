defmodule DpExchange.Robinhood.DefensiveBranchesTest do
  @moduledoc """
  The clauses that exist so something cannot happen, plus the feed's own plumbing.

  Each targets a branch no ordinary call reaches. They all encode the same decision —
  refuse, or carry the absence forward, never substitute something plausible — and a
  branch nobody has exercised is a decision nobody has checked.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Types}
  alias DpExchange.Robinhood
  alias DpExchange.Robinhood.{Fake, Feed, Rest}

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

    # The poller fetches in its own process, which does not see a process-scoped
    # override. A real limiter is started and named instead — and Core's warning when
    # it was missing said exactly the right thing: the venue was "indistinguishable
    # from quiet".
    limiter = :"lim_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      DpExchange.Core.DefaultRateLimiter.start_link(
        name: limiter,
        limits: %{default: %{limit: 1000, per_ms: 1000, burst: 1000}}
      )

    {:ok, limiter: limiter}
  end

  @credentials %{api_key: "k", private_key: Base.encode64(:binary.copy(<<9>>, 32))}

  defp responding(body, status \\ 200) do
    fn conn -> Req.Test.json(%{conn | status: status}, body) end
  end

  describe "empty strings are absent fields, not values" do
    test "an empty timestamp is nil, not a failed read" do
      # v2's real `best_bid_ask` never sends a `timestamp` at all (see `rest_test.exs`'s
      # "venue_time is nil against a real v2 response"); this is defensive coverage for
      # `top_of_book_time/1`'s own tolerance of a present-and-empty one, should the vendor
      # ever add the field. Unlike a trade price, a book with no readable venue_time is
      # still a real, current book — this swallows a `:missing_venue_timestamp` into `nil`
      # rather than refusing the whole read.
      body = %{"results" => [%{"symbol" => "BTC-USD", "ask" => "1", "timestamp" => ""}]}

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert top.venue_time == nil
    end

    test "an empty bid is nil rather than zero" do
      # Zero is a price. A venue that did not quote a bid has not quoted a bid of nothing.
      body = %{"results" => [%{"symbol" => "BTC-USD", "ask" => "1", "bid" => ""}]}

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      # The assertion moved to TopOfBook with the field. Same rule: zero is a price, and a
      # venue that did not quote a bid has not quoted a bid of nothing.
      assert top.bid == nil
    end
  end

  describe "numbers and statuses" do
    test "JSON numbers become Decimals, whichever type they arrive as" do
      body = %{"results" => [%{"symbol" => "BTC-USD", "ask" => 1, "bid" => 0.5}]}

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(top.ask, Decimal.new(1))
      assert Decimal.equal?(top.bid, Decimal.from_float(0.5))
    end

    test "a 502 is an error naming the status" do
      assert {:error, {:exchange_error, :robinhood, message}} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(%{}, 502),
                 retry_attempts: 0
               )

      assert message =~ "502"
    end

    test "a refusal with no readable detail still carries the status" do
      plug = fn conn -> Plug.Conn.resp(conn, 404, "not json") end

      assert {:refused, {:venue_error, 404}} =
               Rest.get_top_of_book("BTC-USD", @credentials, plug: plug, retry_attempts: 0)
    end

    test "a seconds epoch as a string is read" do
      body = %{"results" => [%{"symbol" => "BTC-USD", "ask" => "1", "timestamp" => "1787936147"}]}

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert top.venue_time.year == 2026
    end

    test "a timestamp of an unexpected type is nil, not a guess" do
      body = %{
        "results" => [%{"symbol" => "BTC-USD", "ask" => "1", "timestamp" => %{"nested" => true}}]
      }

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert top.venue_time == nil
    end
  end

  describe "the feed's own plumbing" do
    test "a fetched book reaches the subscriber through the sink", %{limiter: limiter} do
      # The feed is a poll, and this is the wiring that makes a poll indistinguishable
      # from a socket to whoever subscribed.
      body = %{"results" => [%{"symbol" => "BTC-USD", "ask" => "77850.00", "bid" => "77840.00"}]}

      {:ok, feed} =
        Feed.start_link(
          name: :"sink_feed_#{System.unique_integer([:positive])}",
          symbols: ["BTC-USD"],
          credentials: @credentials,
          subscriber: self(),
          start_delay_ms: 0,
          interval_ms: 50,
          limiter: limiter,
          plug: responding(body),
          retry_attempts: 0
        )

      assert_receive {:dp_exchange, :robinhood, %Types.TopOfBook{symbol: "BTC-USD"}}, 3_000
      assert Feed.coverage(feed) == %{"BTC-USD" => :internal_poll}

      # `coverage_by_kind/1` wraps the exact same observed fact under the one kind this
      # feed's fetcher can ever produce — a `Types.TopOfBook`, never a `Types.Quote`.
      assert Feed.coverage_by_kind(feed) == %{top_of_book: %{"BTC-USD" => :internal_poll}}
    end

    test "a genuine refusal reaches the subscriber rather than being retried forever",
         %{limiter: limiter} do
      # `PollingFeed` retries an error and reports a refusal once — only the adapter can
      # tell a delisted symbol from a network blip, so only the adapter decides. The venue
      # must actually SAY so (a 404 with a body) for this to fire — see
      # `Rest.first_result/1`'s moduledoc note and DpCryptoManagement's issue #25: an empty
      # `results` page is silence, not a statement, and must NOT reach this path (covered
      # by "an empty page is retried, never reported as a refusal" below).
      {:ok, _feed} =
        Feed.start_link(
          name: :"refusal_feed_#{System.unique_integer([:positive])}",
          symbols: ["NOPE-USD"],
          credentials: @credentials,
          subscriber: self(),
          start_delay_ms: 0,
          interval_ms: 50,
          limiter: limiter,
          plug: responding(%{"detail" => "Symbol not found"}, 404),
          retry_attempts: 0
        )

      assert_receive {:dp_exchange, :robinhood,
                      {:refused, "NOPE-USD", {:venue_error, 404, "Symbol not found"}}},
                     3_000
    end

    test "an empty page is retried, never reported as a refusal — issue #25", %{
      limiter: limiter
    } do
      # This is the exact defect DpCryptoManagement's issue #25 measured in production:
      # an empty `results` array reaching this feed and being recorded as a permanent
      # `{:refused, :not_listed}` verdict instead of a transient failure the feed keeps
      # retrying. 56 of 83 held refusals were this — pairs that answered normally on the
      # very next call. `NOPE-USD` here answers every poll with an empty page, so if it
      # were still misclassified as a refusal the message below would arrive; the test
      # asserts the coverage-change notice instead, and that no refusal notice ever comes.
      {:ok, _feed} =
        Feed.start_link(
          name: :"empty_page_feed_#{System.unique_integer([:positive])}",
          symbols: ["NOPE-USD"],
          credentials: @credentials,
          subscriber: self(),
          start_delay_ms: 0,
          interval_ms: 50,
          limiter: limiter,
          plug: responding(%{"results" => []}),
          retry_attempts: 0
        )

      assert_receive {:dp_exchange, :robinhood, %DpExchange.Core.Notice{kind: :coverage_change}},
                     3_000

      refute_receive {:dp_exchange, :robinhood, {:refused, "NOPE-USD", _reason}}, 200
    end

    test "update_symbols reaches the poller" do
      {:ok, feed} =
        Feed.start_link(
          name: :"upd_feed_#{System.unique_integer([:positive])}",
          symbols: [],
          start_delay_ms: 60_000
        )

      assert :ok = Feed.update_symbols(feed, ["BTC-USD"])
    end
  end

  describe "the facade's short forms" do
    test "streaming callbacks answer without a started feed" do
      # The 1-arity heads. Each resolves the default feed name, finds nothing running, and
      # says so rather than exiting.
      assert Robinhood.subscribe(["BTC-USD"]) == {:error, :feed_not_started}
      assert Robinhood.unsubscribe(["BTC-USD"]) == :ok
      assert Robinhood.update_symbols(["BTC-USD"]) == {:error, :feed_not_started}
      assert Robinhood.coverage() == %{}

      # No feed running means no observed symbols under any kind — the invariant
      # (`coverage/1`'s keys equal the union across `coverage_by_kind/1`'s values) holds
      # here too: empty against empty.
      assert Robinhood.coverage_by_kind() == %{top_of_book: %{}}
    end

    test "coverage accepts a pid as well as a name" do
      {:ok, feed} =
        Feed.start_link(
          name: :"pid_feed_#{System.unique_integer([:positive])}",
          symbols: [],
          start_delay_ms: 60_000
        )

      assert Robinhood.coverage(feed: feed) == %{}
    end
  end

  describe "the fake's short arity" do
    test "subscribe works without options, and an unlisted symbol pushes nothing" do
      assert :ok = Fake.subscribe(["BTC-USD"])
      assert :ok = Fake.subscribe(["NOPE-USD"])

      assert Fake.coverage() == %{}
    end
  end
end
