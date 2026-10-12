defmodule DpExchange.Robinhood.OrderWritesTest do
  @moduledoc """
  A write is either refused before it is sent, refused by the venue, confirmed, or
  unconfirmed -- and the unconfirmed case always carries the `client_order_id` that was sent.

  Core: `{:refused, _}` is permanent and `{:error, _}` "may be transient and is worth
  retrying". A placement that may have reached the venue and was not confirmed (a 5xx after
  retries, a 2xx that is not an order, a refusal on a retry whose first attempt may have been
  accepted) used to come back as a bare `{:error, reason}` that did not name the key it was
  sent with, so a caller that retried with a new key placed a second order. It is now
  `{:error, {:order_unconfirmed, client_order_id, reason}}`; errors decided before anything
  was sent stay plain.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Robinhood
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

  # Refuses every request. Runs in the caller's process, like the request itself.
  defmodule RefusingLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: {:error, :rate_limit_timeout}
    @impl true
    def check(_provider, _weight, _opts), do: {:rate_limited, 2_000}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  # Lets the first request through and refuses every one after it. The count lives in the
  # process dictionary: `Core.HttpClient` calls the limiter from the caller's own process.
  defmodule OnceLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts) do
      used = Process.get(:once_limiter_used, 0)
      Process.put(:once_limiter_used, used + 1)
      if used == 0, do: :ok, else: {:error, :rate_limit_timeout}
    end

    @impl true
    def check(_provider, _weight, _opts), do: {:rate_limited, 2_000}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{api_key: "rh-key", private_key: Base.encode64(:binary.copy(<<7>>, 32))}
  @market %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: "0.5"}
  @uuid "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

  defp opts(extra), do: [account_number: "RH-1", retry_delay: 1] ++ extra

  # Answers `status`/`body` and tells the test the client_order_id of every request.
  defp answering(status, body, test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:sent, conn.request_path, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, body)
    end
  end

  defp sent_ids(acc \\ []) do
    receive do
      {:sent, _path, raw} -> sent_ids([Jason.decode!(raw)["client_order_id"] | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "an unconfirmed placement carries the key that was sent" do
    test "a 5xx after the retries names the generated key, the one every attempt carried" do
      assert {:error, {:order_unconfirmed, id, _reason}} =
               Rest.place_order(
                 @credentials,
                 @market,
                 opts(plug: answering(500, "boom", self()), retry_attempts: 2)
               )

      attempts = sent_ids()
      assert length(attempts) > 1
      assert Enum.uniq(attempts) == [id]
    end

    test "a caller's own key is the one named back" do
      assert {:error, {:order_unconfirmed, @uuid, _reason}} =
               Rest.place_order(
                 @credentials,
                 Map.put(@market, :client_order_id, @uuid),
                 opts(plug: answering(503, "down", self()), retry_attempts: 1)
               )

      assert sent_ids() == [@uuid]
    end

    test "a 2xx object without an id is unconfirmed, not a missing_required_field error" do
      assert {:error, {:order_unconfirmed, id, {:missing_required_field, :id}}} =
               Rest.place_order(
                 @credentials,
                 @market,
                 opts(plug: answering(200, ~s({"state":"open"}), self()), retry_attempts: 0)
               )

      assert [^id] = sent_ids()
    end

    test "a 2xx that is not JSON is unconfirmed" do
      assert {:error, {:order_unconfirmed, id, _undecodable}} =
               Rest.place_order(
                 @credentials,
                 @market,
                 opts(plug: answering(200, "<html>portal</html>", self()), retry_attempts: 0)
               )

      assert is_binary(id)
    end

    test "a refusal on a retry is unconfirmed: the first attempt may have been accepted" do
      calls = :counters.new(1, [])
      me = self()

      plug = fn conn ->
        :counters.add(calls, 1, 1)
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, conn.request_path, raw})
        status = if :counters.get(calls, 1) == 1, do: 500, else: 400

        Plug.Conn.resp(conn, status, ~s({"detail":"duplicate client_order_id"}))
      end

      assert {:error, {:order_unconfirmed, id, {:refused_after_retry, refusal}}} =
               Rest.place_order(@credentials, @market, opts(plug: plug, retry_attempts: 2))

      assert refusal == {:venue_error, 400, "duplicate client_order_id"}
      assert [^id, ^id] = sent_ids()
    end

    test "a refusal on the first attempt is a plain refusal" do
      assert {:refused, {:venue_error, 400, "insufficient funds"}} =
               Rest.place_order(
                 @credentials,
                 @market,
                 opts(
                   plug: answering(400, ~s({"detail":"insufficient funds"}), self()),
                   retry_attempts: 3
                 )
               )

      assert length(sent_ids()) == 1
    end

    test "a 404 on placement is :not_found" do
      assert {:refused, :not_found} =
               Rest.place_order(
                 @credentials,
                 @market,
                 opts(plug: answering(404, "{}", self()), retry_attempts: 0)
               )
    end

    test "the reason in the tuple is bounded" do
      huge = String.duplicate("x", 50_000)

      assert {:error, {:order_unconfirmed, _id, reason}} =
               Rest.place_order(
                 @credentials,
                 @market,
                 opts(plug: answering(502, huge, self()), retry_attempts: 0)
               )

      assert :erlang.external_size(reason) < 4_096
    end
  end

  describe "an order the venue confirmed is never an error" do
    test "an enum this package does not know leaves that field nil" do
      body = ~s({"id":"o-1","side":"short","type":"iceberg","state":"pending_settlement"})

      assert {:ok, order} =
               Rest.place_order(
                 @credentials,
                 @market,
                 opts(plug: answering(201, body, self()), retry_attempts: 0)
               )

      assert order.id == "o-1"
      assert order.side == nil
      assert order.order_type == nil
      assert order.status == nil
    end

    test "a read of the same body still refuses the unknown enum" do
      body = ~s({"id":"o-1","side":"short"})

      assert {:error, {:unknown_enum, :side, "short"}} =
               Rest.get_order(@credentials, "o-1",
                 account_number: "RH-1",
                 plug: answering(200, body, self()),
                 retry_attempts: 0
               )
    end
  end

  describe "errors decided before anything is sent are not wrapped" do
    test "our own limiter refusing the first send is a plain error" do
      Config.put_override(:rate_limit_module, RefusingLimiter)

      assert {:error, {:exchange_error, :robinhood, "Throttled by our own rate limiter" <> _rest}} =
               Rest.place_order(
                 @credentials,
                 @market,
                 opts(plug: answering(200, ~s({"id":"o"}), self()), retry_attempts: 3)
               )

      assert sent_ids() == []
    end

    test "our own limiter refusing a RETRY is unconfirmed: the first attempt was sent" do
      Config.put_override(:rate_limit_module, OnceLimiter)

      assert {:error, {:order_unconfirmed, id, {:exchange_error, :robinhood, text}}} =
               Rest.place_order(
                 @credentials,
                 @market,
                 opts(plug: answering(500, "boom", self()), retry_attempts: 2)
               )

      assert text =~ "Throttled by our own rate limiter"
      assert [^id] = sent_ids()
    end

    test "a blocking limiter refusing the first send is plain, a retry refused is unconfirmed" do
      Config.put_override(:rate_limit_module, RefusingLimiter)

      assert {:error, {:exchange_error, :robinhood, :rate_limit_timeout}} =
               Rest.place_order(
                 @credentials,
                 @market,
                 opts(
                   plug: answering(200, ~s({"id":"o"}), self()),
                   retry_attempts: 3,
                   rate_limit_blocking: true
                 )
               )

      assert sent_ids() == []

      Config.put_override(:rate_limit_module, OnceLimiter)

      assert {:error,
              {:order_unconfirmed, id, {:exchange_error, :robinhood, :rate_limit_timeout}}} =
               Rest.place_order(
                 @credentials,
                 @market,
                 opts(
                   plug: answering(500, "boom", self()),
                   retry_attempts: 2,
                   rate_limit_blocking: true
                 )
               )

      assert [^id] = sent_ids()
    end

    test "the venue's 429 on the only attempt is a plain error, and is sent once" do
      assert {:error, {:exchange_error, :robinhood, text}} =
               Rest.place_order(
                 @credentials,
                 @market,
                 opts(plug: answering(429, "{}", self()), retry_attempts: 3)
               )

      assert is_binary(text)
      assert length(sent_ids()) == 1
    end

    test "EVERY 4xx but 429 on the only attempt is a refusal (family tick R, DV6)" do
      for status <- [405, 406, 409, 415, 422] do
        assert {:refused, {:venue_error, ^status}} =
                 Rest.place_order(
                   @credentials,
                   @market,
                   opts(plug: answering(status, "{}", self()), retry_attempts: 3)
                 )

        assert length(sent_ids()) == 1
      end
    end

    test "a 429 or a 4xx answering a RETRY is unconfirmed" do
      for status <- [405, 422] do
        calls = :counters.new(1, [])
        me = self()

        plug = fn conn ->
          :counters.add(calls, 1, 1)
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(me, {:sent, conn.request_path, raw})
          answer = if :counters.get(calls, 1) == 1, do: 500, else: status
          Plug.Conn.resp(conn, answer, "{}")
        end

        assert {:error, {:order_unconfirmed, id, reason}} =
                 Rest.place_order(@credentials, @market, opts(plug: plug, retry_attempts: 2))

        assert reason == {:refused_after_retry, {:venue_error, status}}

        assert [^id, ^id] = sent_ids()
      end
    end

    test "a cancel's 4xx other than 429 is a refusal too" do
      assert {:refused, {:venue_error, 422}} =
               Rest.cancel_order(@credentials, "o-1",
                 account_number: "RH-1",
                 plug: answering(422, "{}", self()),
                 retry_attempts: 0
               )
    end

    test "missing or malformed credentials are plain errors and nothing is sent" do
      plug = answering(200, ~s({"id":"o"}), self())

      assert {:error, {:missing_credentials, :robinhood}} =
               Rest.place_order(%{}, @market, opts(plug: plug))

      assert {:error, {:invalid_private_key, :not_base64}} =
               Rest.place_order(
                 %{api_key: "k", private_key: "!!"},
                 @market,
                 opts(plug: plug)
               )

      assert sent_ids() == []
    end

    test "validation errors and the account option are plain errors" do
      plug = answering(200, ~s({"id":"o"}), self())

      assert {:error, {:missing_field, :order_type}} =
               Rest.place_order(
                 @credentials,
                 Map.delete(@market, :order_type),
                 opts(plug: plug)
               )

      assert {:error, {:missing_option, :account_number}} =
               Rest.place_order(@credentials, @market, plug: plug)

      assert sent_ids() == []
    end
  end

  describe "a cancel is sent once" do
    test "a 5xx is not retried, whatever retry_attempts says" do
      assert {:error, _reason} =
               Rest.cancel_order(
                 @credentials,
                 "o-1",
                 plug: answering(500, "boom", self()),
                 retry_attempts: 5,
                 retry_delay: 1
               )

      assert_received {:sent, "/api/v2/crypto/trading/orders/o-1/cancel/", ""}
      refute_received {:sent, _path, _raw}
    end

    test "the default retry count does not retry it either" do
      assert {:error, _reason} =
               Rest.cancel_order(
                 @credentials,
                 "o-2",
                 plug: answering(500, "boom", self()),
                 retry_delay: 1
               )

      assert_received {:sent, _path, ""}
      refute_received {:sent, _path, _raw}
    end

    test "a 404 is :not_found, a 403 keeps the venue's own shape" do
      assert {:refused, :not_found} =
               Rest.cancel_order(@credentials, "gone",
                 plug: answering(404, ~s({"detail":"Not found."}), self()),
                 retry_attempts: 0
               )

      assert {:refused, {:venue_error, 403, "no"}} =
               Rest.cancel_order(@credentials, "mine",
                 plug: answering(403, ~s({"detail":"no"}), self()),
                 retry_attempts: 0
               )
    end
  end

  describe "the facade" do
    test "every order call and get_order_book take opts \\\\ []" do
      Code.ensure_loaded!(Robinhood)

      for {name, arity} <- [
            place_order: 2,
            cancel_order: 2,
            get_order: 2,
            get_orders: 1,
            get_order_book: 1
          ] do
        assert function_exported?(Robinhood, name, arity), "#{name}/#{arity} is missing"
      end

      assert Robinhood.get_order_book("BTC-USD") == {:error, :not_supported}
      assert {:error, {:missing_option, :account_number}} = Robinhood.get_orders(@credentials)
      assert {:error, {:invalid_order_id, nil}} = Robinhood.get_order(@credentials, nil)
      assert {:error, {:invalid_order_id, " "}} = Robinhood.cancel_order(@credentials, " ")
    end

    test "place_order/2 reaches the same validation" do
      assert {:error, {:invalid_order_request, :nope}} =
               Robinhood.place_order(@credentials, :nope)

      assert {:error, {:unsupported_order_field, :post_only}} =
               Robinhood.place_order(@credentials, Map.put(@market, :post_only, true))
    end
  end
end
