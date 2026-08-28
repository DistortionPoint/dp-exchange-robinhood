# Using `dp_exchange_robinhood`

> **EXPERIMENTAL.** Not run in production. Pin three-part. Maturity is per endpoint —
> read `capabilities/0`, not this banner.

Everything general is in
[`dp_exchange_core`'s usage rules](https://hexdocs.pm/dp_exchange_core/usage-rules.html).
This file is only what is **specific to Robinhood**.

## This venue has no streaming API, and you cannot tell

Robinhood Crypto publishes no socket. `subscribe/2` is served by a REST poll inside this
package and delivers the same `Core.Types.Quote` to the same subscriber as a WebSocket
venue would.

```elixir
children = [{DpExchange.Robinhood, credentials: creds, symbols: ["BTC-USD"], subscriber: self()}]
```

The one visible difference is `coverage/1`, which reports **`:internal_poll`** rather than
`:stream`. That is deliberate: the difference shows up as *what is arriving*, never as
*how*, so nothing above the facade branches on transport.

Do not build a poll of your own on top of this. The package already polls, paced against
this venue's budget, and a second loop doubles the request count for no extra data.

## Credentials are required for market data

Every call is signed with an Ed25519 key, quotes included. There is no anonymous endpoint:

```elixir
{:ok, quote} = DpExchange.Robinhood.get_price("BTC-USD", credentials: %{
  api_key: "rh-api-…",
  private_key: "<base64 32-byte seed>"
})
```

**The private key is the base64 32-byte seed Robinhood issues**, not a 64-byte secret key.
Passing the wrong one is refused here with `{:invalid_private_key, {:expected_32_bytes, n}}`
rather than producing a signature the venue rejects with nothing to explain it.

You hold the credentials. This package signs one request with them and keeps nothing.

## The price is the ask

`best_bid_ask` returns the prices a taker would get. Where the venue sends no separate
price, this package uses the **ask** — a real quoted number, and the one a buyer pays.

**It is not a mid.** A series built from it sits a spread above a mid-based series from
another venue, which matters the moment you compare two venues' prices. `bid` and `ask` are
both carried; compute whatever you actually want.

## No candles, no order book, no volume

The venue publishes none of them:

| | |
|---|---|
| `get_historical_prices/4` | `{:error, :not_supported}` |
| `get_order_book/2` | `{:error, :not_supported}` |
| `volume` on a quote | always `nil` |

`historical_timeframes` is an **empty list**, which is the honest answer for a venue with
no candle endpoint. Route backfill and volume-dependent work elsewhere.

`venue_does_not_serve/0` tells you which `:unsupported` endpoints are the venue's shape
versus which this package simply has not ported — both answer the same way, but only one of
them might change.

## Timestamps come from the venue, or the call fails

A quote the venue did not date returns `{:error, :missing_venue_timestamp}`. The local
clock is never substituted, because an undated quote stamped with your own clock is
indistinguishable from a fresh one.

## The catalogue is what your credential sees

`get_symbols/1` walks the paginated `trading_pairs` endpoint. The prior adapter measured 86
symbols, all USD-quoted, on 2026-08-05 — **as seen by that credential**. Listings can differ
by account tier, so treat the count as a property of your key rather than of the venue.

The walk stops if the venue ever points at a page it already served
(`{:error, {:pagination_loop, path}}`), rather than looping forever against a live API.
