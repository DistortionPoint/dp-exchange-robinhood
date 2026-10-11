defmodule DpExchange.Robinhood.InputFidelityTest do
  @moduledoc """
  What reaches the venue is what the caller asked for, and what comes back is labelled
  with the symbol it is actually about.

  Each case here was a plausible substitute rather than an error: another pair's book under
  this pair's name, a quantity in scientific notation, an order filter quietly dropped, a
  `Core` status word the venue's enum does not have.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Robinhood.{Auth, Credentials, Rest}

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

  defp responding(body) do
    fn conn -> Req.Test.json(conn, body) end
  end

  defp capturing(body, test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.query_string, raw})
      Req.Test.json(conn, body)
    end
  end

  describe "a single-symbol read takes the row naming that symbol" do
    test "a reordered `results` is not published under the requested name" do
      body = %{
        "results" => [
          %{"symbol" => "ETH-USD", "bid" => "1", "ask" => "2"},
          %{"symbol" => "BTC-USD", "bid" => "77840.00", "ask" => "77850.00"}
        ]
      }

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert top.symbol == "BTC-USD"
      assert Decimal.equal?(top.bid, Decimal.new("77840.00"))
    end

    test "a row for another symbol only is an error, not this symbol's answer" do
      body = %{"results" => [%{"symbol" => "ETH-USD", "bid" => "1", "ask" => "2"}]}

      assert {:error, :symbol_not_in_response} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert {:error, :symbol_not_in_response} =
               Rest.quantization("BTC-USD", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end
  end

  describe "a float quantity is sent in full notation" do
    test "0.00001 goes out in full notation, never as 1.0e-5" do
      request = %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: 0.00001}

      _result =
        Rest.place_order(@credentials, request,
          account_number: "RH-1",
          plug: capturing(%{}, self()),
          retry_attempts: 0
        )

      assert_receive {:request, _query, raw}
      assert %{"market_order_config" => %{"asset_quantity" => "0.00001"}} = Jason.decode!(raw)
    end
  end

  describe "get_orders/2 forwards every documented filter" do
    test "updated_at_*, side and type reach the query, and :cancelled is the venue spelling" do
      updated = ~U[2026-10-01 00:00:00Z]

      assert {:ok, []} =
               Rest.get_orders(@credentials,
                 account_number: "RH-1",
                 updated_at_start: updated,
                 updated_at_end: "2026-10-02T00:00:00Z",
                 side: "buy",
                 type: "limit",
                 state: :cancelled,
                 plug: capturing(%{"results" => [], "next" => nil}, self()),
                 retry_attempts: 0
               )

      assert_receive {:request, query, _raw}
      params = URI.decode_query(query)

      assert params["updated_at_start"] == DateTime.to_iso8601(updated)
      assert params["updated_at_end"] == "2026-10-02T00:00:00Z"
      assert params["side"] == "buy"
      assert params["type"] == "limit"
      assert params["state"] == "canceled"
    end
  end

  describe "an unset credential is refused, never raised on" do
    test "a nil private key is an invalid key, not a FunctionClauseError" do
      assert {:error, {:invalid_private_key, :not_a_string}} =
               Auth.headers("GET", "/p", "", %{api_key: "k", private_key: nil})
    end

    test "credentials: nil wraps to an empty credential" do
      assert Credentials.wrap(nil) == %Credentials{}
    end
  end

  describe "order identity and history completeness" do
    test "the request's own client_order_id is the one sent" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        order_type: :market,
        quantity: Decimal.new("0.1"),
        client_order_id: "11111111-2222-4333-a444-555555555555"
      }

      _result =
        Rest.place_order(@credentials, request,
          account_number: "RH-1",
          plug: capturing(%{}, self()),
          retry_attempts: 0
        )

      assert_receive {:request, _query, raw}
      assert Jason.decode!(raw)["client_order_id"] == "11111111-2222-4333-a444-555555555555"
    end

    test "a forwarded limit: nil walks every page, not one" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:page, conn.query_string})

        next = "https://trading.robinhood.com/api/v2/crypto/trading/orders/?cursor=next"

        body =
          if conn.query_string =~ "cursor=next",
            do: %{"results" => [], "next" => nil},
            else: %{"results" => [], "next" => next}

        Req.Test.json(conn, body)
      end

      assert {:ok, []} =
               Rest.get_orders(@credentials,
                 account_number: "RH-1",
                 limit: nil,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_received {:page, _first}
      assert_received {:page, second}
      assert second =~ "cursor=next"
    end
  end
end
