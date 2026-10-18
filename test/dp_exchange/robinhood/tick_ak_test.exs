defmodule DpExchange.Robinhood.TickAkTest do
  @moduledoc """
  Three defects found auditing options against the code, 2026-10-18.

    * `:environment` is one of Core's shared transport keys, so the key check accepted
      `environment: :sandbox`; Robinhood has no sandbox, and the call went to production under
      a name that said it was a test.
    * `:adapter`, `:weight`, `:max_retry_after_s` and `:max_body_bytes` passed the key check
      and were then dropped before `Core.HttpClient`, so a limit the caller set was absent.
    * `Feed` defined no `handle_cast/2`, so a stray cast crashed it.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Robinhood
  alias DpExchange.Robinhood.{Fake, Feed, Rest}

  @moduletag :capture_log

  defmodule WeighingLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, weight, _opts), do: weighed(weight)
    @impl true
    def check(_provider, weight, _opts), do: weighed(weight)
    @impl true
    def record(_provider, _weight, _opts), do: :ok

    defp weighed(weight) do
      send(self(), {:weight, weight})
      :ok
    end
  end

  @credentials %{api_key: "k", private_key: Base.encode64(:binary.copy(<<3>>, 32))}
  @order %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: "1"}
  @refused {:error, {:unsupported_option, :environment}}

  defp calls(module) do
    [
      {"get_top_of_book", &module.get_top_of_book("BTC-USD", &1)},
      {"get_symbols", &module.get_symbols(&1)},
      {"list_instruments", &module.list_instruments(&1)},
      {"quantization", &module.quantization("BTC-USD", &1)},
      {"get_balances", &module.get_balances(@credentials, &1)},
      {"get_accounts", &module.get_accounts(@credentials, &1)},
      {"place_order", &module.place_order(@credentials, @order, &1)},
      {"cancel_order", &module.cancel_order(@credentials, "o-1", &1)},
      {"get_order", &module.get_order(@credentials, "o-1", &1)},
      {"get_orders", &module.get_orders(@credentials, &1)},
      {"get_estimated_price",
       &module.get_estimated_price("BTC-USD", :ask, "1", @credentials, &1)},
      {"subscribe", &module.subscribe(["BTC-USD"], &1)},
      {"unsubscribe", &module.unsubscribe(["BTC-USD"], &1)},
      {"update_symbols", &module.update_symbols(["BTC-USD"], &1)},
      {"subscribe_notices", &module.subscribe_notices(&1)}
    ]
  end

  describe "an environment this venue does not have" do
    test "is refused by every facade call and by the Fake, with nothing sent" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:request, conn.request_path})
        Req.Test.json(conn, %{"results" => []})
      end

      for module <- [Robinhood, Fake], environment <- [:sandbox, :uat, "production"] do
        for {label, call} <- calls(module) do
          # Only the keys this call reads, so the one refusal left to fire is the environment's
          # and not an `{:unknown_option, key}` for a key the test should never have passed.
          own = Rest.function_options(String.to_existing_atom(label))
          extras = Keyword.take([account_number: "RH-1", feed: :no_such_feed_for_tick_ak], own)

          base = [environment: environment, credentials: @credentials, plug: plug]
          opts = base ++ [retry_attempts: 0] ++ extras

          assert call.(opts) == @refused, "#{inspect(module)} #{label} #{inspect(environment)}"
        end
      end

      refute_received {:request, _path}
    end

    test "absent, nil and :production are accepted" do
      for environment <- [nil, :production] do
        assert Rest.validate_opts([environment: environment], :get_orders) == :ok
        assert Rest.check_environment(environment: environment) == :ok
      end

      assert Rest.check_environment([]) == :ok
      assert Rest.check_environment(environment: :sandbox) == @refused
    end

    test "makes the reads with no error channel raise, on the facade and the Fake" do
      for module <- [Robinhood, Fake],
          read <- [&module.coverage/1, &module.coverage_by_kind/1, &module.wanted/1] do
        opts = [environment: :sandbox, feed: :absent_ak_feed]
        error = assert_raise ArgumentError, fn -> read.(opts) end

        assert Exception.message(error) =~ "unsupported option :environment"
      end
    end

    test "stops a feed at start rather than polling production" do
      Process.flag(:trap_exit, true)

      assert {:error, {:invalid_option, :environment}} =
               Feed.start_link(
                 name: :"feed_#{System.unique_integer([:positive])}",
                 credentials: @credentials,
                 symbols: [],
                 environment: :sandbox,
                 start_delay_ms: 60_000
               )
    end

    test "lets a feed start when the environment is :production" do
      assert {:ok, feed} =
               Feed.start_link(
                 name: :"feed_#{System.unique_integer([:positive])}",
                 credentials: @credentials,
                 symbols: [],
                 environment: :production,
                 start_delay_ms: 60_000
               )

      assert Process.alive?(feed)
    end
  end

  describe "transport keys the key check accepts reach Core.HttpClient" do
    setup do
      Config.put_override(:rate_limit_module, WeighingLimiter)
      :ok
    end

    test ":weight is the cost the limiter is asked for" do
      row = %{"symbol" => "BTC-USD", "bid" => "1", "ask" => "2"}
      plug = fn conn -> Req.Test.json(conn, %{"results" => [row]}) end

      assert {:ok, _book} =
               Robinhood.get_top_of_book("BTC-USD",
                 credentials: @credentials,
                 plug: plug,
                 retry_attempts: 0,
                 weight: 7
               )

      assert_received {:weight, 7}
    end
  end

  describe "a stray cast" do
    test "does not crash the feed" do
      {:ok, feed} =
        Feed.start_link(
          name: :"feed_#{System.unique_integer([:positive])}",
          credentials: @credentials,
          symbols: ["BTC-USD"],
          start_delay_ms: 60_000
        )

      GenServer.cast(feed, :stray)
      GenServer.cast(feed, {:update_symbols, ["ETH-USD"]})

      # A synchronous call returns only after both casts were handled, in order.
      assert Feed.wanted(feed) == ["BTC-USD"]
      assert Process.alive?(feed)
    end
  end
end
