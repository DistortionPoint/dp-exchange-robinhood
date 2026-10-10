defmodule DpExchange.Robinhood.FakeFidelityTest do
  @moduledoc """
  The fake refuses what the real path refuses, from the real path's own rules, and the
  facade and the feed hand the rate limiter and its blocking flag to `Core.HttpClient`
  consistently even when a caller forwards `nil`.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Robinhood
  alias DpExchange.Robinhood.{Auth, Fake, Feed, Rest}

  @moduletag :capture_log

  @credentials %{api_key: "k", private_key: Base.encode64(:binary.copy(<<9>>, 32))}
  @account [account_number: "RH-1"]
  @order %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: "1"}

  defmodule RecordingLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, opts) do
      Process.put(:limiter_opts, opts)
      :ok
    end

    @impl true
    def check(_provider, _weight, opts) do
      Process.put(:limiter_opts, opts)
      :ok
    end

    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  describe "credentials: the fake applies Auth's rules, not a shape check" do
    test "a blank api key is refused as missing, like the real signer" do
      bad = %{@credentials | api_key: "  "}

      assert Auth.validate_credentials(bad) == {:error, {:missing_credentials, :robinhood}}
      assert Fake.get_accounts(bad, []) == {:error, {:missing_credentials, :robinhood}}
      assert Fake.get_top_of_book("BTC-USD", credentials: bad) == Fake.get_accounts(bad, [])
    end

    test "a private key that is not the base64 32-byte seed is refused, like the real signer" do
      bad = %{@credentials | private_key: "not a seed"}
      expected = {:error, {:invalid_private_key, :not_base64}}

      assert Auth.validate_credentials(bad) == expected
      assert Fake.get_accounts(bad, []) == expected
      assert Fake.get_balances(bad, @account) == expected
    end

    test "a nil private key is refused rather than accepted" do
      bad = %{@credentials | private_key: nil}

      assert Fake.get_accounts(bad, []) == {:error, {:invalid_private_key, :not_a_string}}
    end

    test "valid credentials pass both" do
      assert Auth.validate_credentials(@credentials) == :ok
      assert {:ok, _accounts} = Fake.get_accounts(@credentials, [])
    end
  end

  describe "place_order/3: the fake validates the order as Rest does, in the same order" do
    test "an empty request is refused with the field the real path names" do
      assert Rest.validate_order_request(%{}) == {:error, {:missing_field, :symbol}}
      assert Fake.place_order(@credentials, %{}, @account) == {:error, {:missing_field, :symbol}}
    end

    test "a limit order without a price is refused" do
      request = %{@order | order_type: :limit}

      assert Fake.place_order(@credentials, request, @account) ==
               {:error, {:missing_field, :price}}
    end

    test "an unsupported order type and an unrepresentable time in force are refused" do
      assert Fake.place_order(@credentials, %{@order | order_type: :trailing}, @account) ==
               {:error, {:unsupported_order_type, :trailing}}

      limit = Map.merge(@order, %{order_type: :limit, price: "1", time_in_force: :ioc})

      assert Fake.place_order(@credentials, limit, @account) ==
               {:error, {:unsupported_time_in_force, :ioc}}
    end

    test "the account is checked first and the credentials last" do
      assert Fake.place_order(%{}, %{}, []) == {:error, {:account_number_required, :robinhood}}
      assert Fake.place_order(%{}, %{}, @account) == {:error, {:missing_field, :symbol}}

      assert Fake.place_order(%{}, @order, @account) ==
               {:error, {:missing_credentials, :robinhood}}
    end

    test "a valid order is still accepted as open" do
      assert Rest.validate_order_request(@order) == :ok
      assert {:ok, %{status: :open}} = Fake.place_order(@credentials, @order, @account)
    end
  end

  describe "symbols: the fake canonicalises as the real path does" do
    test "a lower-case listed symbol is served under its canonical name" do
      assert {:ok, book} = Fake.get_top_of_book("btc-usd", credentials: @credentials)
      assert book.symbol == "BTC-USD"
    end

    test "quantization refuses an unlisted symbol instead of inventing increments" do
      assert Fake.quantization("NOPE-USD", credentials: @credentials) ==
               {:refused, :not_listed}

      assert {:ok, _quantum} = Fake.quantization("btc-usd", credentials: @credentials)
    end
  end

  describe "get_balances/2: :asset_codes narrows the holdings, not only the cash" do
    test "asking for an asset the fake does not hold returns no holding" do
      opts = @account ++ [asset_codes: ["ETH"]]

      assert {:ok, []} = Fake.get_balances(@credentials, opts)
    end

    test "asking for BTC returns the holding without the cash row" do
      opts = @account ++ [asset_codes: ["BTC"]]

      assert {:ok, [holding]} = Fake.get_balances(@credentials, opts)
      assert holding.currency == "BTC"
    end

    test "asking for the cash currency returns only the cash row" do
      assert {:ok, [cash]} = Fake.get_balances(@credentials, @account ++ [asset_codes: "USD"])
      assert cash.currency == "USD"
    end

    test "no narrowing returns both" do
      assert {:ok, [_holding, _cash]} = Fake.get_balances(@credentials, @account)
    end
  end

  describe "the facade names this venue's limiter even for a forwarded `limiter: nil`" do
    test "a REST call reaches the limiter under the supervisor's name" do
      Config.put_override(:rate_limit_module, RecordingLimiter)

      row = %{"symbol" => "BTC-USD", "bid" => "1", "ask" => "2"}
      plug = fn conn -> Req.Test.json(conn, %{"results" => [row]}) end

      assert {:ok, _book} =
               Robinhood.get_top_of_book("BTC-USD",
                 credentials: @credentials,
                 plug: plug,
                 retry_attempts: 0,
                 limiter: nil
               )

      assert Keyword.get(Process.get(:limiter_opts), :limiter) ==
               DpExchange.Robinhood.Supervisor.limiter_name([])
    end
  end

  describe "the feed's request options" do
    defp request_opts(extra) do
      name = :"feed_#{System.unique_integer([:positive])}"

      base = [name: name, credentials: @credentials, symbols: [], start_delay_ms: 600_000]
      {:ok, pid} = Feed.start_link(base ++ extra)

      on_exit(fn ->
        try do
          GenServer.stop(pid, :normal)
        catch
          :exit, _reason -> :ok
        end
      end)

      :sys.get_state(pid).request_opts
    end

    test "a forwarded `rate_limit_blocking: nil` still defaults to blocking" do
      assert request_opts(rate_limit_blocking: nil)[:rate_limit_blocking] == true
    end

    test "an explicit `rate_limit_blocking: false` is honoured" do
      assert request_opts(rate_limit_blocking: false)[:rate_limit_blocking] == false
    end

    test "`:timeout` and `:log_requests` reach the poll's requests" do
      opts = request_opts(timeout: 4_321, log_requests: false)

      assert opts[:timeout] == 4_321
      assert opts[:log_requests] == false
    end
  end
end
