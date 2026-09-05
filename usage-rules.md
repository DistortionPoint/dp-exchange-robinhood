# Using `dp_exchange_robinhood`

> **EXPERIMENTAL.** Not run in production. Pin three-part. Maturity is per endpoint —
> read `capabilities/0`, not this banner.

Everything general is in
[`dp_exchange_core`'s usage rules](https://hexdocs.pm/dp_exchange_core/usage-rules.html).
This file is only what is **specific to Robinhood**.

## This venue has no streaming API, and you cannot tell

Robinhood Crypto publishes no socket. `subscribe/2` is served by a REST poll inside this
package and delivers the same `Core.Types.TopOfBook` to the same subscriber as a WebSocket
venue would. **Not `Core.Types.Quote`** — see the next section for why.

```elixir
children = [{DpExchange.Robinhood, credentials: creds, symbols: ["BTC-USD"], subscriber: self()}]
```

The one visible difference is `coverage/1`, which reports **`:internal_poll`** rather than
`:stream`. That is deliberate: the difference shows up as *what is arriving*, never as
*how*, so nothing above the facade branches on transport.

Do not build a poll of your own on top of this. The package already polls, paced against
this venue's budget, and a second loop doubles the request count for no extra data.

## Credentials are required for market data

Every call is signed with an Ed25519 key, the book included. There is no anonymous
endpoint:

```elixir
{:ok, book} = DpExchange.Robinhood.get_top_of_book("BTC-USD", credentials: %{
  api_key: "rh-api-…",
  private_key: "<base64 32-byte seed>"
})
```

**The private key is the base64 32-byte seed Robinhood issues**, not a 64-byte secret key.
Passing the wrong one is refused here with `{:invalid_private_key, {:expected_32_bytes, n}}`
rather than producing a signature the venue rejects with nothing to explain it.

You hold the credentials. This package signs one request with them and keeps nothing.

## `get_price/2` is `:unsupported` — this venue has no last-trade data at all

If you came here after filing an issue that looked like a Robinhood quote returning a
fabricated price, this is that incident's writeup — **DpCryptoManagement's issue #21.**

`best_bid_ask` is the only quote-adjacent endpoint this venue serves, and it carries only
`bid_inclusive_of_sell_spread` and `ask_inclusive_of_buy_spread` — never a trade price.
An earlier version of this package filled `Core.Types.Quote.price` from the ask whenever
the venue sent none. That produced a real-looking number with the wrong meaning: a taker's
ask, presented as a trade that never happened. `Core.Types.Quote`'s own moduledoc now names
this incident directly as the reason `Quote` carries no bid or ask field at all — a package
filling `price` from `ask` "is exactly what one of them did."

Removing that fallback was correct, and it left nothing honest for a last-trade call to
return. There is no separate trade-tape endpoint to fall back to either: Robinhood Crypto's
documented surface is nine operations in total, and none of the other eight is a trade feed
— confirmed by reading all five of the vendor's documentation pages, recorded in
`docs/reference/robinhood/negative-claims.md`. `get_price/2` therefore always returns
`{:error, :not_supported}`, and `venue_does_not_serve/0` lists it as the venue's own
absence, not a gap in this package.

`bid` and `ask` are both real and both still live — through `get_top_of_book/2` and the
`:top_of_book` poll above. If your code wants "the price," pick one of `bid` or `ask`
deliberately rather than reaching for a `price` field that no longer exists: **it is not a
mid**, and a series built from the ask sits a spread above a mid-based series from another
venue, which matters the moment you compare two venues' numbers.

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

## A missing venue timestamp does not fail the call

`get_top_of_book/2` carries `venue_time: nil` when the venue's row has no readable
timestamp, rather than refusing the call. That is correct, not a gap: `Core.Types.TopOfBook`
itself says `venue_time` is `nil` "where the venue publishes none," and a book that arrived
without a date is still a real, current book — refusing it would throw away a genuine bid
and ask over a field that is allowed to be absent. `observed_at` is always this package's
own clock at request time, whether or not the venue dated its own row.

## The catalogue is what your credential sees

`get_symbols/1` walks the paginated `trading_pairs` endpoint. The prior adapter measured 86
symbols, all USD-quoted, on 2026-08-05 — **as seen by that credential**. Listings can differ
by account tier, so treat the count as a property of your key rather than of the venue.

The walk stops if the venue ever points at a page it already served
(`{:error, {:pagination_loop, path}}`), rather than looping forever against a live API.

## v2 needs the account number that v1 did not

`get_accounts/2` is the prerequisite for everything else. **`opts[:account_number]` is a
required query parameter** on `get_balances/2`, `get_orders/2`, `get_order/3` and
`place_order/3` — v1 took none and answered for the credential's own account, so a call
without one is a v1 habit v2 will not honour. Each refuses locally with
`{:error, {:account_number_required, :robinhood}}` rather than sending it.

`cancel_order/3` is the exception: it takes no account number, and it is a **POST**, not a
DELETE. `get_accounts/2` itself reads only the first page of `V2AccountsResponse` — a
deliberate decision, not an oversight, because one account per credential is this venue's
common case; see `Rest.get_accounts/2`'s own doc if you are the credential that turns out to
have more than one.

## Two prices, and the one that accounts for size

- `get_top_of_book/2` — the top of the book, spread-inclusive as the venue publishes it
- `get_estimated_price/4` — what a **given quantity** would execute at now

There is no third. `get_price/2` is `:unsupported` — see above.

**`estimated_price` moved from `marketdata` to `trading` between v1 and v2.** A package
pointed at the old path gets a 404 that reads like an outage.

Several quantities go in one request — `["0.1", "1", "10"]` — which is how you see the slope
rather than three points taken at three times.

## Placing: the config key is named after the order's type

`market` takes `market_order_config`, `limit` takes `limit_order_config`, and so on. This
package builds that key from the type rather than taking it from you: **a config under the
wrong key is silently ignored and the order is placed with none.**

A limit without a price, or a stop-limit without a stop, is refused **by field name** before
the request.

**`time_in_force` is real on `limit`, `stop_loss` and `stop_limit` orders**, and this
package supports `:gtc` and `:day` (the venue's own `gfd`, "good for day") — pass either as
`opts[:time_in_force]` on `place_order/3`'s request map. Anything else this package cannot
send is refused locally as `{:error, {:unsupported_time_in_force, tif}}` rather than
silently dropped, which would have placed your order under an instruction the venue never
received. `market_order_config` carries no `time_in_force` in the venue's own schema, so a
market order never sends one regardless of what you pass. Reading an order back decodes the
venue's `gtc` and `gfd` the same way; a value this package has no atom for yet (the venue
also publishes `gfw` and `gfm`, "good for week" and "good for month") decodes to `nil`
rather than the nearest guess — `capabilities().supported_time_in_force` says which ones you
can actually place.

**`client_order_id` is an idempotency key.** It is generated when you do not supply one, and
re-sending the same one returns the original order instead of placing a second. If a request's
response never reached you, retry with the *same* id — `opts[:client_order_id]` is there for
exactly that.

## Cancelling is a request, not an outcome

`cancel_order/3` returns an order whose `status` is `:open`. **The venue acknowledges the
request and reports no outcome**, and telling you the order is gone would invite a second
order for the same exposure. Read it back with `get_order/3`.

## Fees ride on the order you placed, not a schedule

**This package calls v2 specifically to get `fee_charged`** — `to_order/1` decodes it as
`Order.fee` on every read. The venue does not state a currency for that figure, so
`fee_currency` stays `nil` rather than assuming it matches the pair's quote asset; that
assumption is a convention, not the venue's word. `estimated_fee_remaining` — a second real
field on the same response — has no slot on `Types.Order` and is not decoded, because there
is nowhere honest to put it.

## Holdings: total, tradable, and no hold figure

`get_balances/2` keeps `balance` and `available_balance` apart — the difference is a balance
sitting in an open order. **`hold` is `nil` because the venue publishes no such figure**, and
subtracting would state a number it never did.

## What this venue does not have

Money movement, in all of it. **This is a crypto brokerage with no funding API**: the
vendor's crypto trading documentation publishes nine endpoints and none of them is a payment
method, a transfer, an allowlist, a network list or a transaction ledger. Money reaches the
account through the Robinhood application, which needs a person.

**The no-streaming claim at the top of this file was checked, not inherited.** Five
documentation pages read in full: zero occurrences of `websocket`, `wss://` or `streaming`,
including in the JavaScript bundles that carry the endpoint lists. See
`docs/reference/robinhood/negative-claims.md`, which records every negative this package
makes with the source and date behind it, and the method, so any of them can be re-run.
