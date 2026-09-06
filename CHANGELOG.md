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

- **This feed now says out loud when it has delivered nothing, not only to a log a human
  has to go grepping for — DpCryptoManagement's issue #21, closed at the source.** Issue
  #21 was itself a wrong credential (ciphertext where a key belonged) making every fetch
  fail, every cycle, for a whole deployment, with the only trace `Core.PollingFeed`'s own
  `Logger.warning` — "has delivered NOTHING in 154 consecutive attempts" — a sentence
  nobody was watching for at the time. That earlier fix (below, `get_price/2` →
  `:unsupported`) closed the specific cause; it did nothing about the reporting gap, which
  is a defect on its own: any future outage of this feed, for any reason at all, would have
  been exactly as invisible.

  `dp_exchange_core` 0.1.50 closes the reporting gap in the contract itself:
  `PollingFeed.start_link/1` gained an `:on_notice` option, called with a
  `%Core.Notice{kind: :coverage_change}` the instant the feed crosses INTO
  delivering-nothing (`severity: :warning`) and a second time the instant it crosses back
  OUT (`severity: :info`, message naming how many consecutive failures preceded recovery).
  It fires **once per transition**, never once per failed tick and never once per sweep
  while an outage continues — an 86-symbol feed retrying every symbol every cycle does not
  turn one outage into a notice storm. `:on_notice` defaults to a no-op, so the option
  existing upstream was not itself a fix; a venue has to wire it.

  This package now does: `Feed.start_link/1` passes
  `on_notice: fn notice -> send(parent, {:dp_exchange, :robinhood, notice}) end`,
  the same shape and the same destination as the existing `on_refusal` wiring right next to
  it. The dependency floor moves to `~> 0.1.50` so this cannot compile against a Core that
  lacks the option. **Correction, below:** this entry originally said the fixed
  `subscriber:` was the whole integration and that `subscribe_notices/1` was staying a
  documented no-op "for exactly that reason" — that reasoning did not survive a closer
  look at what a caller of `subscribe_notices/1` actually got, which was nothing, ever,
  from a different pid than the one named at boot. See the entry below, same day.

  Three new tests in `feed_test.exs` prove the wiring end to end against a real `Feed`
  process and a forced-failing `plug:`, not against `PollingFeed` in isolation (its own
  latching logic is `dp_exchange_core`'s to cover): a single failed fetch on this venue's
  one-symbol-per-request feed already crosses the threshold, so the warning notice is
  deterministic on the very first tick; repeated failures across several more ticks do not
  produce a second notice; and a plug that fails twice then succeeds produces exactly one
  `severity: :info` "has resumed delivering after 2 consecutive failures" notice afterward.
  `retry_attempts: 0` is set in these tests specifically — `HttpClient`'s default retry
  backoff (up to ~3s per failed attempt) would otherwise make the notice arrive well after
  a bounded `assert_receive`, for a reason having nothing to do with the behaviour under
  test.

- **`subscribe_notices/1` registered a caller and threw the registration away — a
  same-day defect in the `on_notice` wiring above, not a separate incident.** The facade
  answered `:ok` unconditionally and never touched the feed at all: a consumer calling
  `DpExchange.Robinhood.subscribe_notices(to: monitoring_pid)` got `:ok` back and then
  nothing, ever, because the only pid the feed ever sent a `Core.Notice` to was the fixed
  `:subscriber` named at `start_link/1`. That distinction matters more now that a real
  notice — the coverage-outage pair above — actually travels this path: a monitoring
  process kept separate from the data-consuming one, which is an ordinary shape for a
  consumer to choose, silently received none of it.

  `DpExchange.Robinhood.Feed` gained a genuine `notice_subscribers` registry — the same
  shape `dp_exchange_schwab`'s own `Feed` already uses for its Streamer and
  fallback-poll notices — rather than declaring the single-fixed-subscriber design
  permanent. `Core.PollingFeed` was not changed and was not fought: it still injects
  exactly one `sink`, one `on_refusal` and one `on_notice` function, by design (see its
  own moduledoc on why that shape is deliberate); the fan-out that turns "one recipient"
  into "a set of recipients" lives one layer up, in this module, which is the layer that
  actually knows who is registered. Doing that required turning `Feed` into a `GenServer`
  in its own right — it used to simply *be* the `PollingFeed` process, registered under
  this module's name, with nowhere of its own to keep a set. `PollingFeed` now runs as an
  unnamed child that `Feed` holds a reference to, the same relationship Schwab's own
  `Feed` already has with its Streamer and fallback poll.

  `DpExchange.Robinhood.subscribe_notices/1` now calls through to that registry and
  answers `{:error, :feed_not_started}` when the feed is not running, matching
  `subscribe/2` and `update_symbols/2` rather than the blanket `:ok` it answered before
  regardless of whether anything was listening. Registration is additive: the fixed
  `:subscriber` from `start_link/1` keeps receiving notices exactly as before, so an
  existing consumer that never calls `subscribe_notices/1` sees no change.

  A second, smaller fix rode along: `send/2` to an unregistered atom raises, so a
  `to:` given as a registered name that later died would have crashed this feed on its
  next notice. `fan_out/2` resolves every recipient — the fixed subscriber included —
  before sending, and skips one that no longer resolves, the same fix already shipped in
  `dp_exchange_schwab` and `dp_exchange_coinbase` for the identical shape
  (DpCryptoManagement issue #15).

  A new test in `robinhood_test.exs` registers a subscriber through the facade call
  itself, not by passing `:subscriber` to `Feed.start_link/1` directly, drives the feed
  into the same delivering-nothing state the `on_notice` tests above use, and asserts the
  notice actually reaches that facade-registered pid — the exact call the false `:ok`
  used to accept and discard.

- **`coverage_by_kind/1` implemented — `dp_exchange_core` 0.1.48's optional callback,
  wired for family-wide consumer tooling even though this venue cannot reproduce the
  defect the callback exists to catch.** `coverage/1` reports what is observed arriving,
  truthfully, but collapses every kind of payload into one boolean — on a venue streaming
  several kinds behind one subscription, that hid a dark channel behind a healthy one for
  days (Coinbase's `level2`-vs-`ticker` incident, `dp_exchange_core`'s
  `Venue.coverage_by_kind/1` moduledoc has the full writeup). Robinhood streams exactly one
  kind, `:top_of_book`, delivered by poll — `Feed`'s fetcher is `Rest.get_top_of_book/3`,
  which returns exclusively `Core.Types.TopOfBook.t()`, never `Core.Types.Quote.t()`,
  because this venue has no last-trade endpoint at all. So the honest, structurally-derived
  answer is a single-key map, `%{top_of_book: coverage(opts)}` — not detecting a
  discrepancy that cannot occur here, but giving the family's tooling the same shape every
  venue answers. Wired on `Feed`, the facade and `Fake`; the dependency floor moves to
  `~> 0.1.48` so this cannot compile against a Core that lacks the callback. New tests
  assert a delivering symbol appears under `:top_of_book`, the union invariant against
  `coverage/1` holds, the reported kind is declared in `capabilities().streamable`, and the
  map carries exactly one key — and the conformance suite's assertion group 15 ("coverage
  by kind"), previously skipped for every venue that had not adopted the callback, now runs
  against this package and passes.

### Documentation

- **`usage-rules.md`'s `time_in_force` section still taught the pre-C7 vocabulary after the
  code moved past it.** The `gfw`/`gfm` fix below extended `capabilities().supported_time_in_force`
  to all four of the vendor's documented values and updated `Rest`'s own moduledoc, but
  `usage-rules.md` — the file that actually ships inside the Hex tarball and is what a
  consuming agent reads — still said "this package supports `:gtc` and `:day`" and described
  `gfw`/`gfm` as decoding to `nil` for "a value this package has no atom for yet," which
  stopped being true the moment Core `0.1.45` landed. A consuming agent reading only this
  file would have believed two of the four vendor values it could actually place were
  unsupported. Rewritten to name all four and to carry the one-release `nil` history forward
  as what it now is — closed, not current.

  Audited `README.md` and `usage-rules.md` end to end against live execution rather than by
  eye: `capabilities().endpoints` confirms `get_price/2 => :unsupported` and every other
  maturity the docs claim; `subscribe/2`'s delivered struct was confirmed against
  `Feed`'s poll (`Rest.get_top_of_book/3` constructs `%Core.Types.TopOfBook{}`) and against
  `feed_test.exs`'s own `assert_receive`; and all four `time_in_force` values were round-tripped
  live through `place_order/3` and a decoding response, none dropped. The `get_price/2` /
  ask-fallback docs this audit was chartered to re-check (R1 in `dp_exchange_core`'s
  `2026-09-05_family-wide-defect-sweep.md`) were already correct — no stale `Quote`-delivery
  or ask-fallback text remained.

  Also found and fixed, unrelated to `time_in_force`: `README.md`'s own usage example called
  `subscribe(["BTCUSD"], to: self())`, but the real facade's `subscribe/2` reads no `:to`
  option at all — only `Fake.subscribe/2` (a test double) honours one. On the real venue the
  subscriber is fixed once, at supervision start, via `subscriber:` in the child spec
  (`usage-rules.md`'s own example already did this correctly). The README example ran
  without error but silently did not do what it implied — a `to:` a reader would reasonably
  expect to redirect delivery per call had no effect. Rewritten to match `usage-rules.md`'s
  pattern: `subscriber: self()` on the child spec, plain `subscribe(["BTCUSD"])` on the call.

### Fixed

- **`gfw` and `gfm` now round-trip too, closing the one gap left open by the entry below.**
  Those two of the vendor's four documented `time_in_force` values decoded to `nil` for a
  single release, because Core's vocabulary had no atom for "good for week" or "good for
  month". They were deliberately left as `nil` rather than invented locally or mapped to a
  nearest-match value — a wrong atom on a real order is worse than an absent one, and
  declaring support this package could not honour would have been the same untrue claim as
  the empty list it replaced, pointing the other way.

  `dp_exchange_core` 0.1.45 added `:gfw`/`:gfm`, so the gap is closed: all four values the
  vendor's enum documents now decode, and `capabilities/0` declares all four. The dependency
  floor moves to `~> 0.1.45` so this cannot compile against a Core that lacks them. A new
  test walks the vendor's whole enum and asserts each value both decodes to a real atom and
  appears in the declaration — so a future vendor addition with no Core atom fails a test
  rather than quietly becoming `nil` on a live order.

- **`time_in_force` is wired, both directions — it is a real vendor field this package
  wrongly claimed absent.** Confirmed against Robinhood's own OpenAPI schema:
  `AddOrderV2.limit_order_config`, `.stop_loss_order_config` and `.stop_limit_order_config`
  (the request side) and the matching `OrderResponse` config objects (the response side —
  what `GET`/`POST /api/v2/crypto/trading/orders/` actually return) all carry
  `time_in_force`, enum `["gtc", "gfd", "gfw", "gfm"]`. `to_order/1` hardcoded `nil` with a
  comment asserting the venue publishes none; `order_config/2` never built the key; and
  `capabilities/0` left `supported_time_in_force` at its empty default, hiding the gap a
  second time.

  `order_config/2` now accepts `opts[:time_in_force]` of `:gtc` or `:day` (Core's existing
  atom for the venue's `gfd`, "good for day") on `limit`, `stop_loss` and `stop_limit`
  orders — the three the vendor's schema carries the field on; `market_order_config` has no
  such field, so a market order never sends one. Anything this package cannot send is
  refused locally as `{:error, {:unsupported_time_in_force, tif}}` rather than silently
  dropped, which would have placed an order under an instruction the venue never received.
  `to_order/1` decodes the venue's `gtc`/`gfd` back to the same atoms; `gfw`/`gfm` decode to
  `nil` because Core's `time_in_force` vocabulary has no atom for either yet — Core is
  being extended with both in the same defect-sweep batch this fix belongs to, but this
  package cannot use them until that version reaches Hex (tracked in
  `dp_exchange_core`'s `docs/design/2026-09-05_family-wide-defect-sweep.md` §3).
  `capabilities/0` now declares `supported_time_in_force: [:gtc, :day]`.

  The `trading_test.exs` fixture that asserted `time_in_force == nil` under a comment
  encoding the same wrong assumption as the code was rewritten to the vendor's real
  response shape, and five regression tests were added against it.

- **v2's own fee fields were discarded — `to_order/1` hardcoded `fee: nil` on the exact
  endpoint this package calls v2 *in order to get fee data from*.** `V2CryptoOrder`
  (Robinhood's own schema for what the v2 order endpoints return) carries `fee_charged` and
  `estimated_fee_remaining`, both real numeric fields. `to_order/1` now decodes
  `fee: decimal(row["fee_charged"])`. `fee_currency` stays `nil` — the vendor's schema
  states no currency for the figure, and assuming the pair's quote asset would be this
  package's own convention standing in for the venue's word, which this family's
  fail-closed rule refuses. `estimated_fee_remaining` has no slot on `Types.Order` and is
  not decoded, with a comment saying why rather than inventing one.

  Also recorded, not fixed: `get_accounts/2` reads only the first page of
  `V2AccountsResponse`, which carries the same `next`/`previous` cursors `get_symbols/2`
  deliberately walks. Left un-walked as a documented decision in `Rest.get_accounts/2`'s
  own doc — one account per credential is this venue's common case, and walking would be
  complexity against a case never observed — rather than an undocumented inconsistency.

### Documentation

- **`usage-rules.md` and `README.md` no longer teach the exact behaviour that caused
  DpCryptoManagement's issue #21.** `usage-rules.md` said `subscribe/2` delivered
  `Core.Types.Quote` (it delivers `TopOfBook` and always has, since the `get_price/2`
  fix below), carried a `get_price/2` usage example that crashes against the current
  `{:error, :not_supported}` return, and had a whole "The price is the ask" section
  describing the ask-fallback that *caused* issue #21 as if it were current behaviour.
  `README.md` carried the same broken `get_price/2` example. Both are rewritten: `get_price/2`
  is documented as unsupported with the incident named directly — so a reader hits the
  explanation before re-filing #21 — `get_top_of_book/2` is documented as the real
  market-data call, and `subscribe/2` is documented as delivering `TopOfBook` over the
  internal REST poll. This file ships inside the Hex tarball and is what a consuming agent
  reads; per `dp_exchange_core`'s own `CLAUDE.md`, "it is not optional and it is not the
  README."

- **`usage-rules.md`'s "Timestamps come from the venue, or the call fails" section was
  wrong — a missing venue timestamp does not fail `get_top_of_book/2`, and per
  `Core.Types.TopOfBook`'s own contract it should not.** `Rest.top_of_book_time/1` already
  swallowed a missing or unparseable timestamp into `venue_time: nil`, which
  `rest_test.exs` already asserted; the doc was stale prose from before the `Quote` →
  `TopOfBook` migration, where `:timestamp` was a required field. No code changed; the
  section is rewritten to say what the code actually does and why that is correct.

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

- **`get_price/2` is now `:unsupported` — the ask-fallback removal earlier in this file
  left it permanently non-functional, and DpCryptoManagement's issue #21 is the live
  consequence: 154 consecutive failures, 0 successes, every poll cycle since boot.**
  `best_bid_ask` — the only quote-adjacent endpoint this venue serves — carries only
  `bid_inclusive_of_sell_spread` / `ask_inclusive_of_buy_spread`, never a trade price.
  Confirmed no last-trade endpoint exists anywhere on the venue's documented nine-operation
  surface (`docs/reference/robinhood/negative-claims.md`: "No public trade tape"), and
  that `estimated_price` is not a substitute — its own doc already said so ("Not a quote
  and not a fill"), and it needs a side and quantity picked for it, which is fabrication
  with extra steps. `quoted_price/1` required `row["price"]`, a field this response shape
  never carries, so removing the ask fallback (the correct call — see `Core.Types.Quote`'s
  own moduledoc, which now names this exact incident as why `Quote` carries no bid or ask
  at all) left nothing honest for it to ever return.

  `get_price/2` now returns `{:error, :not_supported}` unconditionally, moved into
  `venue_does_not_serve/0`. `Rest.get_price/3`, `quoted_price/1` and the now-unused
  `required_decimal/2` are removed rather than left dead. `capabilities().streamable`
  changes from `[:quotes]` to `[:top_of_book]` — `:top_of_book` was always a real,
  precedented `data_kind` (Gemini already declares it) and this venue's whole "streaming"
  was already a REST poll internally, so `Feed`'s poll now calls `get_top_of_book/3`
  instead of the broken `get_price/3` and delivers `Core.Types.TopOfBook` instead of
  `Core.Types.Quote` — live bid/ask keeps flowing, honestly labelled, rather than the
  venue's whole quote stream going dark to avoid re-fabricating a trade price. `Fake`
  updated to match on both counts.

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
