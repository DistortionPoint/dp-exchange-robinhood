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
