defmodule DpExchange.Robinhood.SymbolFormatTest do
  @moduledoc """
  This venue's native symbol is already canonical, so the mapping is effectively identity —
  and that is exactly why it had no tests of its own and why a bug in the shared normaliser
  reached it unnoticed.

  `SymbolFormat`'s own moduledoc calls the module "a defensive boundary": any un-canonical
  form the venue ever returns is normalised here rather than leaking upward. A boundary with
  no test is a claim, so these are the claims made concrete.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Robinhood.SymbolFormat

  describe "the identity mapping, asserted rather than assumed" do
    test "a canonical pair survives both directions" do
      for pair <- ~w(BTC-USD ETH-USD SOL-USDC ETH-BTC) do
        assert pair == SymbolFormat.to_exchange_symbol(pair)
        assert pair == SymbolFormat.to_canonical_symbol(pair)
      end
    end

    test "an un-canonical form the venue might emit is normalised, not leaked upward" do
      assert "BTC-USD" == SymbolFormat.to_canonical_symbol("btc-usd")
    end

    test "a separatorless form is NOT split, and the moduledoc now says so" do
      # `sep: "-"` means `CanonicalPair` never consults the quote list — it falls back to
      # quote-suffix matching only for `sep: ""`. So `"BTCUSD"` comes back uppercased and
      # unsplit rather than as `"BTC-USD"`.
      #
      # This module's own moduledoc used to claim the opposite, and pinning the real
      # behaviour is what stops the claim drifting back. The behaviour is the right one:
      # guessing a split from a quote suffix would turn a bare ticker ending in a quote code
      # (`PLUSD`) into `PL-USD`, a different instrument, silently.
      assert "BTCUSD" == SymbolFormat.to_canonical_symbol("BTCUSD")
      assert "BTCUSD" == SymbolFormat.to_canonical_symbol("btcusd")
    end

    test "a symbol with no quote part is not decorated with this venue's separator" do
      # This venue maps with `sep: "-"`, so `CanonicalPair.to_exchange/2` used to join
      # `base <> "-" <> ""` and hand back `"AAPL-"` for `"AAPL"`, and `"-"` for `""`.
      #
      # The fabricated string is plausible, which is what makes it expensive: it goes into a
      # request URL, the venue answers 404, and `classify/1` reports
      # `{:refused, :not_listed}` — telling a caller the VENUE said their symbol is not
      # listed, when what happened is that this package invented a symbol the venue was
      # never asked about.
      assert "AAPL" == SymbolFormat.to_exchange_symbol("AAPL")
      assert "BTC" == SymbolFormat.to_exchange_symbol("BTC")
      assert "" == SymbolFormat.to_exchange_symbol("")
      assert "BTC" == SymbolFormat.to_exchange_symbol("BTC-")
    end

    test "both directions are total — nothing raises and nothing is dropped" do
      for input <- ["", "NOTAPAIR", "---", "BTC-", "-USD", "btc"] do
        assert is_binary(SymbolFormat.to_canonical_symbol(input))
        assert is_binary(SymbolFormat.to_exchange_symbol(input))
      end
    end

    test "quotes/0 is ordered longest-first, as the normaliser requires" do
      quotes = SymbolFormat.quotes()
      assert quotes == Enum.sort_by(quotes, &byte_size/1, :desc)
    end
  end
end
