defmodule DpExchange.Robinhood.OrderLifecycleTest do
  @moduledoc """
  Tick AR, lens X: every word the vendor's own OpenAPI document gives an order (its state,
  side, type and time-in-force, and the filters of the order list) is read from that
  document here and walked, so a value the package does not map, or a value the vendor adds,
  fails a test instead of reaching a caller as `nil` or as the nearest atom. Also pinned: an
  order closed with fills keeps them, a venue word in the wrong case is refused, and the
  Fake never rewrites a terminal order.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.Order
  alias DpExchange.Robinhood.{Fake, Rest}
  alias DpExchange.Robinhood.Test.VendorSpec

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

  @credentials %{api_key: "rh-key", private_key: Base.encode64(:binary.copy(<<7>>, 32))}
  @account [account_number: "RH-1"]
  @market %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: "1"}

  # Every enum below is read from the vendor's committed document (`VendorSpec`).
  @order_enums %{
    "state" => VendorSpec.order_enum("state"),
    "side" => VendorSpec.order_enum("side"),
    "type" => VendorSpec.order_enum("type")
  }
  @tif_enum VendorSpec.time_in_force_enum()
  @filter_enums VendorSpec.list_filter_enums()

  # What each vendor word becomes. `Map.fetch!/2` on it raises for a word the vendor adds,
  # which is the signal: a new word must be mapped or refused on purpose, never defaulted.
  @mapped %{
    "state" => %{
      "open" => :open,
      "partially_filled" => :partially_filled,
      "filled" => :filled,
      "canceled" => :cancelled,
      "failed" => :rejected
    },
    "side" => %{"buy" => :buy, "sell" => :sell},
    "type" => %{
      "market" => :market,
      "limit" => :limit,
      "stop_loss" => :stop,
      "stop_limit" => :stop_limit
    },
    "time_in_force" => %{"gtc" => :gtc, "gfd" => :day, "gfw" => :gfw, "gfm" => :gfm}
  }

  defp read(body) do
    Rest.get_order(
      @credentials,
      "o-1",
      @account ++ [plug: fn conn -> Req.Test.json(conn, body) end, retry_attempts: 0]
    )
  end

  defp cancel(body) do
    Rest.cancel_order(
      @credentials,
      "o-1",
      plug: fn conn -> Req.Test.json(conn, body) end,
      retry_attempts: 0
    )
  end

  describe "the vendor's enums, read from its own document" do
    test "the lists walked below are not empty, so no walk is vacuous" do
      for {field, values} <- @order_enums do
        assert is_list(values) and values != [], "#{field} enum is missing from the document"
      end

      assert "partially_filled" in @order_enums["state"]
      assert is_list(@tif_enum) and @tif_enum != []
      assert @filter_enums |> Map.keys() |> Enum.sort() == ["side", "state", "type"]
    end

    for {field, key} <- [{"state", :status}, {"side", :side}, {"type", :order_type}],
        value <- Map.fetch!(@order_enums, field) do
      test "OrderResponse #{field} #{value} is mapped, not defaulted" do
        body = %{"id" => "o-1", unquote(field) => unquote(value)}
        expected = @mapped |> Map.fetch!(unquote(field)) |> Map.fetch!(unquote(value))

        assert {:ok, %Order{} = order} = read(body)
        assert Map.fetch!(order, unquote(key)) == expected
      end
    end

    for value <- @tif_enum do
      test "time_in_force #{value} is mapped, not defaulted" do
        body = %{
          "id" => "o-1",
          "type" => "stop_loss",
          "stop_loss_order_config" => %{
            "asset_quantity" => "1",
            "stop_price" => "1",
            "time_in_force" => unquote(value)
          }
        }

        expected = @mapped |> Map.fetch!("time_in_force") |> Map.fetch!(unquote(value))

        assert {:ok, %Order{} = order} = read(body)
        assert order.time_in_force == expected
      end
    end

    for {name, key} <- [{"state", :state}, {"side", :side}, {"type", :type}] do
      test "every #{name} the order list's filter documents is accepted as a filter" do
        for value <- Map.fetch!(@filter_enums, unquote(name)) do
          message = "#{unquote(name)} #{value} is documented by the vendor and refused here"

          assert Rest.validate_order_filters([{unquote(key), value}]) == :ok, message
        end
      end
    end

    test "a state the vendor's list filter does not have is refused, never sent" do
      refute "partially_filled" in @filter_enums["state"]

      assert Rest.validate_order_filters(state: :partially_filled) ==
               {:error, {:invalid_field, :state}}

      assert Rest.validate_order_filters(state: "partially_filled") ==
               {:error, {:invalid_field, :state}}
    end
  end

  describe "a venue word in the wrong case is refused, never lower-cased into a match" do
    for {field, value} <- [{"side", "BUY"}, {"state", "FILLED"}, {"type", "LIMIT"}] do
      test "#{field} #{value} on a read and on a cancel" do
        body = %{"id" => "o-1", unquote(field) => unquote(value)}
        expected = {:error, {:unknown_enum, String.to_atom(unquote(field)), unquote(value)}}

        assert read(body) == expected
        assert cancel(body) == expected
      end
    end
  end

  describe "an order closed with fills keeps what filled" do
    @fills %{
      "id" => "o-1",
      "symbol" => "BTC-USD",
      "side" => "buy",
      "type" => "limit",
      "filled_asset_quantity" => "0.1",
      "average_price" => "60000.5",
      "fee_charged" => "0.2",
      "limit_order_config" => %{"asset_quantity" => "0.5", "limit_price" => "61000"}
    }

    for state <- ["canceled", "failed"] do
      test "#{state} with a partial fill is never read as an order that traded nothing" do
        body = Map.put(@fills, "state", unquote(state))
        expected = @mapped |> Map.fetch!("state") |> Map.fetch!(unquote(state))

        for answer <- [read(body), cancel(body)] do
          assert {:ok, %Order{} = order} = answer
          assert order.status == expected
          assert Decimal.equal?(order.filled_quantity, Decimal.new("0.1"))
          assert Decimal.equal?(order.average_price, Decimal.new("60000.5"))
          assert Decimal.equal?(order.fee, Decimal.new("0.2"))
          assert Decimal.equal?(order.quantity, Decimal.new("0.5"))
        end
      end
    end

    test "the filled size is the order's own field, not a sum of its executions" do
      execution = %{
        "effective_price" => "1.00",
        "quantity" => "99",
        "timestamp" => "2026-10-01T00:00:00Z"
      }

      body = Map.merge(@fills, %{"state" => "partially_filled", "executions" => [execution]})

      assert {:ok, %Order{} = order} = read(body)
      assert order.status == :partially_filled
      assert Decimal.equal?(order.filled_quantity, Decimal.new("0.1"))
      assert Decimal.equal?(order.average_price, Decimal.new("60000.5"))
    end

    test "a cancel that lost the race to a fill reports the fill, not a cancellation" do
      body = Map.merge(@fills, %{"filled_asset_quantity" => "0.5", "state" => "filled"})

      assert {:ok, %Order{status: :filled} = order} = cancel(body)
      assert Decimal.equal?(order.filled_quantity, Decimal.new("0.5"))
    end
  end

  describe "an order sized in quote currency" do
    test "states no base quantity, and its limit price is still read" do
      # `OrderResponse` configs carry `quote_amount` as well as `asset_quantity`; `Order` has
      # no field for a quote-currency size, so the size is `nil` (the venue's `asset_quantity`
      # was not stated), never the amount of the other currency read as a quantity.
      body = %{
        "id" => "o-1",
        "state" => "open",
        "type" => "limit",
        "limit_order_config" => %{"quote_amount" => "100.0", "limit_price" => "50000"}
      }

      assert {:ok, %Order{} = order} = read(body)
      assert order.quantity == nil
      assert Decimal.equal?(order.price, Decimal.new("50000"))
      assert order.status == :open
    end
  end

  describe "an answer about a different order is refused" do
    test "get_order/3 and cancel_order/3 refuse a row naming another id" do
      body = %{"id" => "someone-elses", "state" => "open"}

      assert read(body) == {:error, :unexpected_response_shape}
      assert cancel(body) == {:error, :unexpected_response_shape}
    end

    test "a UUID the venue spells in upper case is still the order asked for" do
      id = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
      body = %{"id" => String.upcase(id), "state" => "canceled"}
      plug = fn conn -> Req.Test.json(conn, body) end

      assert {:ok, %Order{status: :cancelled}} =
               Rest.get_order(@credentials, id, @account ++ [plug: plug, retry_attempts: 0])

      assert {:ok, %Order{status: :cancelled}} =
               Rest.cancel_order(@credentials, id, plug: plug, retry_attempts: 0)
    end

    test "the Fake answers the id it was asked about" do
      assert {:ok, placed} = Fake.place_order(@credentials, @market, @account)
      assert {:ok, %Order{id: id}} = Fake.get_order(@credentials, placed.id, @account)
      assert id == placed.id
    end
  end

  describe "get_orders/2 :limit is a cap: min(N, everything that exists)" do
    @orders_base "https://trading.robinhood.com/api/v2/crypto/trading/orders/"
    @orders_url @orders_base <> "?account_number=RH-1"

    defp order_row(id), do: %{"id" => id, "state" => "open"}

    # Two pages of two orders each: the venue's page size (2) is below any limit above 2.
    defp two_pages(test_pid) do
      fn conn ->
        send(test_pid, {:page, conn.query_string})

        if conn.query_string == "account_number=RH-1" do
          Req.Test.json(conn, %{
            "results" => [order_row("a"), order_row("b")],
            "next" => @orders_url <> "&cursor=2"
          })
        else
          Req.Test.json(conn, %{"results" => [order_row("c"), order_row("d")], "next" => nil})
        end
      end
    end

    defp limited(limit, plug) do
      Rest.get_orders(@credentials, @account ++ [limit: limit, plug: plug, retry_attempts: 0])
    end

    defp ids({:ok, orders}), do: Enum.map(orders, & &1.id)

    test "a limit above the page size keeps walking until N rows are held" do
      assert ["a", "b", "c"] == ids(limited(3, two_pages(self())))
      assert_received {:page, "account_number=RH-1"}
      assert_received {:page, second}
      assert second =~ "cursor=2"
    end

    test "a limit above everything that exists answers everything" do
      assert ["a", "b", "c", "d"] == ids(limited(10, two_pages(self())))
    end

    test "a page that reaches N exactly stops the walk: no further request" do
      assert ["a", "b"] == ids(limited(2, two_pages(self())))
      assert_received {:page, "account_number=RH-1"}
      refute_received {:page, _second}
    end

    test "a limit below the page size takes the first N of it" do
      assert ["a"] == ids(limited(1, two_pages(self())))
      refute_received {:page, "account_number=RH-1&cursor=2"}
    end

    test "the page bound reached before N rows is history_truncated, never a short list" do
      counter = :atomics.new(1, signed: false)

      plug = fn conn ->
        n = :atomics.add_get(counter, 1, 1)

        Req.Test.json(conn, %{
          "results" => [order_row("o-#{n}")],
          "next" => @orders_url <> "&cursor=#{n}"
        })
      end

      assert limited(1_000, plug) == {:error, :history_truncated}
      assert :atomics.get(counter, 1) <= 50
    end

    test "a next that points back at a page already read is a loop, not a short list" do
      plug = fn conn ->
        Req.Test.json(conn, %{"results" => [order_row("a")], "next" => @orders_url})
      end

      assert {:error, {:pagination_loop, _path}} = limited(5, plug)
    end
  end

  describe "a row whose state contradicts its own fill is refused, not built" do
    # `Core.Types.Order.new/1` raises on each of these; the answer here is a shape refusal.
    @contradictions [
      {"filled with nothing filled", "filled", "0.0", "1"},
      {"partially_filled with nothing filled", "partially_filled", "0", "1"},
      {"open with the whole size filled", "open", "1.0", "1"},
      {"open with more than the size filled", "open", "2", "1"},
      {"partially_filled with the whole size filled", "partially_filled", "1", "1"},
      {"filled with only part filled", "filled", "0.5", "1"}
    ]

    for {label, state, filled, size} <- @contradictions do
      test "#{label}" do
        body = %{
          "id" => "o-1",
          "state" => unquote(state),
          "type" => "limit",
          "filled_asset_quantity" => unquote(filled),
          "limit_order_config" => %{"asset_quantity" => unquote(size), "limit_price" => "5"}
        }

        refused = {:error, :unexpected_response_shape}

        assert read(body) == refused
        assert cancel(body) == refused

        # A placement's answer is unconfirmed, naming the key it sent.
        plug = fn conn -> Req.Test.json(conn, body) end

        assert {:error, {:order_unconfirmed, _id, :unexpected_response_shape}} =
                 Rest.place_order(
                   @credentials,
                   @market,
                   @account ++ [plug: plug, retry_attempts: 0]
                 )

        # The same row inside a list refuses the whole list.
        page = fn conn -> Req.Test.json(conn, %{"results" => [body], "next" => nil}) end

        assert Rest.get_orders(@credentials, @account ++ [plug: page, retry_attempts: 0]) ==
                 refused
      end
    end

    test "states that cannot contradict a fill, and unstated amounts, are read as before" do
      rows = [
        {"canceled", "0.0", "1"},
        {"failed", "1", "1"},
        {"open", "0", "1"},
        {"partially_filled", "0.25", "1"},
        {"filled", "1", "1"},
        {"filled", "2", "1"},
        {"filled", "1", nil},
        {"open", "1", nil},
        {"filled", nil, "1"}
      ]

      for {state, filled, size} <- rows do
        config = if size, do: %{"asset_quantity" => size, "limit_price" => "5"}, else: %{}

        body = %{
          "id" => "o-1",
          "state" => state,
          "type" => "limit",
          "filled_asset_quantity" => filled,
          "limit_order_config" => config
        }

        message = "#{state} filled #{inspect(filled)} of #{inspect(size)}"
        assert {:ok, %Order{}} = read(body), message
      end
    end
  end

  describe "every order the Fake answers is one Order.new/1 accepts" do
    test "placed, read, listed and cancelled orders of every type rebuild through the constructor" do
      limit = Map.merge(@market, %{order_type: :limit, price: "5", time_in_force: :gtc})
      stop = Map.merge(@market, %{order_type: :stop, stop_price: "5", time_in_force: :day})
      stop_limit = Map.merge(limit, %{order_type: :stop_limit, stop_price: "4"})

      placed =
        for request <- [@market, limit, stop, stop_limit] do
          assert {:ok, order} = Fake.place_order(@credentials, request, @account)
          order
        end

      assert {:ok, cancelled} = Fake.cancel_order(@credentials, hd(placed).id, [])
      assert {:ok, listed} = Fake.get_orders(@credentials, @account)

      for order <- placed ++ [cancelled] ++ listed do
        assert %Order{} = Order.new(Map.from_struct(order))
      end
    end
  end

  describe "the Fake never rewrites a terminal order" do
    test "a second cancel returns the order as it stands, not a fresh cancellation" do
      assert {:ok, placed} = Fake.place_order(@credentials, @market, @account)
      assert {:ok, first} = Fake.cancel_order(@credentials, placed.id, [])
      assert first.status == :cancelled

      assert {:ok, second} = Fake.cancel_order(@credentials, placed.id, [])
      assert second.status == :cancelled
      assert DateTime.compare(second.updated_at, first.updated_at) == :eq
    end

    test "a filled order is answered as filled by a cancel, as the venue's own state" do
      assert {:ok, placed} = Fake.place_order(@credentials, @market, @account)

      # The Fake never fills what it accepts, so a filled order is put in its own per-process
      # store directly: the point is what a cancel does to one, not how it got filled.
      store = {Fake, :orders}
      orders = Process.get(store)
      filled = &%{&1 | status: :filled, filled_quantity: &1.quantity}
      Process.put(store, Map.update!(orders, placed.id, filled))

      assert {:ok, %Order{status: :filled}} = Fake.cancel_order(@credentials, placed.id, [])
      assert {:ok, %Order{status: :filled}} = Fake.get_order(@credentials, placed.id, @account)
    end
  end
end
