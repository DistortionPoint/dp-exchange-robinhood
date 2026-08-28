# Extraction pin — what was read, and in what state

**Host**: `dp_crypto_management`, branch `master`, `553fa787`. Read 2026-08-28.

The working tree was **dirty** — the fourth venue running, and the fourth time. Per-file
SHA-256 of what was actually read:

| SHA-256 (first 16) | Lines | File | Tree state |
|---|---|---|---|
| `3a0f3bfe47336701` | 88 | `robinhood/feed.ex` | clean |
| `01048e0f61fd3890` | 857 | `robinhood/provider.ex` | **M — uncommitted** |
| `7cd11a6163f03301` | 153 | `robinhood/signing.ex` | clean |
| `f56e7651e466b995` | 32 | `robinhood/symbol_format.ex` | clean |

1,130 lines — the smallest adapter in the family, against Webull's 4,506.

## What made it small is what makes it interesting

This venue has **no streaming API**, no candle endpoint, no order book and no volume. Most
of what the other adapters carry has nothing to attach to here.

That leaves the one thing this extraction is really about: whether §6.0's claim survives a
venue that cannot satisfy it the usual way. **Both endpoints always exist** — every venue
answers `subscribe/2` and every venue answers `get_price/2` — and a consumer never branches
on transport. Robinhood is where that is cheapest to abandon and most valuable to keep.

The prior adapter's own `feed.ex` moduledoc records what it cost when the fact travelled
upward instead: the collection layer kept a poll set and decided which venues were exempt
from it, and an operations page described these pairs **in terms of a socket the venue does
not have and has never claimed** — sending readers to hunt a streaming fault that cannot
exist.
