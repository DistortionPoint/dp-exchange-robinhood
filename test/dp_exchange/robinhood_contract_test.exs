defmodule DpExchange.RobinhoodContractTest do
  @moduledoc """
  Core's conformance suite, run against this package.
  """

  use DpExchange.Core.AdapterContract,
    venue: DpExchange.Robinhood,
    fake: DpExchange.Robinhood.Fake,
    symbol_format: DpExchange.Robinhood.SymbolFormat,
    sample_pairs: ~w(BTC-USD ETH-USD DOGE-USD),
    credentials: %{api_key: "test-key", private_key: Base.encode64(:binary.copy(<<1>>, 32))},
    # The options this venue's own endpoints require before its fake will answer at all.
    #
    # Without these, every fake-driven assertion that calls an account-scoped endpoint was
    # refused for the MISSING ACCOUNT before it reached the behaviour under test, and the
    # suite took that refusal as a legitimate answer and skipped. Assertion 24 is how it
    # surfaced: niling this package's fake balance currency on purpose left the suite green,
    # while the two venues that need no account went red. Assertion 17 had the same shape —
    # it strips credentials and expects a failure, and got one for the account rather than
    # the credential.
    #
    # The key is this venue's, not Core's. A table of `:account_id` / `:account_number` /
    # `:account_hash` inside the contract would be exactly the venue-specific knowledge the
    # contract exists to keep out of Core.
    endpoint_opts: %{
      {:get_balances, 2} => [account_number: "contract-account"],
      {:get_orders, 2} => [account_number: "contract-account"],
      {:place_order, 3} => [account_number: "contract-account"],
      {:get_order, 3} => [account_number: "contract-account"]
    }
end
