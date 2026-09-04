# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Status: EXPERIMENTAL

Stated here rather than only per-release, because a reader arriving at a specific version
needs it as much as one reading the top.

This package has not run in production. While it is `0.x` the API may change without a
major version. Coverage is uneven by design: fakes are well covered, order placement and
authenticated flows are not.

**Whenever an endpoint moves to `:proven`, the entry that does it states the evidence** —
what was run against the live venue, and when.

## [Unreleased]

### Added

- **`Fake` wired to `Core.FakeInjection` — DpCryptoManagement's issue #14, reference
  implementation for the family.** Every function with a real success path (not an
  unconditional `Venue.not_supported()`) now checks a queued or always-set outcome first:
  `get_price/2`, `get_top_of_book/2` and `quantization/1` support per-symbol targeting,
  and `get_symbols/1`, `get_balances/2`, `get_accounts/2`, `place_order/3`,
  `cancel_order/3`, `get_order/3`, `get_orders/2` and `market_status/1` support
  whole-call injection. `authenticated/1` also honours
  `FakeInjection.credentials_bypassed?/1`, letting a wiring-only test skip the
  venue-faithful `{:refused, :missing_credentials}` default without changing it for
  anyone who doesn't call `bypass_credentials/1`. `subscribe/2`, `unsubscribe/2` and
  `update_symbols/2` are deliberately not wired — each takes a symbol list in one call,
  which whole-call injection cannot express partial failure for.

- **`quantization/1` is implemented.** It had sat in `@not_ported` with a comment already
  half-answering the question DpCryptoManagement filed (issue #5 against
  `dp_exchange_core`): "`trading_pairs` publishes min/max order size and increments per
  pair" — true, and nothing read them. `get_symbols/1` extracts only `symbol` from each
  row and discards the rest.

  Verified against Robinhood's own OpenAPI schema before wiring anything: `V2TradingPair`
  carries `asset_increment`, `quote_increment`, `max_order_size` and `min_order_amount`.
  **`min_order_size` is absent from the schema**, despite different prose — beside
  `estimated_price` — naming it as if it existed. `quantization/1`'s `min_quantity` is
  `nil` rather than a guess built from `min_order_amount`, which is a cash minimum, not a
  units one.

### Fixed

- **`Feed` never actually reached blocking (`acquire/3`) rate limiting, despite its own
  moduledoc documenting exactly why it needs it — DpCryptoManagement's issue #16.**
  `:rate_limit_blocking` — the option `Core.HttpClient.check_rate_limits/1` reads to
  choose `acquire/3` over fail-fast `check/3` — was missing from both `Feed.start_link/1`'s
  and `Rest.request_opts/1`'s own forwarded-options allowlists, so no caller could ever
  turn it on: every poll fell through to `check/3` regardless, and the exact failure the
  moduledoc describes (87 of 87 symbols delivering dropping to 8 of 87 in one cycle)
  reproduced live. Both allowlists now include it; `Feed.start_link/1` also defaults it
  to `true` — a poll's whole reason to exist is this venue's rate limit, so a slower
  cycle rather than a missing price is the only correct default for it. `Rest`'s own
  allowlist does not default it, since a direct one-off `get_price/2` call goes through
  the same code and fail-fast may be exactly what that caller wants.

- **`Decimal.new/1` raised on a non-numeric price string — the same defect class filed
  against `dp_exchange_webull` as DpCryptoManagement's issue #3.** Auditing every copy of
  the raising pattern in this package found it here too, in `rest.ex`'s `decimal/1`. Fixed
  with `Decimal.parse/1`, requiring the whole string be consumed — the idiom already
  established elsewhere in this family (`chain_strike/1`, `ws_decode.ex`).

  The lenient fix alone would have introduced a second, quieter defect: a malformed
  required field silently becoming `nil` instead of raising, which `@enforce_keys` does
  not catch. `get_price/3` now refuses the quote instead
  (`{:error, {:invalid_decimal, :price, value}}`), rather than delivering a `Quote` with a
  fabricated-looking `nil` in the field this venue's own usage-rules call the whole point
  of the endpoint.

### Documentation

- **Every negative this package makes is audited** —
  `docs/reference/robinhood/negative-claims.md`, fifteen claims with the source and date
  behind each. Robinhood publishes five documentation pages in total and all five were read,
  which is what makes these negatives stronger than most: the corpus is small enough to
  exhaust.

  Fourteen hold. **One was wrong, and it is the interesting one**: `get_fees/2`,
  `get_transfers/2`, `get_trade_history/2` and `get_rate_limit_status/2` sat in the
  "not ported" list — the one that means *the venue serves this and we have not got to it.*
  The venue serves none of them. That mislabel points the opposite way to a false
  `:unsupported`: it invents work that cannot be done, and quietly implies an endpoint the
  vendor does not publish. They now sit in `venue_does_not_serve/0`.

