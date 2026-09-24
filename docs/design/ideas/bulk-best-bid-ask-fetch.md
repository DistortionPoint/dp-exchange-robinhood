# Idea: switch the feed to `best_bid_ask`'s bulk form

**Status:** implemented, 2026-09-08; fallback replaced, 2026-09-24. `Feed` polls in bulk
(`Rest.get_top_of_book_bulk/3`). A whole-batch refusal is bisected, and a refused symbol is
remembered and asked for on its own, where it used to fall back to one request per symbol.
See "What shipped" below.
Recorded during the 2026-09-06 bug audit, alongside the fix for the v1/v2 field-name defect
in `Rest.get_top_of_book/3` (see CHANGELOG).

**Kept here rather than deleted**, against this directory's usual convention of removing an
idea doc once its work lands: one thing this doc originally asked to have settled — what the
venue actually does when one symbol in a `best_bid_ask` batch is bad — is still unobserved.
The code no longer needs that answer (see "Why the design does not need to guess" below),
but a reader auditing this venue's coverage still might, so the open question stays written
down rather than disappearing along with the doc that raised it.

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

## What shipped

`Feed` polls in bulk now: `Rest.get_top_of_book_bulk/3` sends every symbol in scope as
repeated `symbol` query parameters in one signed request, decodes whatever `results` rows
come back. Request count at the ~86-pair catalogue this package inherited: roughly 86
signed requests a cycle before, 1 after.

**2026-09-24: the per-symbol fallback was replaced.** As first shipped, a refused bulk call
fell back to one request per symbol, sequentially, inside `PollingFeed`'s fetch, for every
cycle the bad symbol stayed in scope. That fetch is killed at 30s and this venue's limiter
allows 10 requests a second, so a large enough universe could not finish. A killed fetch
publishes nothing, so one bad symbol silenced every symbol, every cycle. It also fell back
on a 401, where every symbol is refused alike. Now `Feed.fetch_all/5` bisects a refused
batch within a 20s budget, remembers a refused symbol (`state.refused`) so the next bulk
request leaves it out and asks for it on its own, and does not split a 401. See `Feed`'s
moduledoc, "A refused batch is bisected, and a refused symbol is remembered".

## Why this was not a code change when first recorded

`Core.PollingFeed`'s `:fetch_all` path had no refusal handling. `fetch_all_and_publish/1`
matched only `{:ok, events}` and `{:error, reason}` — a `{:refused, _}` returned from
`:fetch_all` did not match either clause and would crash the feed's `GenServer` (a one_for_
one restart, but a real, repeating failure if it happens every cycle) rather than recording
one refused symbol and moving on, which is what the per-symbol `:fetch` path already did
correctly via `on_refusal`. `dp_exchange_core` has since gained that handling
(`fetch_all_and_publish/1`'s `{:refused, refusals}` clause), closing this condition.

The vendor's document does not say — and, as of this writing, still does not say — what a
batched `best_bid_ask` call does when one symbol in the batch is delisted, unlisted, or
malformed: whether the venue drops that row from `results` and 200s the rest, or 400s the
whole request. Given this venue's own history (issue #16, issue #25 — both about a single
bad signal contaminating a much larger batch), guessing the wrong answer here was not a
hypothetical: if the venue 400s the whole batch on one bad symbol, switching to `:fetch_all`
naively would turn "one delisted pair" into "the whole feed delivers nothing, every cycle,
forever" — strictly worse than per-symbol polling.

## Why the design does not need to guess

Rather than wait on a probe to answer the open question above, `Feed.fetch_all/5` is built
to be correct under EITHER possible venue behaviour,
without knowing which one is real:

- **If the venue drops the bad row and 200s the rest** (a `results` array shorter than what
  was asked for): `Rest.get_top_of_book_bulk/3` already publishes exactly the rows present.
  `Core.PollingFeed` treats a symbol absent from a bulk response as uncovered-and-retried,
  never as refused (`publish_and_record/2`) — the same principle
  `Rest.first_result/1`'s own moduledoc states for the single-symbol path, guarding against
  DpCryptoManagement issue #25's exact mistake (silence read as a permanent refusal).
- **If the venue 400s the whole batch**: the bulk call comes back `{:refused, _}`, and
  `Feed` splits the batch and asks again until it reaches the refused symbol, about
  2·log₂(N) requests for one bad symbol. Every refusal found is reported through the same
  `on_refusal` function `PollingFeed` itself would have used, and every symbol that
  answers still publishes in the SAME cycle. From the next cycle the refused symbol is
  asked for on its own and the rest are back to one request, without waiting for a
  consumer to drop it.

No consumer-visible behaviour depends on which of the two is true. See
`lib/dp_exchange/robinhood/feed.ex`'s moduledoc ("This does not guess") for the full
reasoning and `test/dp_exchange/robinhood/feed_test.exs`'s "bulk fetch" describe block for
the tests that prove it: the happy bulk path, a response short of what was asked for
(never refused), and a whole-batch refusal (the other symbols still publish, and the bad
one is reported once).

## What is still unknown, and what would settle it

Which of the two venue behaviours above is real is still not stated anywhere this package
can read, and the design above works precisely because it does not need to know. If a
reader wants the actual answer anyway — for auditing this venue's behaviour, not for this
package's correctness — the probe is unchanged from when this idea was first recorded: a
tier-2 (live, public endpoint, by hand, never on a schedule) call to `best_bid_ask` with a
batch containing one deliberately-invalid symbol alongside valid ones, observing whether the
venue partial-fails (a short `results` array, 200) or whole-fails (4xx) the request. This
repo cannot hold the credentials `best_bid_ask` needs — every endpoint on this venue
requires one — so the probe would have to be run by whoever holds a credential, with the
result written down here or in `docs/reference/robinhood/`.
