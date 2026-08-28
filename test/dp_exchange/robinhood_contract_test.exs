defmodule DpExchange.RobinhoodContractTest do
  @moduledoc """
  Core's conformance suite, run against this package.
  """

  use DpExchange.Core.AdapterContract,
    venue: DpExchange.Robinhood,
    fake: DpExchange.Robinhood.Fake,
    symbol_format: DpExchange.Robinhood.SymbolFormat,
    sample_pairs: ~w(BTC-USD ETH-USD DOGE-USD),
    credentials: %{api_key: "test-key", private_key: Base.encode64(:binary.copy(<<1>>, 32))}
end
