# Tier 2 is the family's "live, unauthenticated endpoint" tier, and it is EMPTY here:
# Robinhood Crypto has no public surface, so nothing in `test/` carries the tag. The
# exclusion stands so the convention holds family-wide and so a tagged test can never
# reach the venue unasked — one that sees a package polling it on a timer will rate-limit
# or block.
ExUnit.start(exclude: [:tier2])
