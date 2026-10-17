defmodule DpExchange.Robinhood.UnknownOptionTest do
  @moduledoc """
  A facade option the call does not read is refused as `{:error, {:unknown_option, key}}`,
  on the real facade and on the Fake, before anything is sent.

  A misspelt `sinse:` or `limt:` that is silently ignored returns a plausible answer to a
  different question than the caller asked. Every option-taking facade function checks its
  options with `DpExchange.Core.Options.check/2` against `Options.transport_options/0` plus
  its own keys (`Rest.function_options/1`, the one table). One table-driven test covers
  every function; the Fake must answer identically, and a queued Fake injection must not be
  consumed by a call refused for its options.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, FakeInjection, Options}
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

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{api_key: "k", private_key: Base.encode64(:binary.copy(<<3>>, 32))}
  @order %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: "1"}
  @stray :sinse

  # Every key of `Rest.function_options/1`'s table.
  @functions [
    :get_top_of_book,
    :get_symbols,
    :list_instruments,
    :quantization,
    :get_balances,
    :get_accounts,
    :place_order,
    :cancel_order,
    :get_order,
    :get_orders,
    :get_estimated_price,
    :subscribe,
    :unsubscribe,
    :update_symbols,
    :subscribe_notices,
    :coverage
  ]

  # Every option-taking facade function, as `{label, fun}`; `fun` takes the options.
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

  # Reads with no error channel: they raise rather than answer an empty map or list.
  defp raising_reads(module) do
    [
      {"coverage", &module.coverage(&1)},
      {"coverage_by_kind", &module.coverage_by_kind(&1)},
      {"wanted", &module.wanted(&1)}
    ]
  end

  defp capturing(test_pid) do
    fn conn ->
      send(test_pid, {:request, conn.request_path, conn.query_string})
      Req.Test.json(conn, %{"results" => []})
    end
  end

  test "every real facade function refuses a stray key, with nothing sent" do
    opts = [
      {@stray, 1},
      credentials: @credentials,
      account_number: "RH-1",
      plug: capturing(self()),
      retry_attempts: 0,
      feed: :no_such_feed_for_unknown_option
    ]

    for {label, call} <- calls(Robinhood) do
      assert call.(opts) == {:error, {:unknown_option, @stray}}, label
    end

    refute_received {:request, _path, _query}
  end

  test "a stray key holding nil is still refused" do
    opts = [{@stray, nil}, credentials: @credentials, account_number: "RH-1"]

    for {label, call} <- calls(Robinhood) do
      assert call.(opts) == {:error, {:unknown_option, @stray}}, label
    end
  end

  test "the Fake refuses exactly what the facade refuses, and does not consult an injection" do
    FakeInjection.fail_always(:robinhood, {:error, :injected})
    opts = [{@stray, 1}, credentials: @credentials, account_number: "RH-1"]

    for {label, call} <- calls(Fake) do
      assert call.(opts) == {:error, {:unknown_option, @stray}}, label
    end

    # Nothing was subscribed by a refused subscribe.
    assert Fake.wanted() == []
  end

  test "the misspelt key of a market read is unknown, not 'unsupported'" do
    assert Robinhood.get_symbols([{:limt, 1}, credentials: @credentials]) ==
             {:error, {:unknown_option, :limt}}

    assert Fake.get_symbols([{:limt, 1}, credentials: @credentials]) ==
             {:error, {:unknown_option, :limt}}
  end

  test "the reads with no error channel raise on a stray key, on the facade and the Fake" do
    for module <- [Robinhood, Fake], {_label, read} <- raising_reads(module) do
      error = assert_raise ArgumentError, fn -> read.([{@stray, 1}, feed: :absent_feed_uo]) end

      assert Exception.message(error) =~ "unknown option :sinse"
    end
  end

  test "each function's own keys are accepted" do
    for function <- @functions do
      own = Rest.function_options(function)
      assert Enum.all?(own, &is_atom/1), "#{function}"
      assert Rest.validate_opts(Enum.map(own, &{&1, nil}), function) == :ok, "#{function}"
    end

    assert Rest.validate_opts([plug: nil, limiter: nil, credentials: nil], :get_orders) == :ok
  end

  test "account_number is refused where the call would not send it" do
    refused = {:error, {:unknown_option, :account_number}}
    opts = [account_number: "RH-1", credentials: @credentials]

    for module <- [Robinhood, Fake] do
      assert module.get_accounts(@credentials, opts) == refused
      assert module.cancel_order(@credentials, "o-1", opts) == refused
      assert module.quantization("BTC-USD", opts) == refused
      assert module.get_estimated_price("BTC-USD", :ask, "1", @credentials, opts) == refused
    end
  end

  test "the allowed list is Core's transport keys plus the function's own" do
    for key <- Options.transport_options() do
      assert Rest.validate_opts([{key, nil}], :get_accounts) == :ok, inspect(key)
    end

    assert Rest.validate_opts([{:cursor, "c"}], :get_accounts) ==
             {:error, {:unknown_option, :cursor}}

    assert Rest.validate_opts([{:cursor, "c"}], :get_orders) == :ok
  end
end
