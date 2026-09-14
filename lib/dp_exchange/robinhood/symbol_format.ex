defmodule DpExchange.Robinhood.SymbolFormat do
  @moduledoc """
  Robinhood's symbol mapping.

  Its native symbol is **already canonical** `BASE-QUOTE` — `BTC-USD` — so the conversion
  is effectively identity. It is declared anyway, for two reasons.

  The contract is uniform: every venue implements both directions, so nothing above the
  facade needs to know that one venue's conversion happens to be free.

  And it is a **defensive boundary**. Any un-canonical form the venue ever returns is
  normalised here rather than leaking upward — a lowercase `btc-usd`, or an alias this venue
  spells its own way. Running the normaliser over an already-canonical string costs nothing;
  one venue quietly emitting a form the rest of the family does not recognise costs a symbol
  that matches no catalogue entry and collects nothing.

  **It does NOT cover a separatorless form, and that is deliberate.** The paragraph above used
  to promise it did, and the `@mapping` comment below used to read as though that case reached
  the quote list. Neither was true: `CanonicalPair` consults the quote list only for a mapping
  that declares `sep: ""`, so on a dashed mapping a string with no dash takes the `:nomatch`
  path and comes back uppercased and unsplit.

  The behaviour is right and the promise was wrong. Guessing a split from a quote suffix is
  safe on a venue that only ever names pairs, and unsafe in general — a bare ticker ending in
  a quote code (`PLUSD`) would become `PL-USD`, a different instrument, silently. An
  unrecognised separatorless string that matches no catalogue entry is the cheaper failure of
  the two, because it collects nothing rather than collecting the wrong thing.
  """

  @behaviour DpExchange.Core.SymbolNormalizer

  alias DpExchange.Core.CanonicalPair

  # `sep: "-"` means the quote list is NEVER consulted. `CanonicalPair` falls back to
  # quote-suffix matching only for a mapping that declares `sep: ""`, and a dashed mapping
  # takes the `:nomatch` path for anything without a dash. This used to say "only consulted
  # for a separatorless string, which this venue never sends", which reads as though that
  # case reaches the list. It does not reach it at all.
  #
  # Kept correct and ordered longest-first anyway: it costs nothing, and it stops being
  # merely cosmetic the moment someone reuses this mapping for a venue that concatenates.
  @mapping %{sep: "-", quotes: ~w(USDC USDT USD BTC ETH)}

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
