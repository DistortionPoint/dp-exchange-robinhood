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
  alias DpExchange.Robinhood.{Fake, Feed, Rest, SymbolFormat}

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
    test "an empty price with no ask is an unreadable quote" do
      body = %{"results" => [%{"price" => "", "timestamp" => "2026-08-28T17:00:01Z"}]}

      assert {:error, :unexpected_response_shape} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)
    end

    test "an empty timestamp fails closed" do
      body = %{"results" => [%{"ask_inclusive_of_buy_spread" => "1", "timestamp" => ""}]}

      assert {:error, :missing_venue_timestamp} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)
    end

    test "an empty bid is nil rather than zero" do
      # Zero is a price. A venue that did not quote a bid has not quoted a bid of nothing.
      body = %{
        "results" => [
          %{
            "ask_inclusive_of_buy_spread" => "1",
            "bid_inclusive_of_sell_spread" => "",
            "timestamp" => "2026-08-28T17:00:01Z"
          }
        ]
      }

      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)

      assert quote_struct.bid == nil
    end
  end

  describe "numbers and statuses" do
    test "JSON numbers become Decimals, whichever type they arrive as" do
      body = %{
        "results" => [
          %{
            "ask_inclusive_of_buy_spread" => 1,
            "bid_inclusive_of_sell_spread" => 0.5,
            "timestamp" => "2026-08-28T17:00:01Z"
          }
        ]
      }

      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(quote_struct.ask, Decimal.new(1))
      assert Decimal.equal?(quote_struct.bid, Decimal.from_float(0.5))
    end

    test "a 502 is an error naming the status" do
      assert {:error, {:exchange_error, :robinhood, message}} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(%{}, 502),
                 retry_attempts: 0
               )

      assert message =~ "502"
    end

    test "a refusal with no readable detail still carries the status" do
      plug = fn conn -> Plug.Conn.resp(conn, 404, "not json") end

      assert {:refused, {:venue_error, 404}} =
               Rest.get_price("BTC-USD", @credentials, plug: plug, retry_attempts: 0)
    end

    test "a seconds epoch as a string is read" do
      body = %{
        "results" => [%{"ask_inclusive_of_buy_spread" => "1", "timestamp" => "1787936147"}]
      }

      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)

      assert quote_struct.timestamp.year == 2026
    end

    test "a timestamp of an unexpected type is an error, not a guess" do
      body = %{
        "results" => [
          %{"ask_inclusive_of_buy_spread" => "1", "timestamp" => %{"nested" => true}}
        ]
      }

      assert {:error, {:unparseable_venue_timestamp, _value}} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)
    end
  end

  describe "the feed's own plumbing" do
    test "a fetched quote reaches the subscriber through the sink", %{limiter: limiter} do
      # The feed is a poll, and this is the wiring that makes a poll indistinguishable
      # from a socket to whoever subscribed.
      body = %{
        "results" => [
          %{
            "ask_inclusive_of_buy_spread" => "77850.00",
            "bid_inclusive_of_sell_spread" => "77840.00",
            "timestamp" => "2026-08-28T17:00:01Z"
          }
        ]
      }

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

      assert_receive {:dp_exchange, :robinhood, %Types.Quote{symbol: "BTC-USD"}}, 3_000
      assert Feed.coverage(feed) == %{"BTC-USD" => :internal_poll}
    end

    test "a refusal reaches the subscriber rather than being retried forever", %{limiter: limiter} do
      # `PollingFeed` retries an error and reports a refusal once — only the adapter can
      # tell a delisted symbol from a network blip, so only the adapter decides.
      {:ok, _feed} =
        Feed.start_link(
          name: :"refusal_feed_#{System.unique_integer([:positive])}",
          symbols: ["NOPE-USD"],
          credentials: @credentials,
          subscriber: self(),
          start_delay_ms: 0,
          interval_ms: 50,
          limiter: limiter,
          plug: responding(%{"results" => []}),
          retry_attempts: 0
        )

      assert_receive {:dp_exchange, :robinhood, {:refused, "NOPE-USD", :not_listed}}, 3_000
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

  describe "the mapping is exposed so it cannot drift" do
    test "mapping/0 and quotes/0 agree" do
      assert SymbolFormat.mapping().quotes == SymbolFormat.quotes()
      assert SymbolFormat.mapping().sep == "-"
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
