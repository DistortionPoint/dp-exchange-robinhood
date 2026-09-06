# Idea: switch the feed to `best_bid_ask`'s bulk form

**Status:** not implemented. Recorded during the 2026-09-06 bug audit, alongside the fix for
the v1/v2 field-name defect in `Rest.get_top_of_book/3` (see CHANGELOG).

## What was found

Robinhood's v2 `best_bid_ask` endpoint accepts a repeated `symbol` query parameter —
`?symbol=BTC-USD&symbol=ETH-USD` — and returns a `results` array covering every symbol asked
for in **one** signed request. Confirmed against the vendor's own OpenAPI document,
`docs.robinhood.com/crypto/trading/`, 2026-09-06: the `symbol` parameter on
`GET /api/v2/crypto/marketdata/best_bid_ask/` is documented as repeatable, and the response
schema (`V2BestBidAskResponse`) is a plain array of `{symbol, bid, ask}` rows.

`Core.PollingFeed`'s own moduledoc names Robinhood as the intended user of its `:fetch_all`
mode for exactly this shape: *"Robinhood's 87 pairs cost one call per cycle that way and 87
without, and its rate limiter is not hypothetical: dropping to per-symbol fetches would
multiply this venue's request count by the size of its catalog."* This module's own
moduledoc, until this audit, said the opposite — that the venue "publishes no bulk-stats
endpoint" — and that claim was wrong. `best_bid_ask` genuinely carries no 24-hour
statistics, which is true and unrelated; it does not follow that there is no bulk form of
the endpoint that does exist.

## Why this is not a code change today

`Core.PollingFeed`'s `:fetch_all` path has no refusal handling. `fetch_all_and_publish/1`
matches only `{:ok, events}` and `{:error, reason}` — a `{:refused, _}` returned from
`:fetch_all` does not match either clause and would crash the feed's `GenServer` (a one_for_
one restart, but a real, repeating failure if it happens every cycle) rather than recording
one refused symbol and moving on, which is what the per-symbol `:fetch` path already does
correctly via `on_refusal`.

The vendor's document does not say what a batched `best_bid_ask` call does when one symbol
in the batch is delisted, unlisted, or malformed — whether the venue drops that row from
`results` and 200s the rest, or 400s the whole request. Given this venue's own history
(issue #16, issue #25 — both about a single bad signal contaminating a much larger batch),
guessing the wrong answer here is not a hypothetical: if the venue 400s the whole batch on
one bad symbol, switching to `:fetch_all` naively would turn "one delisted pair" into "the
whole feed crash-loops," which is a strictly worse failure than what per-symbol polling has
today.

## What would unblock it

Either:

1. A tier-2 (live, public endpoint, by hand, never on a schedule) probe of `best_bid_ask`
   with a batch containing one deliberately-invalid symbol, to observe whether the venue
   partial-fails or whole-fails the request — this repo cannot hold the credentials
   `best_bid_ask` needs, since every endpoint on this venue requires one; the probe would
   have to be run by whoever holds a credential, and the result written down here; or
2. A `dp_exchange_core` change giving `:fetch_all` an `on_refusal`-equivalent path, so a
   `{:refused, _}` from a bulk fetcher is handled the same way it already is from a
   per-symbol one.

Either would make this something to implement rather than something to guess at.
