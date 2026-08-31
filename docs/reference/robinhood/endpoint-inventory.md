# Robinhood Crypto Trading API — endpoint inventory

**Source**: `docs.robinhood.com/crypto/trading/`, enumerated 2026-08-31 from the
documentation's own page bundle, which carries the endpoint list. **Primary vendor
documentation only.**

## Counts

| | operations | in this package |
|---|---|---|
| **v1** | **9** | **2** |
| **v2** | 9 (parallel set) | 0 |

## Endpoints

`✓` marks what this package implements today.

```
✓ GET    /api/v1/crypto/marketdata/best_bid_ask/
  GET    /api/v1/crypto/marketdata/estimated_price/
  GET    /api/v1/crypto/trading/accounts/
  GET    /api/v1/crypto/trading/holdings/
  GET    /api/v1/crypto/trading/orders/
  POST   /api/v1/crypto/trading/orders/
  GET    /api/v1/crypto/trading/orders/{order_id}/
  POST   /api/v1/crypto/trading/orders/{order_id}/cancel/
✓ GET    /api/v1/crypto/trading/trading_pairs/
```

### v2 — a complete parallel surface

```
  GET    /api/v2/crypto/marketdata/best_bid_ask/
  GET    /api/v2/crypto/trading/estimated_price/     ← moved from marketdata to trading
  GET    /api/v2/crypto/trading/accounts/
  GET    /api/v2/crypto/trading/holdings/
  GET    /api/v2/crypto/trading/orders/
  POST   /api/v2/crypto/trading/orders/              ← adds fee-tier orders
  GET    /api/v2/crypto/trading/orders/{order_id}/
  POST   /api/v2/crypto/trading/orders/{order_id}/cancel/
  GET    /api/v2/crypto/trading/trading_pairs/
```

## Notes

**The whole account, holdings and order surface is missing.** `place_order/3` is declared
`:unsupported` on a venue that supports it, so **this package cannot trade a venue that
can be traded** — the sharpest single consequence of the coverage gap anywhere in the
family.

**v1 and v2 are not a migration, they are two live surfaces.** The vendor states that all
read-only actions work on both, and that only v2 supports fee-tier order placement.
`estimated_price` moves from `marketdata` to `trading` between them. Implementing v1, v2
or both is a decision, not a skip.

**Every endpoint on this venue requires a credential** — there is no public surface, which
is why `credential_benefit` is `:required` and why no tier-2 test exists here.

## Streaming: checked against the vendor, not inherited

This package polls, and every document in this family has said the venue "has no streaming
API." **That claim originated in the host adapter's moduledoc** — a derived artefact — and
was carried forward four times without anyone checking it against Robinhood.

It has now been checked, and it holds. Method, so it can be re-run:

| check | result |
|---|---|
| `docs.robinhood.com/sitemap.xml` | 5 pages total: `/`, `/crypto/`, `/crypto/connect/`, `/crypto/trading/`, `/healthcheck/`. **No streaming page.** |
| `websocket`, `wss://`, `streaming` across all three doc pages | **0 occurrences** |
| the trading page's own JS bundle (which carries the endpoint list) | **0** — 67 apparent `sse` hits are the substring in *asset* |
| the Connect bundle | same |
| any `ws://` or `wss://` URL anywhere in the documentation | **none** |

**Why the check mattered.** Schwab's package made the same claim on the same kind of
reasoning and was wrong: its streamer is absent from the OpenAPI documents because it is
not REST, and is documented in the prose beside them. The lesson is to check *every* page a
vendor publishes rather than the endpoint list alone. Robinhood has five pages and all five
were checked.

**A trap worth naming.** Searching the web for "Robinhood crypto API websocket" returns
confident claims that it "supports both REST and WebSocket interfaces." Those describe
**third-party wrappers**, not Robinhood's API. That is the derived-artefact error in its
most tempting form — a plausible answer from a source that is not the vendor.

This is an absence of evidence rather than a vendor statement that no streaming exists, and
absence is weaker than presence. But the documentation set is small, complete, and
enumerates every endpoint including a full parallel v2 — so if a stream existed, this is
where it would be.

## Re-capturing

The documentation is a Next.js single-page app; its sitemap lists only five pages. The
endpoint list lives in the page's own JS bundle:

```
curl -s https://docs.robinhood.com/crypto/trading/ | grep -oE 'src="[^"]+pages/crypto/trading[^"]+"'
curl -s https://docs.robinhood.com<that bundle> | grep -oE '/api/v[0-9]+/crypto/[a-z_/{}]*' | sort -u
```