- **`docs/reference/robinhood/endpoint-inventory.md` marks every operation implemented.**
  It had recorded the family's sharpest coverage gap — "this package cannot trade a venue
  that can be traded" — and that gap is closed: all nine documented operations ship, on v2.

- **`usage-rules.md` covers the v2 surface**: the account number v1 did not need, the three
  prices and which one accounts for size, the order-config key named after the order type,
  `client_order_id` as an idempotency key, why a cancellation returns an open order, and why
  `hold` is `nil`.

### Changed

- **Core dependency moves to `~> 0.1.36`**, and `place_orders/3` is declared **absent with
  the reason**: this venue places one order per request. A batch is one request the venue
  accepts or rejects as a unit, and a caller placing several here calls `place_order/3`
  several times and reconciles the outcomes itself.

### Changed

- **`convert/4` and `get_trade_volume/2` (Core 0.1.22) are declared unsupported.** The venue
  publishes neither a one-step conversion nor the two-step quote/commit pair, and no
  account-volume report. Summing fills here would be this package's arithmetic rather than
  the venue's ledger, which is the number its fee tiers actually come from.


- **Core 0.1.21's three new callbacks are declared, and none of them exists here.** Read
  from the venue's v2 reference, 2026-09-01: the crypto order surface is four calls —
  list, place, get, and cancel-one. There is no preview, no amend, no bulk cancel and no
  position-closing endpoint. `preview_replace/4`, `cancel_all_orders/2` and
  `close_position/3` return `not_supported`, and the enumeration behind that is in
  `docs/reference/robinhood/`.


### Fixed
- **An ask is no longer used as a trade price.** `get_price/3` read
  `price || ask_inclusive_of_buy_spread`, so a response carrying no traded price produced a
  quote whose `price` was the **ask** — a resting order, not an execution. Every value was
  real, so nothing looked wrong; only the meaning was. A response with no traded price now
  returns `{:error, :no_trade_price_in_response}`.

  **This is a behaviour change for any consumer that was receiving those quotes**: where a
  quote previously arrived carrying an ask, an error now arrives instead. That is the
  intended direction — a stop or a position value computed from an ask is wrong by the width
  of the spread, and worst exactly when the book is thin.

  The test suite had asserted the old behaviour as intended, including a test named *"the
  price is the ASK when the venue sends no separate price"*. It now asserts the opposite, and
  fixtures carry a traded price deliberately inside the spread and equal to neither side.

### Changed
- `get_symbols/1` calls **`/api/v2/crypto/trading/trading_pairs/`**. v2's response is the
  same `results` + `next` shape, so this is a path change only.
- `get_price/3` **stays on v1** deliberately. v2's `best_bid_ask` documents its response as
  `{"results": [{"symbol", "bid", "ask"}]}` — top of book and nothing more. It carries no
  traded price and no timestamp, both of which `Core.Types.Quote` enforces. Representing
  top-of-book is a contract question for Core, not a path swap, and v1 remains documented and
  current in the meantime.

### Added

- **The whole v2 surface** — accounts, holdings, estimated price, the four order calls, and
  the market-data pair migrated from v1.

  **This package could not trade a venue that can be traded.** `place_order/3` was declared
  `:unsupported` on a broker whose documentation publishes it — the sharpest single
  consequence of the coverage gap anywhere in this family, and it is closed.

  **`account_number` is a required query parameter in v2** on holdings, on the order list,
  on one order and on placing one, where v1 took none and answered for the credential's own
  account. A call without it is not a smaller answer, it is a rejection, so each refuses
  with `{:error, {:account_number_required, :robinhood}}` before a request is made —
  `get_accounts/2` is where the number comes from.

  **`estimated_price` moved from `marketdata` to `trading` between the versions**, and a
  package pointed at the old path gets a 404 that reads like an outage. It is the third
  price on this venue and the only one that accounts for size: not `get_price/2`'s last
  trade and not `get_top_of_book/2`'s top of book. Several quantities can go in one request,
  which is how a caller sees the slope rather than three points taken at three times.

  **`client_order_id` is generated when the caller does not supply one, and it is an
  idempotency key.** Re-sending the same one returns the original order rather than placing
  a second, so a retry of a request whose response was never seen should pass the same id —
  which is why `opts[:client_order_id]` exists.

  **An order's configuration goes under a key named after its own type** —
  `market_order_config`, `limit_order_config` and so on — and this package builds that key
  from the type rather than taking it from the caller: a config under the wrong key is
  silently ignored and the order is placed with none. A limit without a price, or a
  stop-limit without a stop, is refused **by field name** before the request.

  **`cancel_order/3` returns an order whose status is `:open`.** The venue acknowledges the
  request and reports no outcome, and telling a caller the order is gone invites a second
  order for the same exposure. `get_order/3` says whether the cancel took.

  **Holdings keep the total and the tradable amount apart** — the difference is a balance
  sitting in an open order — and `hold` is `nil` because the venue publishes no such figure.
  Subtracting would state a number it never did.

  A state this package does not recognise maps to `nil`, never the nearest: a caller
  branching on `:filled` must not be handed it for a word that merely looked close.

