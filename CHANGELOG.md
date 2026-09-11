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

- **This package now reports a link on the telemetry channel, where before it would have
  read as permanently disconnected.** `Core.Telemetry` said `[:dp_exchange, :link, …]` are
  the events "every venue package emits"; there was not one `:telemetry.execute/3` call
  anywhere in the family for as long as the spec existed. `:telemetry.attach/4` against a
  name nobody emits **succeeds** — so a consumer wired a dashboard to it, got no error, and
  saw an empty panel, which reads as a venue with no traffic rather than as an unimplemented
  spec.

  **This venue holds no socket — its link is the poller** — so the events come from
  `Core.PollingFeed` 0.2.8 rather than from anything here: `:link, :event` per delivered
  payload, and `:link, :up` / `:link, :down` mapped onto the delivering-nothing latch that
  already existed, so they inherit its once-per-crossing property and cannot storm on a long
  outage. What carries the route is package-internal; a consumer should not have to know
  which venues in the family hold a socket.

  `:bytes` is **absent** from this venue's `:link, :event`, not zero. A poll has no frame, so
  there is no point at which a byte count means what it does on a socket — and a consumer
  summing `:bytes` across a mixed fleet must get the streaming venues' throughput, not a
  total silently depressed by every poller reporting a confident zero.

  The request and rate-limit events come free with the same Core release, since this
  package's REST goes through `Core.HttpClient` and its metered calls through
  `Core.DefaultRateLimiter`.

  **The metrics channel is alongside the notice channel, never instead of it.** A
  `Core.Notice` is a condition a consumer must ACT on; telemetry is aggregate and lossy by
  design.

### Changed

- **`dp_exchange_core` floor raised to `~> 0.2.8`**, the release that both emits these events
  from the shared modules and adds `Core.Telemetry.link_event/2` for a route with no wire
  size to report.

## [0.3.4] - 2026-09-11

### Added

- **Back-pressure: a slow subscriber no longer gets an unbounded mailbox.** `Core.Venue`'s
  `subscribe/2` doc promised this from the day the contract was written, and no venue in
  this family implemented any of it — every one fanned out with a bare `send/2` and had
  never looked at a subscriber's mailbox. A consumer that stalled accumulated a mailbox
  until the node died, with no notice, no log line, and `coverage/1` reporting perfect
  health throughout, because the feed genuinely was delivering.

  Past a bound (default 10,000 queued messages, `:max_queue_len` at start) this feed stops
  sending to that subscriber and emits a `:degraded` notice naming it, the queue length and
  the bound — and a second `severity: :info` notice when it catches up. The pair brackets
  exactly the window a consumer has to reconcile from the pull endpoints.

  Implemented in `dp_exchange_core` 0.2.6 as `Core.Fanout`, shared rather than written five
  times. Three properties worth stating, because they are what make dropping acceptable at
  all: another subscriber that is keeping up is unaffected; `coverage/1` does not change,
  because it reports what the *venue* delivered to this package and not what this package
  forwarded; and **notices are never subject to the bound**, since the notice saying a
  subscriber is being dropped must not be the first casualty of that same subscriber being
  dropped.

  See `usage-rules.md`, "A slow subscriber gets dropped, and told".

### Changed

- **`dp_exchange_core` floor raised to `~> 0.2.6`, and this one is hard.** `Feed` calls
  `Core.Fanout.max_queue_len!/2` at `init/1` and `Core.Fanout.deliver/4` on every payload.
  Against a lower Core this package does not misbehave, it fails to compile — which is the
  good outcome.

- **The pid-or-registered-name subscriber resolution moved to `Core.Fanout.resolve/1`.** All
  five venues had written it identically since DpCryptoManagement's issue #15; the data path
  and the notice path now share one definition, so they cannot drift into disagreeing about
  what counts as a reachable subscriber.

## [0.3.3] - 2026-09-10

### Fixed

