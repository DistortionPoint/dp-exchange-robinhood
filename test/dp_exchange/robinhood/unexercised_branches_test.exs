defmodule DpExchange.Robinhood.UnexercisedBranchesTest do
  @moduledoc """
  The branches a full run never reached (tick AA), each asserted for what it must do rather
  than merely executed.

  Grouped by the module they belong to: the REST layer's refusals and decode alternatives, the
  fake's filters and short arities, and the facade's short arities and its answers to a feed
  that dies mid-call. The feed's own are in `feed_test.exs`.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Robinhood
  alias DpExchange.Robinhood.{Fake, Rest}

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

  # A limiter that cannot answer at all, as opposed to one that says "wait".
  defmodule DownLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: {:error, :down}
    @impl true
    def check(_provider, _weight, _opts), do: {:error, :down}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{
    api_key: "test-key-not-real",
    private_key: Base.encode64(:binary.copy(<<7>>, 32))
  }

  @account [account_number: "RH-1"]
  @order %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: "1"}

  defp responding(body) do
    fn conn -> Req.Test.json(conn, body) end
  end

  defp responding_status(status, body) do
    fn conn -> Req.Test.json(%{conn | status: status}, body) end
  end

  defp capturing(body, test_pid) do
    fn conn ->
      send(test_pid, {:query, conn.query_string})
      Req.Test.json(conn, body)
    end
  end

  defp rest_opts(extra), do: [retry_attempts: 0] ++ extra

  describe "Rest: a book side that is present but not a readable positive number" do
    test "a negative JSON number is refused, carrying the number as sent" do
      body = %{"results" => [%{"symbol" => "BTC-USD", "bid" => -1, "ask" => "2"}]}

      assert {:error, {:invalid_decimal, :bid, -1}} =
               Rest.get_top_of_book("BTC-USD", @credentials, rest_opts(plug: responding(body)))
    end

    test "a JSON boolean is refused, quoted rather than read as a price or as no order" do
      body = %{"results" => [%{"symbol" => "BTC-USD", "bid" => "1", "ask" => true}]}

      assert {:error, {:invalid_decimal, :ask, "true"}} =
               Rest.get_top_of_book("BTC-USD", @credentials, rest_opts(plug: responding(body)))
    end
  end

  describe "Rest: a row that names no symbol" do
    test "is the answer when it is the only row, as a filtered single-symbol request returns" do
      body = %{"results" => [%{"bid" => "1", "ask" => "2"}]}

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials, rest_opts(plug: responding(body)))

      assert top.symbol == "BTC-USD"
      assert Decimal.equal?(top.bid, Decimal.new(1))
      assert Decimal.equal?(top.ask, Decimal.new(2))
    end

    test "is not the answer when there are several: which one is ours cannot be told" do
      body = %{"results" => [%{"bid" => "1", "ask" => "2"}, %{"bid" => "3", "ask" => "4"}]}

      assert {:error, :symbol_not_in_response} =
               Rest.get_top_of_book("BTC-USD", @credentials, rest_opts(plug: responding(body)))
    end
  end

  describe "Rest: a page cursor the walk will not follow" do
    test "a next that is not a string refuses the accounts read rather than ending it" do
      body = %{"next" => 5, "results" => [%{"account_number" => "RH-1"}]}

      assert {:error, :unexpected_response_shape} =
               Rest.get_accounts(@credentials, rest_opts(plug: responding(body)))
    end

    test "a next naming another endpoint's path refuses the accounts read" do
      other = "/api/v2/crypto/trading/holdings/"
      body = %{"next" => other, "results" => [%{"account_number" => "RH-1"}]}

      assert {:error, {:unexpected_next_path, ^other}} =
               Rest.get_accounts(@credentials, rest_opts(plug: responding(body)))
    end
  end

  describe "Rest: a status that is neither success nor one of the four refusals, on a read" do
    for status <- [405, 410, 418, 422] do
      test "#{status} is an error naming the status, not a refusal and not an empty success" do
        assert {:error, {:exchange_error, :robinhood, message}} =
                 Rest.get_accounts(
                   @credentials,
                   rest_opts(plug: responding_status(unquote(status), %{"detail" => "no"}))
                 )

        assert message =~ "HTTP #{unquote(status)}"
      end
    end
  end

  describe "Rest: a 2xx body that arrives as undecoded text" do
    test "valid JSON text is decoded, as the same body would have been had it been typed JSON" do
      row = %{"account_number" => "RH-1", "status" => "active"}

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, Jason.encode!(%{"results" => [row]}))
      end

      assert {:ok, [^row]} = Rest.get_accounts(@credentials, rest_opts(plug: plug))
    end
  end

  describe "Rest.get_estimated_price/5: rows that are not objects" do
    test "refuse the whole answer, rather than riding beside the rows that decode" do
      body = %{"results" => [7, %{"symbol" => "BTC-USD", "ask" => 1.5}]}

      assert {:error, :unexpected_response_shape} =
               Rest.get_estimated_price(
                 "BTC-USD",
                 :ask,
                 "1",
                 @credentials,
                 rest_opts(plug: responding(body))
               )
    end
  end

  describe "Rest.get_orders/2: the venue's words for the filters" do
    for {filter, wire} <- [
          {[side: :sell], %{"side" => "sell"}},
          {[state: :filled], %{"state" => "filled"}},
          {[state: :rejected], %{"state" => "failed"}},
          {[state: :failed], %{"state" => "failed"}},
          {[state: "failed"], %{"state" => "failed"}},
          {[state: :pending], %{"state" => "pending"}}
        ] do
      test "#{inspect(filter)} is sent as #{inspect(wire)}" do
        assert {:ok, []} =
                 Rest.get_orders(
                   @credentials,
                   @account ++
                     unquote(filter) ++
                     rest_opts(plug: capturing(%{"results" => []}, self()))
                 )

        assert_receive {:query, query}, 5_000
        expected = unquote(Macro.escape(wire))
        assert query |> URI.decode_query() |> Map.take(Map.keys(expected)) == expected
      end
    end
  end

  describe "Rest.filter_instant/1" do
    test "reads nothing, a DateTime and an ISO 8601 string, and refuses anything else" do
      now = DateTime.utc_now()

      assert Rest.filter_instant(nil) == {:ok, nil}
      assert Rest.filter_instant(now) == {:ok, now}
      assert Rest.filter_instant("2026-10-01T00:00:00Z") == {:ok, ~U[2026-10-01 00:00:00Z]}
      assert Rest.filter_instant("yesterday") == :error
      assert Rest.filter_instant(1_790_000_000) == :error
      assert Rest.filter_instant(~D[2026-10-01]) == :error
    end
  end

  describe "Rest.get_orders/2: one page, when :limit is given" do
    test "a null results is an empty page" do
      assert {:ok, []} =
               Rest.get_orders(
                 @credentials,
                 @account ++ rest_opts(limit: 1, plug: responding(%{"results" => nil}))
               )
    end

    for {label, body} <- [
          {"a results that is not a list", %{"results" => "denied"}},
          {"a page with no results", %{"next" => nil}},
          {"a body that is not a page", []}
        ] do
      test "#{label} is unreadable, not an empty history" do
        assert {:error, :unexpected_response_shape} =
                 Rest.get_orders(
                   @credentials,
                   @account ++
                     rest_opts(limit: 1, plug: responding(unquote(Macro.escape(body))))
                 )
      end
    end
  end

  describe "Rest.get_order/3: an order timestamp that does not parse" do
    test "is nil, not the epoch and not now" do
      body = %{
        "id" => "o-1",
        "state" => "open",
        "type" => "limit",
        "created_at" => "yesterday",
        "updated_at" => %{"not" => "a time"},
        "limit_order_config" => %{"asset_quantity" => "0.5", "limit_price" => "60000"}
      }

      assert {:ok, order} =
               Rest.get_order(@credentials, "o-1", @account ++ rest_opts(plug: responding(body)))

      assert order.created_at == nil
      assert order.updated_at == nil
      assert order.id == "o-1"
    end
  end

  describe "Rest.place_order/3: a limiter that cannot answer" do
    test "is a plain error on the first send: nothing left, so nothing is unconfirmed" do
      Config.put_override(:rate_limit_module, DownLimiter)
      test_pid = self()

      plug = fn conn ->
        send(test_pid, :sent)
        Req.Test.json(conn, %{"id" => "o-1"})
      end

      assert {:error, {:exchange_error, :robinhood, "Rate limiter unavailable"}} =
               Rest.place_order(
                 @credentials,
                 @order,
                 @account ++ rest_opts(plug: plug)
               )

      refute_received :sent
    end
  end

  describe "Fake: the :state filter's spellings of a rejected order" do
    test "all find nothing, because this fake never rejects what it accepts" do
      assert {:ok, _placed} = Fake.place_order(@credentials, @order, @account)

      for state <- [:rejected, :failed, "failed"] do
        assert Fake.get_orders(@credentials, @account ++ [state: state]) == {:ok, []}
      end

      assert {:ok, [_open]} = Fake.get_orders(@credentials, @account ++ [state: :open])
    end
  end

  describe "Fake: the calls that take options answer without them" do
    test "the order calls still demand the account option, and say so" do
      missing = {:error, {:missing_option, :account_number}}

      assert Fake.place_order(@credentials, @order) == missing
      assert Fake.get_order(@credentials, "o-1") == missing
      assert Fake.get_orders(@credentials) == missing
    end

    test "cancel_order needs no options: an id it never issued is not found" do
      assert Fake.cancel_order(@credentials, "never-issued") == {:refused, :not_found}
    end

    test "subscribe_notices registers the caller" do
      assert Fake.subscribe_notices() == :ok
    end

    test "the calls this venue does not serve say so" do
      unsupported = {:error, :not_supported}

      assert Fake.quote_conversion("BTC", "USD", "1") == unsupported
      assert Fake.get_deposit_address("BTC", "bitcoin") == unsupported
      assert Fake.estimate_withdrawal_fee("BTC", "bitcoin", "1") == unsupported
      assert Fake.withdraw("BTC", "bitcoin", "1", "address") == unsupported
    end
  end

  describe "Facade: the calls that take options answer without them" do
    test "get_estimated_price refuses a side it does not know, before anything is signed" do
      assert Robinhood.get_estimated_price("BTC-USD", :sideways, "1", @credentials) ==
               {:error, {:unsupported_side, :sideways}}
    end

    test "quantization without credentials is refused for them, before any request" do
      assert Robinhood.quantization("BTC-USD") == {:error, {:missing_credentials, :robinhood}}
    end

    test "wanted and subscribe_notices find no feed running" do
      assert Robinhood.wanted() == []
      assert Robinhood.subscribe_notices() == {:error, :feed_not_started}
    end
  end

  describe "Facade: a feed that dies while answering" do
    # `GenServer.call/3` exits the caller with the callee's own reason, so a feed that exits
    # `:timeout` mid-call is the exit a real call timeout produces, without waiting out its
    # fifteen-second budget.
    defp dying_feed(reason) do
      name = :"dying_feed_#{System.unique_integer([:positive])}"
      test_pid = self()

      spawn(fn ->
        Process.register(self(), name)
        send(test_pid, :registered)

        receive do
          {:"$gen_call", _from, _request} -> exit(reason)
        end
      end)

      assert_receive :registered, 5_000
      name
    end

    test "a timeout is {:error, :feed_timeout}, not an exit in the caller" do
      feed = dying_feed(:timeout)

      assert Robinhood.update_symbols(["BTC-USD"], feed: feed) == {:error, :feed_timeout}
    end

    test "a read has no room for an error, so a feed that does not answer is the empty answer" do
      assert Robinhood.coverage(feed: dying_feed(:boom)) == %{}
      assert Robinhood.coverage_by_kind(feed: dying_feed(:boom)) == %{}
      assert Robinhood.wanted(feed: dying_feed(:boom)) == []
    end
  end
end
