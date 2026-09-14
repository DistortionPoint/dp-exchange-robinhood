defmodule DpExchange.Robinhood.OrderShapeRefusalTest do
  @moduledoc """
  A response that is not an order object is refused, not answered with an empty one.

  `Rest.to_order/1`'s fallback clause used to build a `%Types.Order{}` with `id`, `symbol`,
  `side`, `order_type`, `quantity` and `status` all `nil` and hand it back as `{:ok, order}`
  from `get_order/3`, `place_order/3` and `cancel_order/3`. Nothing about that value said
  "the venue did not send an order": `Types.Order` deliberately permits `nil` in every one
  of those fields — its own moduledoc explains that this venue's cancel acknowledgement,
  which carries an id and nothing else, is the case the type was widened for — so the
  struct cannot carry the distinction. Only the decoder can, and it was throwing it away.

  `place_order/3` is where that costs the most. It moves funds. A caller that gets
  `{:ok, %Order{id: nil, status: nil}}` has been told the call succeeded and told nothing
  about whether an order exists, which is the one question it asked.

  `get_orders/2` is here for the same reason in list form: `account_rows/1` passes through
  whatever sits inside `"results"`, so one malformed element used to become one blank order
  among real ones — the hardest version of this to notice.

  The refusal value matches `DpExchange.Gemini.Private.to_order/1`'s for the identical
  condition: `{:error, :unexpected_response_shape}`. Same situation, same answer, across the
  family.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.Order
  alias DpExchange.Robinhood.Rest

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

  @credentials %{api_key: "rh-key", private_key: Base.encode64(:crypto.strong_rand_bytes(32))}
  @account [account_number: "RH-1", retry_attempts: 0]

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp opts(body), do: Keyword.put(@account, :plug, responding(body))

  describe "a body that is not an order object" do
    test "get_order/3 refuses rather than returning an all-nil order" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_order(@credentials, "o-1", opts(["not", "an", "order"]))
    end

    test "place_order/3 refuses — the call that moves funds does not report a false success" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        order_type: :market,
        quantity: Decimal.new("0.01")
      }

      assert {:error, :unexpected_response_shape} =
               Rest.place_order(@credentials, request, opts(["accepted"]))
    end

    test "cancel_order/3 refuses" do
      assert {:error, :unexpected_response_shape} =
               Rest.cancel_order(@credentials, "o-1", opts([]))
    end

    test "get_orders/2 refuses the whole list rather than seeding it with a blank order" do
      body = %{
        "results" => [
          %{"id" => "o-1", "state" => "filled"},
          "this is not an order",
          %{"id" => "o-2", "state" => "open"}
        ]
      }

      assert {:error, :unexpected_response_shape} = Rest.get_orders(@credentials, opts(body))
    end
  end

  describe "a 2xx body that will not decode" do
    # Found by the test above: `place_order/3` answered `{:ok, %Order{}}` with every field
    # `nil` for a body that was not JSON at all, because `decode/1` collapsed an unparseable
    # body to `%{}` and `%{}` is a map. Two separate substitutions in a row, each of which
    # would have been caught alone.
    #
    # The realistic source is not the venue sending bad JSON. It is a `200` that is not the
    # venue: a captive portal, a corporate interstitial, a CDN maintenance page — all of
    # which answer `200 text/html`. Every endpoint here fed that through the same collapse,
    # so `get_balances/2` reported an empty portfolio and `get_top_of_book/3` reported a
    # nil-priced book, both as success.
    defp html(status \\ 200) do
      fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(status, "<html><body>Service temporarily unavailable</body></html>")
      end
    end

    defp interrupted(call) do
      call.(Keyword.put(@account, :plug, html()))
    end

    test "get_order/3 refuses" do
      assert {:error, {:undecodable_response, :robinhood}} =
               interrupted(&Rest.get_order(@credentials, "o-1", &1))
    end

    test "place_order/3 refuses — no false success on the call that moves funds" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        order_type: :market,
        quantity: Decimal.new("0.01")
      }

      assert {:error, {:undecodable_response, :robinhood}} =
               interrupted(&Rest.place_order(@credentials, request, &1))
    end

    test "get_balances/2 refuses rather than reporting an empty portfolio" do
      assert {:error, {:undecodable_response, :robinhood}} =
               interrupted(&Rest.get_balances(@credentials, &1))
    end

    test "get_top_of_book/3 refuses rather than reporting a nil-priced book" do
      assert {:error, {:undecodable_response, :robinhood}} =
               interrupted(&Rest.get_top_of_book("BTC-USD", @credentials, &1))
    end

    test "a refusal status keeps reading the body leniently" do
      # The other half of the split. A 4xx body is read for a human-readable reason, and
      # "there wasn't one" is an honest answer — the status code already established the
      # refusal. This must NOT become `{:error, {:undecodable_response, _}}`: that would
      # turn a permanent, correctly-classified refusal into a generic error and lose the
      # status with it.
      assert {:refused, {:venue_error, 404}} =
               Rest.get_order(@credentials, "o-1", Keyword.put(@account, :plug, html(404)))
    end
  end

  describe "a real order object still decodes" do
    test "get_order/3 reads the venue's own fields" do
      body = %{
        "id" => "o-42",
        "symbol" => "BTC-USD",
        "side" => "buy",
        "type" => "market",
        "state" => "filled",
        "filled_asset_quantity" => "0.25",
        "average_price" => "50000.00"
      }

      assert {:ok, %Order{} = order} = Rest.get_order(@credentials, "o-42", opts(body))
      assert order.id == "o-42"
      assert order.side == :buy
      assert order.status == :filled
      assert Decimal.equal?(order.quantity, Decimal.new("0.25"))
      assert order.provider == :robinhood
    end

    test "get_orders/2 keeps the venue's order, oldest row first" do
      body = %{
        "results" => [
          %{"id" => "o-1", "state" => "filled"},
          %{"id" => "o-2", "state" => "open"}
        ]
      }

      assert {:ok, [first, second]} = Rest.get_orders(@credentials, opts(body))
      assert first.id == "o-1"
      assert second.id == "o-2"
    end

    test "a cancel acknowledgement carrying only an id is NOT refused" do
      # The case `Types.Order` was widened for. It is a map, so it is an order object as far
      # as the venue is concerned — every field it declines to state is honestly `nil`. This
      # is exactly the value the removed fallback was confusable with, and the reason the
      # distinction had to be drawn on the response's shape rather than on the struct's
      # contents.
      assert {:ok, %Order{} = order} =
               Rest.cancel_order(@credentials, "o-7", opts(%{"id" => "o-7"}))

      assert order.id == "o-7"
      assert order.status == nil
      assert order.quantity == nil
      assert order.provider == :robinhood
    end
  end

  describe "a retried order carries the SAME idempotency key" do
    test "every attempt sends the client_order_id generated for the first" do
      # `Core.HttpClient` retries anything that is not a 4xx, including a timeout and a
      # connection reset — exactly the failures where the venue may have received and acted
      # on the request. That is only safe because this venue documents `client_order_id` as
      # an idempotency key and this package generates one when the caller gives none, so a
      # retry asks the venue to complete the SAME order rather than place another.
      #
      # The property that makes it true is that the key is generated once, while the body is
      # built, and the retry loop re-sends that body unchanged. Nothing pinned it: generate
      # it per attempt and each becomes a distinct order, with the suite still green.
      # `dp_exchange_schwab` and `dp_exchange_gemini` have no such key for their order writes
      # and therefore do not retry them at all.
      me = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        decoded = if raw == "", do: %{}, else: Jason.decode!(raw)
        send(me, {:attempt, decoded["client_order_id"]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, Jason.encode!(%{"detail" => "unavailable"}))
      end

      request = %{
        symbol: "BTC-USD",
        side: :buy,
        order_type: :market,
        quantity: Decimal.new("0.01")
      }

      Rest.place_order(@credentials, request,
        account_number: "RH-1",
        plug: plug,
        retry_attempts: 3,
        retry_delay: 1
      )

      ids = drain_attempts([])

      assert length(ids) > 1,
             "the retry loop must actually have retried for this to mean anything"

      assert Enum.all?(ids, &is_binary/1), "every attempt must carry a client_order_id"
      assert length(Enum.uniq(ids)) == 1, "a retry must not mint a new key: got #{inspect(ids)}"
    end

    defp drain_attempts(acc) do
      receive do
        {:attempt, id} -> drain_attempts([id | acc])
      after
        300 -> Enum.reverse(acc)
      end
    end
  end
end
