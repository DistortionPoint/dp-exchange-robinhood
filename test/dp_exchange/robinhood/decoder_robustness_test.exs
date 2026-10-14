defmodule DpExchange.Robinhood.DecoderRobustnessTest do
  @moduledoc """
  Hostile and malformed venue payloads (tick AC): each decoder answers an error, or drops the
  unreadable part, rather than handing the caller a plausible value or raising in its process.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
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

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{
    api_key: "test-key-not-real",
    private_key: Base.encode64(:binary.copy(<<7>>, 32))
  }
  @account [account_number: "RH-1"]
  @base "https://trading.robinhood.com"

  defp responding(body), do: fn conn -> Req.Test.json(conn, body) end

  defp responding_status(status, body) do
    fn conn -> Req.Test.json(%{conn | status: status}, body) end
  end

  # Counts requests, so a test can say "nothing, or exactly one, went out".
  defp counting(test_pid, body) do
    fn conn ->
      send(test_pid, {:request, conn.request_path, conn.query_string})
      Req.Test.json(conn, body)
    end
  end

  defp opts(extra), do: [retry_attempts: 0] ++ extra

  describe "get_symbols/2 and list_instruments/2: a blank symbol is no symbol" do
    @rows %{
      "results" => [
        %{"symbol" => "", "asset_code" => "X", "quote_code" => "USD"},
        %{"symbol" => "   ", "asset_code" => "Y", "quote_code" => "USD"},
        %{"symbol" => "BTC-USD", "asset_code" => "BTC", "quote_code" => "USD"}
      ]
    }

    test "get_symbols drops them rather than publishing an empty catalogue entry" do
      assert {:ok, ["BTC-USD"]} = Rest.get_symbols(@credentials, opts(plug: responding(@rows)))
    end

    test "list_instruments drops them too" do
      assert {:ok, [%{symbol: "BTC-USD"}]} =
               Rest.list_instruments(@credentials, opts(plug: responding(@rows)))
    end
  end

  describe "list_instruments/2: base and quote are text or nil" do
    test "a number, an object and a blank string are nil, not carried as sent" do
      body = %{
        "results" => [
          %{"symbol" => "A-USD", "asset_code" => 5, "quote_code" => %{"x" => 1}},
          %{"symbol" => "B-USD", "asset_code" => "  ", "quote_code" => ["USD"]}
        ]
      }

      assert {:ok, [first, second]} =
               Rest.list_instruments(@credentials, opts(plug: responding(body)))

      assert {first.base, first.quote, second.base, second.quote} == {nil, nil, nil, nil}
    end
  end

  describe "quantization/3: a bound is positive or it is not stated" do
    defp quantize(row) do
      Rest.quantization(
        "BTC-USD",
        @credentials,
        opts(plug: responding(%{"results" => [Map.put(row, "symbol", "BTC-USD")]}))
      )
    end

    test "a zero or negative increment is unreadable, so is a non-positive maximum" do
      assert {:ok, rules} =
               quantize(%{
                 "quote_increment" => "0",
                 "asset_increment" => "0.001",
                 "max_order_size" => "-5",
                 "min_order_amount" => "-1",
                 "status" => 7
               })

      assert rules.price_increment == nil
      assert Decimal.equal?(rules.quantity_increment, Decimal.new("0.001"))
      assert rules.max_quantity == nil
      assert rules.min_quote_size == nil
      assert rules.status == nil
    end

    test "both increments non-positive is refused, as both unreadable already was" do
      assert {:error, {:missing_required_field, :increments}} =
               quantize(%{"quote_increment" => "0", "asset_increment" => "-0.1"})
    end

    test "a zero cash minimum is kept: it states that there is none" do
      assert {:ok, rules} = quantize(%{"quote_increment" => "0.01", "min_order_amount" => "0"})
      assert Decimal.equal?(rules.min_quote_size, Decimal.new(0))
    end
  end

  describe "error bodies" do
    test "an errors detail that is not text is not a reason, and is not carried" do
      huge = %{"nested" => String.duplicate("a", 100_000)}
      body = %{"errors" => [%{"detail" => huge, "attr" => nil}]}

      assert {:refused, {:venue_error, 400}} =
               Rest.get_accounts(@credentials, opts(plug: responding_status(400, body)))
    end

    test "a text detail is still carried" do
      body = %{"errors" => [%{"detail" => "Must be a valid UUID."}]}

      assert {:refused, {:venue_error, 400, "Must be a valid UUID."}} =
               Rest.get_accounts(@credentials, opts(plug: responding_status(400, body)))
    end

    test "an HTML 404 keeps its status" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(404, "<html><body>nope</body></html>")
      end

      assert {:refused, {:venue_error, 404}} = Rest.get_accounts(@credentials, opts(plug: plug))
    end
  end

  describe "get_accounts/2: every row is an account" do
    test "a row that is not an object is refused" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_accounts(@credentials, opts(plug: responding(%{"results" => [7]})))
    end

    test "an object that names no account is refused, not a phantom account" do
      body = %{"results" => [%{"account_number" => "RH-1"}, %{"status" => "active"}]}

      assert {:error, :unexpected_response_shape} =
               Rest.get_accounts(@credentials, opts(plug: responding(body)))
    end
  end

  describe "get_orders/2: a cursor is text" do
    test "anything else is refused before a request is signed" do
      for bad <- [%{"a" => 1}, {:x}, 5, "", "   ", [:a]] do
        assert {:error, {:invalid_field, :cursor}} =
                 Rest.get_orders(
                   @credentials,
                   @account ++ opts(plug: counting(self(), %{"results" => []}), cursor: bad)
                 )
      end

      refute_received {:request, _path, _query}
    end

    test "the Fake refuses the same shapes with the same answer" do
      for bad <- [%{"a" => 1}, {:x}, 5, "", "   "] do
        assert Fake.get_orders(@credentials, @account ++ [cursor: bad]) ==
                 {:error, {:invalid_field, :cursor}}
      end
    end
  end

  describe "a `next` cursor is followed only when it is a sane request line" do
    defp paged(next, test_pid) do
      fn conn ->
        send(test_pid, {:request, conn.request_path, conn.query_string})

        Req.Test.json(conn, %{
          "results" => [%{"account_number" => "RH-1"}],
          "next" => next
        })
      end
    end

    test "whitespace in the query is refused and not followed" do
      next = @base <> "/api/v2/crypto/trading/accounts/?cursor=a b"

      assert {:error, :unexpected_response_shape} =
               Rest.get_accounts(@credentials, opts(plug: paged(next, self())))

      assert_received {:request, _path, ""}
      refute_received {:request, _path, _query}
    end

    test "a control character in the query is refused" do
      next = @base <> "/api/v2/crypto/trading/accounts/?cursor=a\u0001b"

      assert {:error, :unexpected_response_shape} =
               Rest.get_accounts(@credentials, opts(plug: paged(next, self())))
    end

    test "a query past 2 KB is refused" do
      next = @base <> "/api/v2/crypto/trading/accounts/?cursor=" <> String.duplicate("a", 3_000)

      assert {:error, :unexpected_response_shape} =
               Rest.get_accounts(@credentials, opts(plug: paged(next, self())))
    end
  end

  describe "get_estimated_price/5: the body and its numbers" do
    defp estimate(body) do
      Rest.get_estimated_price("BTC-USD", "ask", "1", @credentials, opts(plug: responding(body)))
    end

    test "a body with no results list is unreadable, not an estimate" do
      for body <- [%{}, %{"detail" => "x"}, %{"results" => "x"}, %{"results" => %{}}] do
        assert {:error, :unexpected_response_shape} = estimate(body)
      end
    end

    test "a numeric field that is present and not a number is refused" do
      for bad <- ["abc", "NaN", "", true, [1], %{"a" => 1}] do
        body = %{"results" => [%{"symbol" => "BTC-USD", "ask" => bad}]}
        assert {:error, {:invalid_decimal, "ask", _raw}} = estimate(body)
      end
    end

    test "null and absent fields are left alone" do
      body = %{"results" => [%{"symbol" => "BTC-USD", "ask" => nil, "est_fee" => 1}]}
      assert {:ok, %{"results" => [row]}} = estimate(body)
      assert row["ask"] == nil
      assert Decimal.equal?(row["est_fee"], Decimal.new(1))
    end

    test "a null results page is an empty one" do
      assert {:ok, %{"results" => nil}} = estimate(%{"results" => nil})
    end
  end
end
