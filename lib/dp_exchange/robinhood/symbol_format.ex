defmodule DpExchange.Robinhood.SymbolFormat do
  @moduledoc """
  Robinhood's symbol mapping.

  Its native symbol is **already canonical** `BASE-QUOTE` — `BTC-USD` — so the conversion
  is effectively identity. It is declared anyway, for two reasons.

  The contract is uniform: every venue implements both directions, so nothing above the
  facade needs to know that one venue's conversion happens to be free.

  And it is a **defensive boundary**. Any un-canonical form the venue ever returns is
  normalised here rather than leaking upward — a lowercase `btc-usd`, or a separatorless
  form from an endpoint nobody has looked at lately. Running the normaliser over an
  already-canonical string costs nothing; one venue quietly emitting a form the rest of the
  family does not recognise costs a symbol that matches no catalogue entry and collects
  nothing.
  """

  @behaviour DpExchange.Core.SymbolNormalizer

  alias DpExchange.Core.CanonicalPair

  # `sep: "-"` means the quote list is only consulted for a separatorless string, which
  # this venue never sends. Kept correct and ordered longest-first regardless: it costs
  # nothing, and it stops being merely cosmetic the moment someone reuses this mapping.
  @mapping %{sep: "-", quotes: ~w(USDC USDT USD BTC ETH)}

  @doc "The mapping, exposed so the conformance suite can drive `CanonicalPair` with it."
  @spec mapping() :: CanonicalPair.mapping()
  def mapping, do: @mapping

  @doc "The quote currencies this venue settles in."
  @spec quotes() :: [String.t()]
  def quotes, do: @mapping.quotes

  @impl true
  @spec to_canonical_symbol(String.t()) :: String.t()
  def to_canonical_symbol(native) when is_binary(native),
    do: CanonicalPair.to_canonical(@mapping, native)

  @impl true
  @spec to_exchange_symbol(String.t()) :: String.t()
  def to_exchange_symbol(canonical) when is_binary(canonical),
    do: CanonicalPair.to_exchange(@mapping, canonical)
end