### Changed

- **`best_bid_ask` and `trading_pairs` moved to v2**, which is what D5 makes the surface.
  Both functions already existed and both were on v1, which is why their coverage boxes
  stayed open. A test now asserts that no `/api/v1/` path remains in the code: a path is the
  one thing in an HTTP call that cannot be verified by reading the response, and the v1 paths
  still work.

- **Core dependency moves to `~> 0.1.35`**, and twelve further callbacks are declared absent
  with the reason. **This is a crypto brokerage with no funding API**: the vendor's crypto
  trading documentation publishes nine endpoints and none of them is a payment method, a
  transfer, an allowlist, a network list or a transaction ledger — money reaches the account
  through the Robinhood application, which needs a person. Checked against all five of the
  vendor's documentation pages on 2026-09-01.


- **`get_trades/2`, `get_auction_imbalance/2` and `get_volume_profile/3` are declared
  unsupported.** Read from the venue's v2 reference, 2026-09-01: the crypto surface is best
  bid/ask, estimated price, accounts, holdings, orders and trading pairs — no tape. A crypto
  book trades continuously, so there is no opening or closing auction to have an imbalance
  in, and the venue publishes no volume-at-price split. Not "unimplemented": there is
  nothing to implement.

- First release. Quotes and the catalogue behind `DpExchange.Core.Venue`, with a feed.
  108 tests including Core's 28 conformance assertions, passing first run.
- First release. Quotes and the catalogue behind `DpExchange.Core.Venue`, with a feed.
  108 tests including Core's 28 conformance assertions, passing first run.
- **Ed25519 request signing**, verified by checking that a signature this package produces
  verifies under the key the venue's own seed format derives. The signed payload is
  `api_key <> timestamp <> path <> method <> body`, where `path` **includes the query
  string** — the easiest thing to get wrong, and it fails as an unhelpful 401.
- A private key that is not the base64 32-byte seed the venue issues is refused with
  `{:invalid_private_key, …}` rather than producing a signature the venue rejects silently.

### This venue has no streaming API, and that is the point
- `subscribe/2` is served by a REST poll through `Core.PollingFeed`. What a consumer
  receives is identical to a socket venue's; `coverage/1` reports `:internal_poll` so the
  difference is visible as **what is arriving**, never as **how**.
- Before the facade, that absence travelled upward: the collection layer kept a poll set
  and decided which venues were exempt, and an operations page described these pairs in
  terms of a socket the venue does not have — sending readers hunting a streaming fault
  that cannot exist.

### Declared honestly rather than left to be discovered
- **`credential_benefit: :required`** — every call is signed, quotes included.
- **`historical_timeframes: []`** — the venue publishes no candle endpoint at all. An empty
  list is the honest answer; a populated one with an `:unsupported` endpoint behind it
  would be a declaration disagreeing with itself.
- **No order book, no volume.** `volume` is `nil`, never `0`.
- `venue_does_not_serve/0` separates what the **venue** does not offer from what this
  package has not ported. Both answer `{:error, :not_supported}`, but only one of them
  might ever change.

### Fixed, relative to the adapter this replaces
- **A bar or quote with no venue timestamp now fails** rather than being stamped with the
  local clock. The prior decoder ended with `|| DateTime.utc_now()`, which is the **fourth**
  venue in this family found carrying that same substitution.
- **The catalogue walk cannot loop.** A cursor walk trusts the venue to stop saying "next";
  if it ever points at a page already fetched, the caller hung forever with no error while
  the venue took a signed request every few milliseconds. Now
  `{:error, {:pagination_loop, path}}`. Found because a test hung.