- **No published version was attributable to a changelog entry (dp-exchange-core issue
  #32).** Every entry in this repository's `CHANGELOG.md` sat under `## [Unreleased]` — in
  the **published tarball**, since `CHANGELOG.md` ships inside it — so a consumer could not
  tell which version introduced a breaking change, or whether they had already taken one.

  That mapping is load-bearing here rather than cosmetic. This family signals a breaking
  change with a **minor bump**, and those changes are repeatedly a refusal tuple or struct
  gaining a field: invisible to the compiler, and invisible to a test that pins the old
  shape. The reporting consumer's written upgrade procedure is *"read `CHANGELOG.md` for a
  `### Changed — BREAKING` section, then grep for every clause matching the old shape"* —
  which needs version → change. Without it, `### Changed — BREAKING` says *that* the shape
  changed and never whether they already have it.

  They gave two incidents from the same three days, and the difference between them is the
  whole argument: `dp_exchange_gemini` 0.1.42's refusal-shape change was found **after
  shipping**, by reading a fix comment, while `dp_exchange_webull` 0.4.0's was caught
  **before** — because that entry happened to name the version in its prose.

  **Two halves, because fixing only one would have let it recur immediately:**

  - **Going forward**, the release pipeline cuts a `## [x.y.z] - YYYY-MM-DD` heading itself,
    in the publish job and **before `mix hex.publish`** — a heading added after the upload
    would describe a tarball nobody can read.
  - **Retroactively**, the accumulated block now sits under a `## [<version>] and earlier`
    heading. Attributing each of ~1,600 lines to the exact release that carried it is
    archaeology; this restores the one fact a consumer needs from it — that none of it is
    pending — which is what the reporter suggested.

  The issue measured five packages, from their `deps/`. `dp_exchange_schwab` has the same
  defect and is not one of their dependencies, so it could not appear in their table: six
  instances, all fixed here.


## [0.3.2] and earlier - 2026-09-10

**Everything below this line is published.** Entries were accumulated under
`[Unreleased]` from the first release to `0.3.2`, so no reader could tell shipped work
from pending — dp-exchange-core issue #32. Attributing each entry to the exact version
that carried it would be archaeology across hundreds of releases; this heading restores
the one fact a consumer actually needs from it, which is that none of it is pending.

Releases from here on cut their own `## [x.y.z]` heading at publish time, so this is
the last block that will ever need a range.

### Changed — BREAKING

- **`Core.Types.Quote` and `Core.Types.OrderBook` no longer carry `:timestamp`.** They carry
  **`:venue_time`** (the venue's own, `nil` where the venue publishes none) and
  **`:observed_at`** (when this package read it, always present). Requires
  `dp_exchange_core ~> 0.2.1`; this package's own version takes a minor bump to signal it.

  `:timestamp` was documented as the venue's own and "never invented", and two packages in
  this family could not keep that promise, because the frames they decode carry no venue time
  at all. With one field their only options were to lie or drop real data, and they lied.

  **This package constructs neither type** — it delivers `Core.Types.TopOfBook`, which has
  had this shape from the start. Nothing here changed but the `dp_exchange_core` floor, and
  it moves in the same batch for a reason worth stating: a consumer pairing a `~> 0.1` venue
  with a `~> 0.2` one could not resolve them together, so the family moves as one or not at
  all.

  The full reasoning, the three options weighed and the consumer's own argument for this one
  are in `dp_exchange_core`'s
  `docs/design/closed/2026-09-09_venue-time-and-observed-time.md`, announced and answered as
  dp-exchange-core issue #31. `Trade`, `Fill`, `Balance` and `OrderBookDelta` are unchanged.

### Fixed

- **The `trading_pairs` pagination walk had no page bound, and the cycle guard could not
  substitute for one.** `walk/5` refused a `next` pointing at a path it had already
  fetched, which catches a venue that loops back — and cannot catch one that hands back a
  **new** path every time (`?cursor=1`, `?cursor=2`, …), because no path ever repeats. A
  venue-side defect of that shape would have walked forever, holding the caller and
  spending a signed request per page until something else broke. This was the only venue
  in the family walking a cursor with no bound; `dp_exchange_coinbase` and
  `dp_exchange_webull` both already had one.

  Bounded at 50 pages, failing closed with `{:error, :too_many_trading_pair_pages}` rather
  than returning what it had — a truncated catalogue answered as `{:ok, rows}` is a partial
  list presented as complete, which is the "nearby substitute where an error belongs"
  failure this family keeps paying for, and it is how every other venue's bound already
  behaves. Robinhood Crypto lists on the order of a hundred pairs, so 50 pages is roughly
  two orders of magnitude of headroom.

### Changed

- **The same walk is now linear rather than quadratic.** It accumulated with
  `acc ++ results` per page, copying the whole accumulator every time. Pages are now
  collected as a list of pages and concatenated once. Measured on the shapes that matter:
  50 pages × 250 rows is 1.1 ms quadratic against 63 µs linear.
  **At the bound that is ~0.02% of a walk dominated by 50 HTTP round trips** — this came
  along with the bound above rather than standing on its own, and the same pattern is
  deliberately left alone elsewhere in the family, where it is bounded and the
  measurement says it does not matter.

  The cycle guard's `seen` stays a plain list. A `MapSet` was tried and reverted: with
  the page bound in place the scan is over at most 50 entries, so it buys nothing
  measurable, and it cost a dialyzer opacity warning — a worse trade than the scan it
  removed.

### Fixed

- **Reads now carry `@call_timeout` explicitly, exactly as writes already did.**
  `coverage/1`, `coverage_by_kind/1`, `status/1` and `wanted/1` took `GenServer.call/2`'s
  implicit **five seconds** while every write named a generous one, and that asymmetry is
  what turned a bounded delay into a dead caller in dp-exchange-core issue #28: `coverage/1`
  is the call a consumer's health check makes, so any moment the Feed was legitimately busy
  for longer than five seconds turned a health check into an **exit** — and into a dead
  consumer process, when the read happened inside the consumer's own `handle_call/3`. The
  blocking is fixed at its sources rather than papered over here; this is the second line of
  defence. A read that has to queue behind something should wait for it, not die of it.

### Documentation

- **`Credentials`' moduledoc now says that the redaction wrap lives in `child_spec/1`, and
  that bypassing `child_spec/1` bypasses it.** Requested by the consumer who verified the
  dp-exchange-core #29 fix and then went looking for their canary in their own supervisor's
  state — and found it. Their supervision code builds the child spec itself
  (`start: {__MODULE__, :start_feed, [module, opts, pairs]}`) for a legitimate reason: a
  `Core.PollingFeed`-shaped facade defaults `subscriber` to `self()`, which resolves to the
  *supervisor* when `start_link/1` is called from `init/1`, so a different delivery target
  can only be set at `start_link` time. On that path `child_spec/1` never runs, their
  supervisor stores the raw map, and OTP renders the live key on the next crash exactly as
  before. **Upgrading does not fix it, because nothing from this package is on that path.**

  No code change: `wrap/1` and `wrap_opt/1` were already public, which was all that path
  needed. What was missing was anyone saying so — the natural assumption, "upgraded,
  therefore redacted", is wrong there, and assertion 22 cannot see it because it asks about
  `child_spec/1`'s own rendering. `dp_exchange_core`'s `usage-rules/auth.md` carries the
  full version, including the reshaping case that bit them: a host mapping its own key
  names into a venue's and returning a bare map re-introduces the leak in its own code,
  downstream of anything a package can reach.

### Fixed

- **A read-only coverage call could kill the feed — dp-exchange-core issue #28.**
  `handle_call` delegated straight into `Core.PollingFeed` with `GenServer.call/2`'s
  five-second default, into a process that could not answer while a fetch was in flight —
  `:fetch_timeout_ms` floors at **30 seconds**, so a coverage read landing during an
  ordinary poll was not unlucky, it was a guaranteed timeout. The exit propagated out of
  `handle_call/3` and killed `Feed`, which restarts from the static opts its supervisor
  holds and never carries a consumer's later subscriptions. The reporting consumer watched
  a live venue go **61 pairs to 0 and stay there**, with the process alive, idle, and
  passing every liveness check. Asking whether the venue was healthy is what made it
  unhealthy.

  `Core.PollingFeed` no longer blocks on its fetch, which removes the cause. These reads
  are guarded here regardless, and it is not belt-and-braces: a poller mid-restart, wedged
  by something else, or simply gone is a condition this `Feed` has to survive, and no fix
  inside `PollingFeed` can promise it always answers.

  The fallback says the least that is true. `c:DpExchange.Core.Venue.coverage/1` returns a
  map, so an error tuple is not sayable, and an absent symbol already means
  `:not_covered` — while replying with a **remembered** coverage would assert arrivals
  nobody confirmed, the "nearby substitute where an error belongs" this family keeps paying
  for. A `:link_down` notice carries what an empty map cannot: **"we could not ask" is not
  "nothing arrived"**, and only the notice distinguishes them.

- **Credentials were written to the log in cleartext by any crash — dp-exchange-core issue
  #29.** A supervisor stores the `{module, :start_link, [opts]}` MFA its child spec names,
  and OTP writes that argument list through `inspect/1` into the `Start Call:` line of the
  report it logs on **any** child termination. `:credentials` arrived as a plain map, so
  every crash printed the live secret in full. It needs no unusual conditions, it lands in
  ordinary application logs — the artifact most likely to be shipped to an aggregator or
  attached to a bug report — and it defeats credential hygiene upstream of it: a consumer
  can hold the key encrypted at rest and still have it written out in the clear. The
  reporting consumer found live keys this way and nearly pasted them into a GitHub issue
  while reporting a different bug.

  `child_spec/1` now wraps `:credentials` with `DpExchange.Robinhood.Credentials.wrap_opt/1`, and
  **the placement is the fix**: wrapping in `start_link/1` or `init/1` does nothing,
  because by then the supervisor above has already captured the raw list. `Feed.child_spec/1` does the same, for a consumer supervising the feed directly. Redacting the
  value rather than setting the `:sensitive` process flag is deliberate — that flag
  suppresses the whole report, including the stack trace that made the unrelated bug
  diagnosable. This keeps the report and removes only the secret. `dp_exchange_core`'s
  conformance suite gains **assertion 22** for exactly this, so it cannot come back here or
  arrive in a new venue.

### Added

- **`script/check_doc_sources.sh` and `docs/reference/robinhood/doc-sources.tsv`** — a weekly,
  non-blocking check that every vendor documentation page this package cites still resolves
  the way it did when a person read it. It records status and redirect destination and does
  **not** follow redirects or diff content: a permanent redirect is itself the change notice
  (this family lost a streaming API to one, announced by nothing else), while content
  diffing a rendered docs site would be red every week for reasons that are never the reason
  we care about. Built after auditing what would have caught each way five vendors'
  documentation turned out to be wrong — across that whole sample a *changelog* diff caught
  nothing, and an *index* diff was the only mechanism that ever fired. It earned itself
  immediately: on its first run in `dp_exchange_webull` it caught a cited page that 404s, and
  pulling that thread found a rate ceiling five times too permissive against that venue's own
  per-endpoint table. Scheduled Mondays 09:20 UTC via
  `.github/workflows/doc-sources-check.yml`, never on push, never in the publish chain.
  Documentation sites only — never a venue API, which tier 2's never-on-a-schedule rule
  still forbids.

  One page is tracked here, and that is the finding: `docs.robinhood.com/crypto/trading/`
  is the entire published surface for this venue. Every claim this package makes about
  Robinhood traces to it, so losing it silently would matter more here than anywhere else
  in the family.

### Changed

- **The feed polls `best_bid_ask` in bulk now — one signed request a cycle, not one per
  symbol.** At the ~86-pair catalogue this package inherited, that is roughly 86 signed
  requests a cycle before this change, 1 after — a consumer watching their rate limiter
  will see the drop. `Rest.get_top_of_book_bulk/3` uses the endpoint's own repeatable
  `symbol` query parameter (`?symbol=BTC-USD&symbol=ETH-USD`, confirmed against the
  vendor's OpenAPI document, 2026-09-06) to ask for every symbol in one request, and
  `Feed` now runs `Core.PollingFeed` in its bulk `:fetch_all` mode instead of per-symbol
  `:fetch`. Recorded as `docs/design/ideas/bulk-best-bid-ask-fetch.md` and deferred at the
  time because the vendor's document does not say what a batched call does when one
  symbol in it is bad, and `PollingFeed`'s `:fetch_all` path had no refusal handling —
  `dp_exchange_core` has since closed the second gap, and this change closes the first by
  not needing to guess: see the idea doc and `Feed`'s own moduledoc ("This does not
  guess") for the full reasoning.

  A `results` array shorter than what was asked for is published as-is — the venue not
  answering for a symbol on one request is silence, not a statement that the symbol does
  not exist, and turning it into a permanent refusal is the exact defect
  DpCryptoManagement issue #25 already fixed on the single-symbol path. A batch that is
  refused outright (400/401/403/404) falls back to one signed request per symbol, for
  that cycle only: the offending symbol is identified and reported through `on_refusal`
  (once, the correct refusal contract), and every symbol that answers fine still
  publishes in the SAME cycle rather than waiting behind the bad one. No single bad
  symbol can deny the feed permanently; the worst case is one degraded cycle — back to
  86 requests — for as long as the refused symbol stays in scope.

### Documentation

- **`capabilities/0`'s `measured_against` now says what would settle its unprobed rate
  ceilings, not just that they are unprobed.** Family-wide sweep for the constant class
  behind `dp_exchange_coinbase`'s `@pairs_per_socket` incident: a venue fact carried
  unverified into a place a verified one belongs. `public_ceiling`/`authenticated_ceiling`
  (`limit: 10, per_ms: 1_000`) were already honestly flagged "ceilings NOT probed" and no
  number changed — Robinhood's documentation (`docs/reference/robinhood/endpoint-
  inventory.md`) publishes no rate-limit figures and every endpoint is signed, so nothing
  here can be ramped anonymously from this repository. Added the probe that would settle
  it: a credentialed consumer deliberately ramping request rate against one read endpoint
  and recording the first `429`, by hand. Price/quantity increments are read per-pair
  from the venue rather than hardcoded.

- **`Feed.@interval_ms` (30s) gained a comment distinguishing "matches the platform's
  cadence" from "derived from the venue's rate ceiling" — no behaviour change.** A closer
  read of the sweep above found this one worth a second pass: the prior comment justified
  the interval by the host platform's own convention, without saying whether that
  happened to respect `public_ceiling`/`authenticated_ceiling` above or was chosen
  independently of them. It is the latter — `PollingFeed` spreads each tick's fetches
  evenly across `interval_ms`, so at the ~86-symbol catalogue this package inherited this
  cadence produces roughly 2.9 req/s, comfortably under the declared (and itself
  unverified) 10 req/s ceiling, but that headroom was never stated and is a coincidence
  of the two numbers rather than one derived from the other. Said so in place.

- **`market_status/1` gained a stated reason for its `{:ok, :open}` answer — no behaviour
  change.** `dp_exchange_core` 0.1.66's widened assertion 17 flagged this callback for
  answering `{:ok, _}` with no credential on a `credential_benefit: :required` venue,
  identically to `dp_exchange_webull`'s. Unlike Webull's, this venue's answer was already
  correct: `asset_classes/0` is `[:crypto]`, this package's only asset class here, and
  crypto has no exchange-mandated trading session for the literal to lie about. It was an
  undocumented bare literal rather than an evidenced decision, though, and "defensible"
  is not "recorded".

  Now documented in `DpExchange.Robinhood.market_status/1`'s own doc: why the answer is
  correct without a venue call (checked against the vendor's own documentation —
  `docs/reference/robinhood/endpoint-inventory.md` records that all 9 of Robinhood's
  documented operations are implemented here and none is a market-status or
  trading-calendar call, so there is nothing to fetch even if this answer needed one),
  and what would make it wrong: this package ever serving a second asset class here, or
  a genuine trading suspension this package has no endpoint to observe (a different
  question from the one this callback answers, and one it does not claim to cover).
  `docs/reference/robinhood/negative-claims.md` records the same check.

  Resolved in `dp_exchange_core` by a narrow addition to assertion 17's credential gate
  rather than here: the gate now also skips `market_status/1` when a venue's own
  `asset_classes/0` is exactly `[:crypto]`, grounded in the callback's own contract doc
  ("crypto venues answer `:open`") — not a blanket exemption, since `dp_exchange_schwab`
  (not crypto-only) stays gated on the identical callback. Regression tests added in
  `robinhood_test.exs` (`describe "market_status/1"`) pin both the answer and the
  crypto-only condition the exemption relies on.

### Fixed

- **A crash of `Feed` printed the Ed25519 `private_key` seed — and the `api_key` — in
  cleartext, in OTP's own crash report.** `Auth.headers/5`'s own moduledoc says this
  package "signs one request, and keeps nothing", which is true of the signing call
  itself, but `Feed` keeps a copy of `state.credentials` for its whole lifetime anyway:
  `start_poller/1` closes over it to build the `fetch` callback `Core.PollingFeed` calls
  on every tick, and a crash-restart needs the original value to rebuild that closure.
  OTP's default crash report prints a `GenServer`'s state in full on termination, and a
  plain map field prints every key including the raw key material — verified by
  crashing an equivalent process holding `%{api_key: "...", private_key: "..."}` as a
  bare state field and reading the resulting log line back.
  `Process.flag(:sensitive, true)` was tried as an alternative and does not help: the
  same crash, with the flag set, printed the same cleartext state. Now `Feed` wraps the
  pair in `DpExchange.Robinhood.Credentials`, a struct whose `Inspect` is derived with
  `except:` naming both fields, at the point credentials enter state. Nothing
  downstream changes: a struct is a map, so `Auth.headers/5`'s
  `%{api_key: k, private_key: p}` pattern still binds the real values inside the one
  function that has to sign with them. Re-verified against a real crash of the new
  shape: the log line now reads `credentials: #DpExchange.Robinhood.Credentials<...>`.

- **A crashed poller took the whole `Feed` down with it, silently discarding every
  symbol added after boot.** `PollingFeed.start_link/1` runs inside `Feed`'s own
  `init/1`, which links the poller to `Feed` the way `start_link` always does. `Feed`
  never called `Process.flag(:trap_exit, true)`, so an abnormal poller exit sent an
  untrappable `EXIT` signal along that link and crashed `Feed` too — restarted by
  `DpExchange.Robinhood.Supervisor` from the *static* `opts` it was given at
  tree-start, which never carry a consumer's later `update_symbols/2` calls or
  `subscribe_notices/1` registrations. Found by a 2026-09-07 supervision audit —
  proven by linking a real process into a running `Feed` and killing it with
  `Process.exit(pid, :kill)` (not `:normal`, which a non-trapping process ignores).

  `Feed` now traps exits and tracks its own `symbols` set (updated on every
  `update_symbols/2` call, since the static start `opts` alone are not enough to
  rebuild from), so a crashed poller restarts with the symbols this feed actually had
  rather than the ones it started with. `coverage/1` and `coverage_by_kind/1`
  correctly read empty immediately after the crash (the fresh poller starts with
  nothing delivered) rather than a stale `:internal_poll`, and a `:link_down`
  `Core.Notice` reports the crash — previously silent.

- **BREAKING: `supported_order_types` was `[]` while `place_order/3` was `:experimental`
  and `Rest.order_config/2` built four real order types** — market, limit, stop and
  stop-limit, from `AddOrderV2`'s own `market_order_config`, `limit_order_config`,
  `stop_loss_order_config` and `stop_limit_order_config`. `Capabilities.new/1` validates
  the *contents* of this list but never that a venue with an active `place_order/3`
  declared anything, so the empty list passed every check. Now
  `[:market, :limit, :stop, :stop_limit]`. Found by a cross-package audit;
  `dp_exchange_coinbase` defaulted the same field the same way for the same reason.

  Declaring `:stop` — the shared contract's atom, not this venue's own `:stop_loss` —
  surfaced two bugs in the code that had to accept it:

  - `Rest.order_config/2` only matched `:stop_loss`/`"stop_loss"`, so a caller passing the
    atom this package's own new declaration names was refused with
    `{:unsupported_order_type, :stop}` on a venue that serves the type. Now accepts `:stop`
    too, alongside the venue's own spelling — `dp_exchange_webull` already maps `:stop ->
    "STOP_LOSS"` the same way.
  - **The wire's `"type"` field and the `"#{type}_order_config"` key were built by
    interpolating the caller's raw atom**, not the venue's own spelling. A caller passing
    `:stop` therefore produced `"stop_order_config"`, a key the venue does not recognise —
    the order shipped with `type: "stop"` and no config object the venue could read at all,
    rather than being refused where the mistake could be seen. `wire_order_type/1` now maps
    `:stop -> "stop_loss"` explicitly for both the `type` field and the config key; every
    other type's wire spelling is unchanged.

- **`child_spec/1` did not declare `type: :supervisor`, so OTP defaulted it to `:worker`**
  — which also defaults `:shutdown` to `5_000`ms instead of `:infinity`. A consumer
  terminating this child gave the whole nested tree (feed, rate limiter, and everything
  under them) only five seconds to shut down gracefully before `:kill`, rather than
  letting it unwind on its own terms. Invisible to any single-package review — nothing
  crashes, no test fails — and found only by diffing `child_spec/1` across all five venue
  packages against each other; `dp_exchange_schwab` was the only one that already declared
  it.

- **`authenticated_streamable` was `[]` on a venue where every call is signed, including
  the quotes.** It reads as "no credential is needed to stream `:top_of_book`", which is
  false here — there is no anonymous surface at all. `Capabilities.new/1` enforces
  `authenticated_streamable` as a **subset** of `streamable` (which of the streamed kinds
  needs a credential), not a superset naming extra kinds a credential unlocks —
  `usage-rules/feeds.md` in `dp_exchange_core` currently states the direction the wrong
  way round, worth flagging upstream. Now `[:top_of_book]`, matching the one kind this
  venue streams. Found by a cross-package audit; `dp_exchange_webull` carried the
  identical `[]` for the identical reason.

### Removed

- **`SymbolFormat.mapping/0` — dead code, and a breaking change if anything outside this
  package called it.** Found by Core's new "16. internal wiring" conformance assertion
  (`DpExchange.Core.UnwiredCheck`), which reads the real `:xref` call graph restricted to
  this package's own `lib/` — a test calling a function does not count as wiring it, which
  is deliberate: it is the same shape as `rate_limit_blocking` never being set by its
  caller (issue #16), the defect the assertion exists to catch family-wide. `mapping/0`
  had no caller anywhere in `lib/`: `to_canonical_symbol/1` and `to_exchange_symbol/1`
  read the `@mapping` module attribute directly, `quotes/0` reads `@mapping.quotes`
  directly, and `Core.AdapterContract`'s conformance suite — despite this function's own
  doc claiming it exists "so the conformance suite can drive `CanonicalPair` with it" —
  never calls `.mapping()` on a venue's `SymbolFormat` module; it only ever calls
  `to_canonical_symbol/1` and `to_exchange_symbol/1`. Core's own reference pattern in
  `usage-rules/symbols.md` does not expose a `mapping/0` either. A vestigial `def`-exposed
  getter over a module attribute the real code never reads through it.

### Fixed

- **`FeedTest`'s notice-registry tests raced under load and failed intermittently on
  certain random seeds** — five `assert_receive` calls waited only 500ms for a
  `%Notice{kind: :coverage_change, severity: :warning}` that a 40ms-interval
  `Core.PollingFeed` normally delivers well inside that window, but the margin was too
  tight once this suite ran alongside its siblings under `async: true` with `max_cases:
  20`. Widened to 2,000ms — the assertions still return as soon as the message arrives, so
  this costs nothing on the passing path. Found by a cross-package audit running the full
  suite on multiple explicit seeds, which this family's CI does not do by default.

- **`Auth.headers/5` recomputed the signed payload with its own second copy of the
  concatenation `payload/5` already implements, rather than calling `payload/5`.** Also
  found by the "16. internal wiring" assertion: `payload/5` had no caller in `lib/`, only
  in `auth_test.exs`. The two copies agreed byte-for-byte — confirmed both against each
  other (the test at `auth_test.exs:52` already verified a signature produced by
  `headers/5` against a payload reconstructed by `payload/5`) and against the vendor's own
  documentation, `docs.robinhood.com/crypto/trading/` → Authentication → Headers and
  Signature, fetched live 2026-09-06: `message = f"{api_key}{current_timestamp}{path}
  {method}{body}"`, method uppercase, path including the query string, and the reference
  implementation Robinhood links from that page passes `body=""` for a bodyless request —
  the same empty-string-in-the-concatenation this package always did, not the literal
  omission the page's own prose says in passing (concatenating `""` and omitting it
  produce the identical string, so there was never a behavioural difference either way).
  So this was **not** the "two implementations disagree" defect the internal-wiring check
  exists to catch on a signing path — a signature-correctness bug — but the hand-kept
  duplicate was still a landmine waiting for the day the two drifted. `headers/5` now
  builds its signed string by calling `payload/5`, so there is exactly one implementation
  of the venue's signature ordering, and it is the one both the header path and the test
  suite exercise. No change to any wire behaviour — every existing signature-shape test
  passes unchanged.

- **`get_top_of_book/2` decoded v1's field names against the v2 endpoint this package
  actually calls, and every real poll silently returned `bid: nil, ask: nil` — the venue's
  entire quoted-price surface, and the whole data path behind `subscribe/2`.** Found during
  a bug audit, 2026-09-06, and confirmed against the vendor's own OpenAPI document at
  `docs.robinhood.com/crypto/trading/`, fetched live the same day: v1's `best_bid_ask`
  (schema `BidAskPrice`) publishes `bid_inclusive_of_sell_spread` and
  `ask_inclusive_of_buy_spread`; **v2's `best_bid_ask` (schema `V2BestBidAsk`, what
  `Rest.get_top_of_book/3` has always called) is a different, three-field schema:
  `symbol`, `bid`, `ask`.** `row["bid_inclusive_of_sell_spread"]` is never present on a v2
  row, so `decimal/1` correctly returned `nil` for it, every time — a `200 OK` with a
  well-formed, plausible-looking `TopOfBook` struct on every poll, which is exactly why
  nothing caught it: `Core.PollingFeed` counts any `{:ok, event}` as a delivery regardless
  of which fields are `nil`, so this never tripped the "delivering nothing" escalation, and
  every existing test matched the delivered struct only by `symbol`, never by `bid`/`ask`.

  Now reads `row["bid"]` / `row["ask"]`. `venue_time` stays `nil` for this endpoint — not a
  parse failure, but the honest answer to a `timestamp` field v2 never sends at all (v1's
  did). Every test fixture across `rest_test.exs`, `feed_test.exs` and `trading_test.exs`
  that built a v1-shaped `best_bid_ask` body against the v2 path is rewritten to the real
  v2 shape, and the delivery tests now assert actual `bid`/`ask` values rather than only the
  struct's `symbol` — the exact gap that let this ship. This is the same defect class as
  the wrong `time_in_force` field fixed earlier (a venue-schema mismatch invisible to tests
  because the fixtures encoded the same wrong assumption as the code), on the venue's most
  load-bearing endpoint.

  **Affected published versions: `0.1.11` through `0.1.17` inclusive.** The v1→v2 URL
  switch landed in `ea25ffb`, the commit immediately before the `0.1.11` release, and the
  decoder was never moved with it. A consumer that polled `top_of_book` on any of those
  versions received a `TopOfBook` whose `bid`, `ask` and `venue_time` were all `nil` — so
  **any stored history written from this venue over that range holds no prices and cannot
  be repaired from the package side.** It is stated here rather than only in the fix
  description because a consumer streaming this into a time-series store has bad rows
  already written, and nothing in an upgrade tells them which ones.


- **`cancel_order/3` discarded the venue's real response and always returned a fabricated
  `status: :open`, regardless of what the venue actually said.** Confirmed against the
  vendor's own OpenAPI document, 2026-09-06: v1's cancel endpoint
  (`POST /api/v1/.../cancel/`) really does answer with a bare `text/plain` acknowledgement
  and no order data, which is what the discarded-body behaviour was originally correct for.
  **v2's cancel endpoint — the one this module calls — is different: `200` returns
  `application/json` against `$ref: V2CryptoOrder`, the identical schema `get_order/3`
  reads.** A cancel that lands returns `state: "canceled"`; one that loses a race to a fill
  returns the fill's own state. Hardcoding `:open` was silently wrong for either outcome
  the moment the v1→v2 migration happened. `cancel_order/3` now decodes the response with
  `to_order/1`, exactly like `get_order/3` and `place_order/3`. `Fake.cancel_order/3` moves
  from `:open` to `:cancelled` to match — the real venue's ordinary case for a call that
  succeeds — and both facade tests and the fake-injection suite are updated.

- **`Fake.quantization/1` could not be called the way the real facade's
  `quantization/2` is, and never checked credentials at all.** Every other real,
  successful-path function on this venue's `Fake` (`get_top_of_book/2`, `get_symbols/1`,
  `list_instruments/1`) gates on `authenticated/1`, matching the real venue signing every
  call. `quantization` did not: it took no `opts` parameter at all, so a caller reaching
  it the way production code reaches `DpExchange.Robinhood.quantization/2` — with
  `credentials:` in `opts` — got `UndefinedFunctionError`, and a caller invoking arity 1
  got an unconditional success no credentials could have produced against the real venue.
  Both are the "differently capable" defect `usage-rules/testing.md` warns about. Now
  `quantization/2` (opts defaulting to `[]`, so the old arity-1 call still works),
  authenticated the same way its siblings are.

