# Spec-example fixtures

Every file here is driven through the real public function in
`test/dp_exchange/robinhood/spec_examples_test.exs` — never hand-tuned to agree with
`Rest`'s own decoding, only with the vendor's committed OpenAPI document,
`docs/reference/robinhood/openapi/crypto-trading.openapi.json`. JSON carries no comments,
which is why the citation for each file lives here instead of inline.

**None of the schemas below declare a `required` array**, and the document carries no
full-body `example`/`examples` for any 200/201 response used here (only scalar,
parameter-level `example`s — a query parameter's sample value, a pagination URI). So every
fixture is "an instance built strictly from the schema's properties" per this suite's own
rule, using every documented property since none is marked required (except the order
configs' `quote_amount`, which this package neither sends nor decodes), with a value of
the schema's own declared `type`/`format` — a JSON number where the schema says `number`,
a JSON string where it says `string`. That distinction is deliberate: the venue's own
worked Python samples (embedded in the spec's `info.description`) send prices and
quantities as **strings**, and this package's fixtures for the *request* side follow that
worked example rather than the formal `type: number` declaration — see
`spec_examples_test.exs`, "the vendor's own schema and its own worked example disagree",
for why both are handled rather than one silently overruling the other.

## Files

### `api_v2_crypto_marketdata_best_bid_ask.json`
`GET /api/v2/crypto/marketdata/best_bid_ask/` → `200`, `#/components/schemas/V2BestBidAskResponse`
(`#/components/schemas/V2BestBidAsk` per row). Drives `Rest.get_top_of_book/3`.
`bid`/`ask` are `type: number, format: double` on this schema — sent as JSON numbers here,
not strings, which the existing `rest_test.exs` fixtures never exercised.

### `api_v2_crypto_trading_trading_pairs.json`
`GET /api/v2/crypto/trading/trading_pairs/` → `200`,
`#/components/schemas/V2TradingPairsResponse` (`#/components/schemas/V2TradingPair` per
row). Drives `Rest.get_symbols/2`, `Rest.list_instruments/2` and `Rest.quantization/3` —
all three read this one endpoint's rows for different fields, so one fixture backs three
tests.

### `api_v2_crypto_trading_accounts.json`
`GET /api/v2/crypto/trading/accounts/` → `200`, `#/components/schemas/V2AccountsResponse`
(`#/components/schemas/V2Account`, with `fee_tier_status` →
`#/components/schemas/FeeTierStatus`). Drives `Rest.get_accounts/2`, which returns the
venue's own row maps unmodified — no `Core.Types` struct exists for an account.

### `api_v2_crypto_trading_holdings.json`
`GET /api/v2/crypto/trading/holdings/` → `200`, `#/components/schemas/V2HoldingsResponse`
(`#/components/schemas/V2Holding` per row). Drives `Rest.get_balances/2`.

### `api_v2_crypto_marketdata_estimated_price.json`
`GET /api/v2/crypto/trading/estimated_price/` → `200`,
`#/components/schemas/V2EstimatedPriceResponse` (`#/components/schemas/V2EstimatedPrice`
per row). Drives `Rest.get_estimated_price/5`, which returns the venue's own body
unmodified. **Named for the spec's own `operationId`,
`api_v2_crypto_marketdata_estimated_price`, not the path** — the vendor's OpenAPI document
still names this operation `marketdata` although v2 moved the path itself to
`/trading/estimated_price/` (see `Rest`'s own moduledoc, "This endpoint moved from
`marketdata` to `trading` between v1 and v2"). The operationId is a leftover of that
migration; the path is what this package actually calls and is what the test asserts.

### `api_v2_crypto_trading_orders_post.json`
`POST /api/v2/crypto/trading/orders/` → `201`, `#/components/schemas/V2CryptoOrder`
(`allOf` `#/components/schemas/OrderResponse` plus `fee_charged`/`estimated_fee_remaining`).
Drives `Rest.place_order/3`'s response side — a filled market order. The request side
(`#/components/schemas/AddOrderV2`, `requestBody`) is asserted directly against the spec's
`required` array in the test rather than fixture-driven, since it is what this package
*sends*, not receives.

### `api_v2_crypto_trading_cancel_order.json`
`POST /api/v2/crypto/trading/orders/{id}/cancel/` → `200`,
`#/components/schemas/V2CryptoOrder`. Drives `Rest.cancel_order/3` — a canceled limit
order, `average_price: null` (the schema declares this field `nullable: true`).

### `api_v2_crypto_trading_orders_get_one.json`
**Not a documented path.** `GET /api/v2/crypto/trading/orders/{order_id}/` — confirmed
called by this package (`Rest.get_order/3`) and listed in
`docs/reference/robinhood/endpoint-inventory.md` and in the spec's own `info.description`
(the "Making your first API call" Python sample's `get_order`/`get_orders` methods for
both v1 and v2) — **is absent from this document's `paths` object entirely.** Only the
cancel path (`.../orders/{id}/cancel/`) is formally documented for a single order by id.
This fixture is therefore built from `#/components/schemas/V2CryptoOrder` — the same
schema `Rest.get_order/3` decodes with (`to_order/1`, shared verbatim with
`place_order/3` and `cancel_order/3`) — rather than from a response object the spec
actually names for this path, and the test that drives it says so rather than treating the
gap as a full spec example. A partially-filled stop-limit order, to exercise
`limit_price` *and* `stop_price` on the same row.

### `api_v2_crypto_trading_orders_get.json`
`GET /api/v2/crypto/trading/orders/` → `200`, `#/components/schemas/V2OrdersResponse`
(`#/components/schemas/V2CryptoOrder` per row). Drives `Rest.get_orders/2`. Two rows,
deliberately: an open limit order (whose `limit_order_config` carries no `time_in_force`
on the response side, unlike the request side — `OrderResponse.limit_order_config` has
exactly `quote_amount`, `asset_quantity`, `limit_price`) and a filled stop-loss order
(whose `stop_loss_order_config` *does* echo `time_in_force`) — the asymmetry
`Rest`'s own moduledoc already documents, now backed by a schema-derived fixture instead
of only a hand-built one.
