defmodule DpExchange.Robinhood.FakeInjectionTest do
  @moduledoc """
  Proves `Fake` actually consults `Core.FakeInjection` — the shared mechanism itself is
  tested in `dp_exchange_core`; this is the wiring, per function, in this package.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.FakeInjection
  alias DpExchange.Robinhood.Fake

  @credentials %{api_key: "k", private_key: "s"}

  describe "whole-call injection reaches every function with a real success path" do
    test "get_symbols/1" do
      FakeInjection.fail_always(:robinhood, {:error, :injected})
      assert Fake.get_symbols(credentials: @credentials) == {:error, :injected}
    end

    test "get_balances/2" do
      FakeInjection.fail_always(:robinhood, {:error, :injected})
      assert Fake.get_balances(@credentials, account_number: "1") == {:error, :injected}
    end

    test "get_accounts/2" do
      FakeInjection.fail_always(:robinhood, {:error, :injected})
      assert Fake.get_accounts(@credentials, []) == {:error, :injected}
    end

    test "place_order/3" do
      FakeInjection.fail_always(:robinhood, {:error, :injected})
      assert Fake.place_order(@credentials, %{}, account_number: "1") == {:error, :injected}
    end

    test "cancel_order/3" do
      FakeInjection.fail_always(:robinhood, {:error, :injected})
      assert Fake.cancel_order(@credentials, "id", []) == {:error, :injected}
    end

    test "get_order/3" do
      FakeInjection.fail_always(:robinhood, {:error, :injected})
      assert Fake.get_order(@credentials, "id", account_number: "1") == {:error, :injected}
    end

    test "get_orders/2" do
      FakeInjection.fail_always(:robinhood, {:error, :injected})
      assert Fake.get_orders(@credentials, account_number: "1") == {:error, :injected}
    end

    test "market_status/1" do
      FakeInjection.fail_always(:robinhood, {:error, :injected})
      assert Fake.market_status([]) == {:error, :injected}
    end

    test "with nothing queued, normal Fake behaviour is unaffected" do
      assert {:ok, _symbols} = Fake.get_symbols(credentials: @credentials)
    end
  end

  describe "symbol-targeted injection" do
    test "get_top_of_book/2 only fails for the targeted symbol" do
      FakeInjection.fail_always(:robinhood, "BTC-USD", {:error, :injected})

      assert Fake.get_top_of_book("BTC-USD", credentials: @credentials) == {:error, :injected}
      assert {:ok, _tob} = Fake.get_top_of_book("ETH-USD", credentials: @credentials)
    end

    test "quantization/2 only fails for the targeted symbol" do
      FakeInjection.fail_always(:robinhood, "BTC-USD", {:error, :injected})

      assert Fake.quantization("BTC-USD", credentials: @credentials) == {:error, :injected}
      assert {:ok, _quantum} = Fake.quantization("ETH-USD", credentials: @credentials)
    end

    test "a whole-call queue still reaches a symbol-taking function with no symbol-specific override" do
      FakeInjection.fail_always(:robinhood, {:error, :whole_call})

      assert Fake.get_top_of_book("BTC-USD", credentials: @credentials) == {:error, :whole_call}
    end
  end

  describe "queue_failures/2 is deterministic and pops in order" do
    test "returns queued outcomes, then resumes normal behaviour" do
      FakeInjection.queue_failures(:robinhood, [{:error, :first}, {:error, :second}])

      assert Fake.get_symbols(credentials: @credentials) == {:error, :first}
      assert Fake.get_symbols(credentials: @credentials) == {:error, :second}
      assert {:ok, _symbols} = Fake.get_symbols(credentials: @credentials)
    end
  end

  describe "bypass_credentials/1" do
    test "skips the venue-faithful credential refusal" do
      assert Fake.get_symbols([]) == {:error, {:missing_credentials, :robinhood}}

      FakeInjection.bypass_credentials(:robinhood)

      assert {:ok, _symbols} = Fake.get_symbols([])
    end

    test "the default, without calling bypass_credentials/1, is still venue-faithful" do
      assert Fake.get_top_of_book("BTC-USD", []) == {:error, {:missing_credentials, :robinhood}}
    end

    test "covers the account and trading surface too, not only market data" do
      FakeInjection.bypass_credentials(:robinhood)

      assert {:ok, _balances} = Fake.get_balances(%{}, account_number: "1")
      assert {:ok, _accounts} = Fake.get_accounts(%{}, [])
      assert {:ok, _order} = Fake.place_order(%{}, %{}, account_number: "1")
      assert {:ok, _order} = Fake.cancel_order(%{}, "id", [])
      assert {:ok, _order} = Fake.get_order(%{}, "id", account_number: "1")
      assert {:ok, _orders} = Fake.get_orders(%{}, account_number: "1")
    end
  end

  describe "quantization/2 — matches the real facade's arity and credential gating" do
    # `Rest.quantization/3` signs the request like every other call on this venue, and
    # `DpExchange.Robinhood.quantization/2` carries credentials through `opts`. A fake
    # exposing only `quantization/1` could never stand in for that call — swapping `Fake` in
    # at the `Config` seam and calling `quantization(symbol, opts)` the same way production
    # code does would raise `UndefinedFunctionError` — and answering success with no
    # credentials at all would be "differently capable" on top of that.
    test "quantization/2 exists and refuses without credentials, same as get_top_of_book/2" do
      assert Fake.quantization("BTC-USD", []) == {:error, {:missing_credentials, :robinhood}}
    end

    test "quantization/1 still works — opts defaults to [], which is still no credentials" do
      assert Fake.quantization("BTC-USD") == {:error, {:missing_credentials, :robinhood}}
    end

    test "quantization/2 succeeds once credentials are given" do
      assert {:ok, _quantum} = Fake.quantization("BTC-USD", credentials: @credentials)
    end

    test "bypass_credentials/1 covers quantization/2 too" do
      FakeInjection.bypass_credentials(:robinhood)

      assert {:ok, _quantum} = Fake.quantization("BTC-USD", [])
    end
  end

  describe "the account and trading surface gates on credentials, same as market data" do
    # `get_balances/2`, `get_accounts/2`, `place_order/3`, `cancel_order/3`, `get_order/3`
    # and `get_orders/2` used to ignore their `credentials` argument entirely: any value,
    # including `%{}`, answered success as long as an account number (where one is
    # required) was present. The real venue signs every one of these calls with no
    # anonymous endpoint, so that let a consumer's test pass with no credentials at all
    # against behaviour the real venue cannot produce.
    test "get_balances/2" do
      assert Fake.get_balances(%{}, account_number: "1") ==
               {:error, {:missing_credentials, :robinhood}}
    end

    test "get_accounts/2" do
      assert Fake.get_accounts(%{}, []) == {:error, {:missing_credentials, :robinhood}}
    end

    test "place_order/3" do
      assert Fake.place_order(%{}, %{}, account_number: "1") ==
               {:error, {:missing_credentials, :robinhood}}
    end

    test "cancel_order/3 — the one order call with no account number, but still signed" do
      assert Fake.cancel_order(%{}, "id", []) == {:error, {:missing_credentials, :robinhood}}
    end

    test "get_order/3" do
      assert Fake.get_order(%{}, "id", account_number: "1") ==
               {:error, {:missing_credentials, :robinhood}}
    end

    test "get_orders/2" do
      assert Fake.get_orders(%{}, account_number: "1") ==
               {:error, {:missing_credentials, :robinhood}}
    end
  end
end