- **`Fake` was differently capable than the real facade in six more ways, found by a
  documentation-accuracy sweep on 2026-09-06 that deliberately touched no code first.**
  All six are the same class as `quantization/1` above — a fake more, or differently,
  capable than the venue it stands in for — and **each is a breaking change to a
  consumer's existing test if that test pinned the old, wrong behaviour.**

  - **`Fake.get_balances/2`, `get_accounts/2`, `place_order/3`, `cancel_order/3`,
    `get_order/3` and `get_orders/2` never checked their `credentials` argument at all** —
    `%{}`, `nil`, or any other value answered success as long as the account number
    (where one is required) was present. This venue signs every request with no anonymous
    endpoint, including these; only `get_top_of_book/2`, `get_symbols/1`,
    `list_instruments/1` and `quantization/2` gated on it. All six now call the same
    `authenticated/1`/`authenticated_credentials/1` check the market-data functions
    already did, refusing with `{:error, {:missing_credentials, :robinhood}}` first
    (after the account-number check, for the four calls that need one — matching
    `Rest`'s own order of checks). **A consumer's existing test calling any of these six
    with placeholder or absent credentials, expecting success, now gets a refusal.**

  - **The credential refusal itself was the wrong shape: `{:refused, :missing_credentials}`
    where the real facade answers `{:error, {:missing_credentials, :robinhood}}`.** Both
    were tested side by side in `robinhood_test.exs` and never compared: the real venue's
    test asserted the `:error` tuple three lines above the fake's test asserting the
    `:refused` one, for the identical call. The two tags mean different things family-wide
    — `DpExchange.Core.Venue`'s own moduledoc: `:refused` is the venue's permanent word
    about a request it received; `:error` may be transient and is worth retrying. A missing
    local credential never reaches the venue, so it was never the venue's word about
    anything, and `Auth.headers/5` has always returned the `:error` shape. Now
    `authenticated/1` and the new `authenticated_credentials/1` both do too, on every
    function that checks either. **Breaking for a consumer's test matching the old
    `{:refused, :missing_credentials}` tuple literally.**

  - **`Fake.get_top_of_book/2` stamped `venue_time` with a fixed, non-`nil` datetime.**
    The real `Rest.get_top_of_book/3` always decodes `venue_time: nil` on this venue — v2's
    `best_bid_ask` schema has no `timestamp` property at all — so the fake was handing a
    consumer's freshness check a value the real venue can never produce: the exact
    "plausible value, wrong meaning" substitution this family exists to refuse. Now `nil`,
    always, matching the real path. `observed_at` keeps its fixed value; that one is a
    deliberate, documented testing convenience (freshness against a fixed clock is
    testable at all only because it does not move), not a claim about what the venue
    sends.

  - **`Fake.subscribe/2` honoured `opts[:to]`, which the real
    `c:DpExchange.Core.Venue.subscribe/2` has no notion of at all** — the real facade's
    `subscribe/2` delivers to whichever process
    this venue's feed was supervised with, fixed at boot, and silently ignores any `:to`
    passed to it (only `subscribe_notices/2`'s own registry reads that key). A consumer's
    tier-1 test redirecting delivery with `to:` passed tests behaviour the real venue does
    not have. Now always delivers to the calling process, `opts[:to]` or not.

  - **`Fake.subscribe_notices/1` answered a bare `:ok` unconditionally and was never wired
    through `FakeInjection`, unlike every other real-success-path function** — this
    module's own moduledoc already claimed the wiring ("every function below that has a
    real success path... checks `FakeInjection.next_outcome/1` or `/2` first"), so the
    code contradicted its own documentation. The real facade answers
    `{:error, :feed_not_started}` when its feed is not running, and nothing on the fake
    side could ever produce that shape for a consumer to test against. Routed through
    `with_injection/2` now — `FakeInjection.fail_always(:robinhood, {:error,
    :feed_not_started})` or `queue_failures/2,3` reaches it exactly as they reach
    `get_symbols/1` or `market_status/1`; with nothing queued it still answers `:ok`.

  Fixed in `lib/dp_exchange/robinhood/fake.ex`. Regression tests pinning all six live in
  `robinhood_test.exs` and `fake_injection_test.exs`.

### Documentation

- **A documentation-only sweep for claims the code contradicts, 2026-09-06.** Nine false
  claims, none of which changes behaviour:
  - **`README.md`'s usage example did not work.** `get_top_of_book("BTCUSD", …)` and
    `subscribe(["BTCUSD"])` used a separatorless symbol, and canonical form here is
    `BASE-QUOTE`. `CanonicalPair.to_exchange/2` on a `sep: "-"` mapping splits the
    canonical string on `-` and finds none, so `"BTCUSD"` goes to the venue as `"BTCUSD-"`
    — a malformed symbol, not a working call. Both examples now read `"BTC-USD"`.
  - **`README.md` claimed the conformance suite passes "against Robinhood's live public
    endpoints."** There are none: every endpoint on this venue requires a credential, which
    is exactly why `docs/reference/robinhood/endpoint-inventory.md` records that *"no
    tier-2 test exists here."* `CLAUDE.md`, `test_helper.exs` and `.env.sample` carried
    the same claim in three more shapes, including a `mix test --include tier2` command
    for a tag nothing in `test/` sets.
  - **`.env.sample` described a different venue.** It named Gemini's OAuth flow, a "WEBULL
    App Key", and a `DpExchange.Gemini.get_price(…, environment: :sandbox)` example — and
    said "every endpoint that would need [a credential] is declared `:unsupported`", which
    is the opposite of this venue, where every implemented endpoint needs one.
  - **`usage-rules.md` listed `volume` on a quote as "always `nil`."** This package never
    returns a `Core.Types.Quote` at all since `get_price/2` became `:unsupported`. The row
    now names what a caller does receive: `bid_size` / `ask_size` on a `TopOfBook`, always
    `nil` because `best_bid_ask` publishes no size.
  - **`usage-rules.md` said `venue_time` is `nil` "when the venue's row has no readable
    timestamp,"** implying it is sometimes present. `V2BestBidAsk` has no `timestamp`
    property at all, so it is `nil` on every book.
  - **`Feed`'s moduledoc said a "direct one-off `get_price/2` call" goes through `Rest`'s
    forwarded-options allowlist.** `get_price/2` returns `{:error, :not_supported}` at the
    facade and never reaches `Rest`; the one-off call that does is `get_top_of_book/2`.
  - **`Rest.get_estimated_price/5`'s doc called it "a different number from `get_price/3`'s
    last trade."** There is no last trade on this venue and no `get_price/3` anywhere —
    `usage-rules.md` already said "two prices … there is no third," and the facade's own
    `get_estimated_price/5` doc still said "third." Both corrected.
  - **Wrong arities on six real cross-references.** `Rest`'s docs called its own
    `get_symbols/2` and `list_instruments/2` "`/1`" (the facade's arity), the facade called
    its own `get_symbols/1` "`/2`" (`Rest`'s arity), and the `{:get_price, 2}` entry in
    `@venue_does_not_serve` said `get_price/3`.
  - **`config/*.exs` and `docs/design/README.md` named the wrong package** —
    `:dp_exchange_gemini` and `dp_exchange_core` — and `runtime.exs` called this a
    "contract library" that "opens no sockets" whose seam `:rate_limit_module` it reads;
    that key is read by `dp_exchange_core` under its own app name.
  - **`README.md` told a consumer to pin `~> 0.1.0`** while `mix.exs` is at `0.2.1` — a
    constraint that cannot resolve the current package. Now `~> 0.2.0`, in both the
    banner and the `deps` snippet.
  - **`.gitignore` ignored `dp_exchange_coinbase-*.tar`** in this repo, so a built Hex
    tarball here was not ignored at all. Corrected to this package's own name.

- **`time_in_force` is not symmetric between placing an order and reading it back, and
  several comments and tests claimed it was.** Confirmed against the vendor's own OpenAPI
  document, 2026-09-06: on the REQUEST side, `AddOrderV2.limit_order_config`,
  `.stop_loss_order_config` and `.stop_limit_order_config` all carry `time_in_force` — true,
  and what the request-building code already did correctly. On the RESPONSE side,
  `OrderResponse.limit_order_config` has no `time_in_force` property at all; only
  `.stop_loss_order_config` and `.stop_limit_order_config` echo it back. A limit order's
  `time_in_force` is therefore knowable from the `place_order/3` call that set it, never
  from re-reading the order — `get_order/3` and `cancel_order/3` honestly decode `nil` for
  it, always, on a limit order, which the decoder already did correctly; only the comments
  and `usage-rules.md` claimed otherwise, and several tests exercised the decoder against a
  `limit_order_config` fixture carrying `time_in_force`, a shape the real venue never
  sends. Rewritten to use `stop_loss_order_config` / `stop_limit_order_config` for the
  decode-side tests, with a new test asserting the limit-order `nil` case directly.

- **This feed's own moduledoc said the venue "publishes no bulk-stats endpoint." That
  is not what the vendor's document says.** `best_bid_ask`'s `symbol` query parameter is
  documented as repeatable (`?symbol=BTC-USD&symbol=ETH-USD`, one signed request, one
  `results` array covering every symbol asked for) — confirmed 2026-09-06.
  `Core.PollingFeed`'s own moduledoc names Robinhood as the intended user of its
  `:fetch_all` mode for exactly this shape. Not adopted here yet: `:fetch_all` has no
  refusal path in `Core.PollingFeed` today, and the vendor's document does not say what a
  batched call does when one symbol in it is invalid — guessing wrong would turn one bad
  symbol into a feed-wide crash loop, worse than today's per-symbol design. Recorded as
  `docs/design/ideas/bulk-best-bid-ask-fetch.md` rather than implemented as a guess.

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

- **`list_instruments/1` is implemented — it was one query away, not a new endpoint.**
  `get_symbols/1` already walked every page of `trading_pairs` and discarded everything but
  `symbol`; `quantization/3` already read the richer fields off the same rows. This reuses
  the same walk and maps `asset_code`/`quote_code` straight to `Core.Instrument`'s `base`
  and `quote` — never parsed back out of the canonical symbol string, matching how
  `dp_exchange_coinbase` builds the same struct. Every row is `:spot`, the only instrument
  type this venue's trading-pairs endpoint lists. Moved out of `@not_ported`, whose comment
  had called this "reads only the symbols" — true of `get_symbols/1`, never a reason the
  richer fields couldn't be read too. `capabilities/0` now declares it `:experimental`
  instead of `:unsupported`.

### Fixed

- **An empty `trading_pairs`/`best_bid_ask` page was read as the venue stating a symbol
  does not exist, and it is not that — DpCryptoManagement's issue #25, measured on the
  reporting consumer's own production node.** `first_result/1` turned any 200 response
  whose `results` array happened to be empty into `{:refused, :not_listed}`, and
  `Core.PollingFeed`'s own contract reports a refusal exactly once and never retries it —
  so a transient empty page, indistinguishable at the HTTP layer from "genuinely not
  listed," became a permanent catalog verdict. Measured: 83 refusals held on one
  deployment, 56 of them `{:refused, :not_listed}` for pairs that answer normally on the
  very next call — `BTC-USD`, `ETH-USD`, `LTC-USD`, `LINK-USD` and `DOGE-USD` among them.
  Clearing only those 56 took that consumer's collection scope from 5 pairs to 63, 62 of
  them fresh within 60 seconds. **92% of this venue's collection was suppressed by an
  inference the venue never made.**

  `first_result/1` now returns `{:error, :empty_result}` for an empty page — retryable,
  the same shape a 500 already produces — while `{:refused, :not_listed}` stays exactly
  where the venue actually says so: a 400/401/403/404 carrying a body, handled by
  `refusal/2` on the HTTP status rather than on the shape of a 200. The other 27 of the 83
  held refusals were genuine venue statements this way (`{:venue_error, 400, "Invalid
  symbol: ALGO-USD"}`) and are unaffected. `get_top_of_book/3` and `quantization/3`, the
  two callers, both change; `get_symbols/1`'s pagination walk never went through
  `first_result/1` and was never affected. New tests in `rest_test.exs`,
  `defensive_branches_test.exs` and `robinhood_test.exs` fail against the prior code and
  pass against this one, including one that runs `Feed` end to end against a
  perpetually-empty page and asserts no `{:refused, ...}` message ever reaches the
  subscriber.

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
