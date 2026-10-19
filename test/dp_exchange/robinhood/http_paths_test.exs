defmodule DpExchange.Robinhood.HttpPathsTest do
  @moduledoc """
  Tick AN, lens J. Every class of response and transport failure a request can meet reaches a
  documented answer: never a crash, never `{:ok, garbage}`, never a substituted default.

  Covered here because nothing else was covering it: a transport failure (`:timeout`,
  `:closed`, `:econnrefused`) on a read, on a placement and on a cancel; a 2xx whose JSON is
  `null`, a number, a boolean, a list, a bare string or nothing at all, on every read and on a
  placement; the venue's own `ErrorResponse` shape (`errors[].detail`) on the refusals this
  package reads; a 429 on a read; and a response over `:max_body_bytes` on a placement.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Robinhood.Rest

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
  @account [account_number: "RH-1"]
  @market %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: "0.5"}
  @transport_reasons [:timeout, :closed, :econnrefused]

  # Every request that reaches the transport is reported, then fails the way a dropped
  # connection does.
  defp failing_transport(reason, test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:sent, conn.method, conn.request_path, raw})
      Req.Test.transport_error(conn, reason)
    end
  end

  # What every request reaching the transport carried, in order. The facade call has returned,
  # so every request it made is already in the mailbox.
  defp sent(acc \\ []) do
    receive do
      {:sent, method, path, raw} -> sent([{method, path, raw} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A body sent verbatim, so a JSON `null` or a bare number reaches `Core.HttpClient` as the
  # bytes it would on the wire, not as something `Req.Test.json/2` made of an Elixir term.
  defp raw_body(body, status \\ 200, content_type \\ "application/json") do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type(content_type)
      |> Plug.Conn.resp(status, body)
    end
  end

  # Every read this package makes, each as a function of the transport options.
  defp reads do
    [
      {"get_top_of_book", &Rest.get_top_of_book("BTC-USD", @credentials, &1)},
      {"get_top_of_book_bulk", &Rest.get_top_of_book_bulk(["BTC-USD"], @credentials, &1)},
      {"quantization", &Rest.quantization("BTC-USD", @credentials, &1)},
      {"get_symbols", &Rest.get_symbols(@credentials, &1)},
      {"list_instruments", &Rest.list_instruments(@credentials, &1)},
      {"get_accounts", &Rest.get_accounts(@credentials, &1)},
      {"get_balances", &Rest.get_balances(@credentials, @account ++ &1)},
      {"get_orders", &Rest.get_orders(@credentials, @account ++ &1)},
      {"get_order", &Rest.get_order(@credentials, "o-1", @account ++ &1)},
      {"cancel_order", &Rest.cancel_order(@credentials, "o-1", &1)},
      {"get_estimated_price", &Rest.get_estimated_price("BTC-USD", :ask, "1", @credentials, &1)}
    ]
  end

  describe "a transport failure on a placement that may have been sent" do
    for reason <- @transport_reasons do
      test "#{reason} is unconfirmed, under the one key every attempt carried" do
        reason = unquote(reason)

        assert {:error, {:order_unconfirmed, id, {:exchange_error, :robinhood, message}}} =
                 Rest.place_order(@credentials, @market,
                   account_number: "RH-1",
                   plug: failing_transport(reason, self()),
                   retry_attempts: 2,
                   retry_delay: 1
                 )

        assert message =~ Atom.to_string(reason)

        assert [{"POST", _path, first}, {"POST", _same_path, second}] = sent()
        assert Jason.decode!(first)["client_order_id"] == id
        assert Jason.decode!(second)["client_order_id"] == id
      end
    end

    test "a caller's own key is the one named back" do
      key = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

      assert {:error, {:order_unconfirmed, ^key, _reason}} =
               Rest.place_order(@credentials, Map.put(@market, :client_order_id, key),
                 account_number: "RH-1",
                 plug: failing_transport(:timeout, self()),
                 retry_attempts: 1
               )

      assert [{"POST", _path, _raw}] = sent()
    end
  end

  describe "a transport failure on a cancel or a read" do
    for reason <- @transport_reasons do
      test "#{reason} on a cancel is a plain error, and the cancel is sent once" do
        reason = unquote(reason)

        assert {:error, {:exchange_error, :robinhood, message}} =
                 Rest.cancel_order(@credentials, "o-1", plug: failing_transport(reason, self()))

        assert message =~ Atom.to_string(reason)
        assert [{"POST", "/api/v2/crypto/trading/orders/o-1/cancel/", ""}] = sent()
      end

      test "#{reason} on a read is a plain error, retried to the attempts asked for" do
        reason = unquote(reason)

        assert {:error, {:exchange_error, :robinhood, message}} =
                 Rest.get_accounts(@credentials,
                   plug: failing_transport(reason, self()),
                   retry_attempts: 3,
                   retry_delay: 1
                 )

        assert message =~ Atom.to_string(reason)
        assert length(sent()) == 3
      end
    end
  end

  describe "a 2xx whose JSON is not the shape the endpoint returns" do
    # `null`, a number, a boolean and a list are valid JSON and not a page, an order or a
    # book. Every read answers `{:error, :unexpected_response_shape}` for each: not a crash in
    # the caller's process, not an empty success.
    for body <- ["null", "42", "true", "[]"] do
      test "#{body} is refused by every read" do
        for {label, call} <- reads() do
          assert call.(plug: raw_body(unquote(body)), retry_attempts: 0) ==
                   {:error, :unexpected_response_shape},
                 "#{label} answered something else for #{unquote(body)}"
        end
      end

      test "#{body} on a placement is unconfirmed, never an order" do
        assert {:error, {:order_unconfirmed, id, :unexpected_response_shape}} =
                 Rest.place_order(@credentials, @market,
                   account_number: "RH-1",
                   plug: raw_body(unquote(body)),
                   retry_attempts: 0
                 )

        assert is_binary(id)
      end
    end

    # A bare JSON string and an empty body are not JSON this package can decode into anything.
    for {label, body} <- [{"a bare JSON string", ~s("text")}, {"an empty body", ""}] do
      test "#{label} is an undecodable response on every read" do
        for {name, call} <- reads() do
          assert call.(plug: raw_body(unquote(body)), retry_attempts: 0) ==
                   {:error, {:undecodable_response, :robinhood}},
                 "#{name} answered something else for #{unquote(label)}"
        end
      end

      test "#{label} on a placement is unconfirmed, as the undecodable response it is" do
        assert {:error, {:order_unconfirmed, _id, {:undecodable_response, :robinhood}}} =
                 Rest.place_order(@credentials, @market,
                   account_number: "RH-1",
                   plug: raw_body(unquote(body)),
                   retry_attempts: 0
                 )
      end
    end
  end

  describe "the venue's own ErrorResponse shape" do
    # `{"type": ..., "errors": [{"detail": ..., "attr": ...}]}` is what the OpenAPI document
    # names for every 4xx. The unlisted-symbol 400 is read from it.
    defp error_response(type, detail) do
      Jason.encode!(%{"type" => type, "errors" => [%{"detail" => detail, "attr" => nil}]})
    end

    test "an unlisted symbol's 400 is :not_listed on every single-symbol read" do
      plug = raw_body(error_response("validation_error", "Invalid symbol: ALGO-USD"), 400)
      opts = [plug: plug, retry_attempts: 0]

      assert {:refused, :not_listed} = Rest.get_top_of_book("ALGO-USD", @credentials, opts)
      assert {:refused, :not_listed} = Rest.quantization("ALGO-USD", @credentials, opts)

      assert {:refused, :not_listed} =
               Rest.get_estimated_price("ALGO-USD", :ask, "1", @credentials, opts)

      # The poll's bulk read keeps the venue's own words, for its per-symbol refusal channel.
      assert {:refused, {:venue_error, 400, "Invalid symbol: ALGO-USD"}} =
               Rest.get_top_of_book_bulk(["ALGO-USD"], @credentials, opts)
    end

    test "a 401, 403 and 404 carry the detail the venue gave" do
      for status <- [401, 403, 404] do
        detail = "reason #{status}"
        plug = raw_body(error_response("client_error", detail), status)

        assert {:refused, {:venue_error, ^status, ^detail}} =
                 Rest.get_accounts(@credentials, plug: plug, retry_attempts: 0)
      end
    end

    test "a 404 on an order is :not_found, whatever its body says" do
      for body <- [error_response("client_error", "Not found."), "", "<html>nope</html>"] do
        assert {:refused, :not_found} =
                 Rest.get_order(@credentials, "gone",
                   account_number: "RH-1",
                   plug: raw_body(body, 404),
                   retry_attempts: 0
                 )
      end
    end

    test "an error body with no errors list still carries the status" do
      for body <- ["{}", "[]", "null", ~s({"errors": []}), ~s({"errors": ["x"]})] do
        assert {:refused, {:venue_error, 400}} =
                 Rest.get_accounts(@credentials, plug: raw_body(body, 400), retry_attempts: 0)
      end
    end
  end

  describe "a 429 and a 5xx on a read" do
    defp throttled(test_pid, headers) do
      fn conn ->
        send(test_pid, {:sent, conn.method, conn.request_path, ""})

        conn
        |> put_headers(headers)
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, error_response("client_error", "Request was throttled."))
      end
    end

    defp put_headers(conn, headers) do
      Enum.reduce(headers, conn, fn {name, value}, acc ->
        Plug.Conn.put_resp_header(acc, name, value)
      end)
    end

    test "a 429 is the venue's throttling, never a refusal, and is not retried" do
      for headers <- [[], [{"retry-after", "1"}], [{"retry-after", "soon"}]] do
        assert {:error, {:exchange_error, :robinhood, "Rate limited by the venue" <> _rest}} =
                 Rest.get_accounts(@credentials,
                   plug: throttled(self(), headers),
                   retry_attempts: 3,
                   retry_delay: 1
                 )

        assert [{"GET", "/api/v2/crypto/trading/accounts/", ""}] = sent()
      end
    end

    test "a 503 is retried to the attempts asked for, then a plain error naming the status" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:sent, conn.method, conn.request_path, ""})
        Plug.Conn.resp(conn, 503, "down")
      end

      assert {:error, {:exchange_error, :robinhood, message}} =
               Rest.get_accounts(@credentials, plug: plug, retry_attempts: 3, retry_delay: 1)

      assert message =~ "503"
      assert length(sent()) == 3
    end
  end

  describe "a response over :max_body_bytes on a placement" do
    test "is unconfirmed, and is not sent again" do
      test_pid = self()
      body = Jason.encode!(%{"id" => "o-1", "padding" => String.duplicate("x", 4_096)})

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:sent, conn.method, conn.request_path, raw})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end

      assert {:error, {:order_unconfirmed, id, reason}} =
               Rest.place_order(@credentials, @market,
                 account_number: "RH-1",
                 plug: plug,
                 max_body_bytes: 64,
                 retry_attempts: 3,
                 retry_delay: 1
               )

      assert reason == {:exchange_error, :robinhood, {:response_too_large, 64}}
      assert [{"POST", _path, raw}] = sent()
      assert Jason.decode!(raw)["client_order_id"] == id
    end
  end
end
