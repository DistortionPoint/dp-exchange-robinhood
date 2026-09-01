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
