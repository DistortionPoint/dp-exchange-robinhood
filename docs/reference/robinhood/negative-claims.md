# Robinhood — every negative this package makes, and what is behind it

**Audited 2026-09-01.** A negative claim is any place this package says a venue *does not*
do something: an entry in `venue_does_not_serve/0`, an empty list in `capabilities/0`, a
`nil` where a number could have gone.

The rule this file exists to enforce: **an unverified negative is a substitution exactly
like an invented value.** "The venue has no order book" and "we never looked" produce the
same `{:error, :not_supported}`, and only one of them is true.

## Source

Robinhood publishes **five documentation pages** and no more — `docs.robinhood.com`'s own
sitemap lists `/`, `/crypto/`, `/crypto/connect/`, `/crypto/trading/` and `/healthcheck/`.
The endpoint list is not in the rendered HTML; it is in the page's JavaScript bundle, which
is where `docs/reference/robinhood/endpoint-inventory.md` reads it from.

**All five were read in full for this audit.** That is the whole vendor corpus, which is
what makes the negatives here stronger than they would be for a venue with a hundred pages.

## The claims

| claim | verified how | date | holds? |
|---|---|---|---|
| No streaming API | sitemap enumerated; `websocket` / `wss://` / `streaming` searched across all five pages **and their JS bundles**: 0 occurrences | 2026-09-01 | ✅ |
| No candles | no historical or bars operation among the nine | 2026-09-01 | ✅ |
| No order book | best bid/ask only; no depth operation | 2026-09-01 | ✅ |
| No public trade tape | no trades operation; the orders endpoint is the credential's own | 2026-09-01 | ✅ |
| No volume on a quote | `best_bid_ask` publishes no size field | 2026-09-01 | ✅ |
| No batch order placement | `POST …/orders/` takes one order; no list form in either v1 or v2 | 2026-09-01 | ✅ |
| No preview, no replace, no cancel-all, no close-position | the order surface is four operations: list, place, get, cancel-one | 2026-09-01 | ✅ |
| No money movement of any kind | none of the nine is a payment method, transfer, allowlist, network list or ledger | 2026-09-01 | ✅ |
| No staking, no perpetuals, no options | absent from both v1 and v2 | 2026-09-01 | ✅ |
| No conversion endpoint | neither one-step nor quote/commit | 2026-09-01 | ✅ |
| No watchlists, no issuer data, no screener | absent from both surfaces | 2026-09-01 | ✅ |
| No auction imbalance, no volume profile | a continuously-traded crypto book has no auction to have an imbalance in | 2026-09-01 | ✅ |
| No `hold` figure on a balance | holdings publish total and available; the difference is not itself published | 2026-09-01 | ✅ |
| ~~`get_fees`, `get_transfers`, `get_trade_history`, `get_rate_limit_status` are "not ported"~~ | **wrong label.** None of the nine operations is any of these — they are the venue's absence, not this package's backlog | 2026-09-01 | ❌ **corrected** |

## The one that was wrong, and why it is the interesting one

Four callbacks sat in `@not_ported` — the list that means *the venue serves this and we have
not got to it.* None of them is served. **The mislabel pointed the wrong way**: it told a
host that implementing them here would change the answer, when nothing done in this
repository ever could.

That is the same defect as a false `:unsupported`, wearing the opposite coat. A false
negative hides a capability the venue has; a false *backlog* item invents work that cannot
be done and quietly implies the venue has an endpoint it does not. Both are plausible, and
neither surfaces as a failure.

They now sit in `@venue_does_not_serve` with the count that disproves them.

## The trap this venue sets

Searching the web for "Robinhood crypto API websocket" returns confident claims that it
"supports both REST and WebSocket interfaces." **Those describe third-party wrappers.**
A derived artefact restating a vendor is not the vendor, and this is that error in its most
tempting form — a fluent, specific, wrong answer from a source that looks authoritative.

The same class of mistake is what made the streaming claim worth re-checking at all: it
originated in the *host application's* adapter moduledoc and was carried forward four times
before anyone read Robinhood's own pages. It happened to be right. It was not evidence.

## Absence of evidence, stated as such

Only the streaming claim rests on *not finding* something rather than on a vendor statement.
The documentation set is five pages, enumerates every operation including a complete
parallel v2, and contains no socket URL anywhere — so if a stream existed, this is where it
would be. That is strong. It is not the same as the vendor saying there is none, and this
file does not pretend otherwise.

## Re-running this

Everything above is re-derivable from `endpoint-inventory.md`'s "Re-capturing" section: two
`curl` calls fetch the bundle and enumerate the operations. If the count is no longer nine,
every row in the table above is stale.
