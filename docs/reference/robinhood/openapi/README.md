# Robinhood Crypto Trading API — the vendor's OpenAPI document

`crypto-trading.openapi.json` is the vendor's own OpenAPI 3.0.1 document for the Crypto
Trading API, 14 paths, fetched 2026-09-29.

**It is not published as a file.** The documentation page, https://docs.robinhood.com/crypto/trading/,
renders from a Next.js bundle that carries the whole specification as one
`JSON.parse('…')` string literal. On 2026-09-29 that bundle was
`https://docs.robinhood.com/_next/static/chunks/pages/crypto/trading-8436f0bde21c73a2dc6c.js`.
The hash in that name changes with every deploy of their site, so the URL is not a stable
citation; the page is (see `../doc-sources.tsv`).

`extract.mjs` is how the JSON here was produced from that bundle, so a later capture can be
diffed against this one rather than re-read by hand:

```sh
# find the current bundle name in the page's HTML, fetch it, then:
node extract.mjs trading-<hash>.js crypto-trading.openapi.json
```

It reads the first `JSON.parse('…')` literal, un-escapes it as JavaScript would, and writes the
parsed document back out pretty-printed. Nothing is edited by hand.

**Why it is committed.** A 2026-09-29 audit against this document found an order's `quantity`
read from `filled_asset_quantity` (so every order reported its filled amount as its size), and
holdings and orders read one page as the whole list. Neither was visible from this repository
before, because only the endpoint inventory had been committed and the test fixtures had been
written to agree with the code.
