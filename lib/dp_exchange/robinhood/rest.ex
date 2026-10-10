defmodule DpExchange.Robinhood.Rest do
  @moduledoc """
  Robinhood Crypto's REST surface — internal.

  ## Every call is signed, including the quotes

  There is no anonymous endpoint here. `best_bid_ask` needs the same Ed25519 signature as
  an order, which is why this venue declares `credential_benefit: :required` and why
  `get_price/2` takes credentials.

  ## There is no `get_price/3` here, and that is deliberate

  `best_bid_ask` returns a bid and an ask — the prices a taker would actually get — and
  never a trade price. This module used to fill a quote's `price` from the ask when the
  venue sent none. `Core.Types.Quote`'s own moduledoc now names that incident directly as
  the reason `Quote` carries no bid or ask at all: a package filling `price` from `ask` "is
  exactly what one of them did." Removing the fallback was correct and left nothing here for
  `get_price/3` to honestly return — DpCryptoManagement's issue #21. The facade declares
  `get_price/2` `:unsupported` accordingly. `bid` and `ask` are both real and both carried,
  through `get_top_of_book/3`.

  ## v2's field names are not v1's, and this cost a working quote

  v1's `best_bid_ask` (`BidAskPrice`) publishes `bid_inclusive_of_sell_spread` and
  `ask_inclusive_of_buy_spread`, plus a computed `price` (their midpoint — still not a trade
  price) and a `timestamp`. **v2's `best_bid_ask` (`V2BestBidAsk`) is a different schema**:
  three fields only — `symbol`, `bid`, `ask`. No spread-inclusive names, no `price`, no
  `timestamp` at all. This module calls v2 but, for one release, decoded v1's field names
  against it — every real poll got `200 OK` with a well-formed body and silently decoded
  `bid: nil, ask: nil, venue_time: nil` every time, because `row["bid_inclusive_of_sell_spread"]`
  is never present on a v2 row. Confirmed against the vendor's own OpenAPI document,
  `docs.robinhood.com/crypto/trading/`, 2026-09-06: `V2BestBidAskResponse.results` is an
  array of `V2BestBidAsk`, and `V2BestBidAsk`'s only properties are `symbol`, `bid`, `ask`.
  Reads `row["bid"]` / `row["ask"]` now. `venue_time` stays `nil` for this endpoint — not a
  parse failure, but the honest answer to a field v2 never sends.

  ## No candles, no order book, no volume

  Robinhood Crypto publishes no historical-candle endpoint, no order book, and no volume on
  the quote. Those are `:unsupported` — and that is the venue's shape, not a gap in this
  package. Declaring them so lets a consumer route that work elsewhere instead of
  discovering an empty series.
  """

  alias DpExchange.Core.{Config, HttpClient, Instrument}
  alias DpExchange.Core.Types.{Balance, Order, TopOfBook}
  alias DpExchange.Robinhood.{Auth, SymbolFormat}

  @base_url "https://trading.robinhood.com"
  @trading_pairs_path "/api/v2/crypto/trading/trading_pairs/"

  # The vendor's own OpenAPI schema carries `time_in_force` as an enum of
  # `["gtc", "gfd", "gfw", "gfm"]` on `AddOrderV2.limit_order_config`,
  # `.stop_loss_order_config` and `.stop_limit_order_config` — a REAL field on every
  # non-market REQUEST config, not one this venue lacks. `market_order_config` has no such
  # field in the schema, so a market order never carries one either way.
  #
  # **The RESPONSE side is not symmetric with the request side, and that is the venue's own
  # asymmetry, not a gap here.** `OrderResponse.limit_order_config` — confirmed against the
  # vendor's OpenAPI document, 2026-09-06 — carries only `quote_amount`, `asset_quantity`
  # and `limit_price`; it has no `time_in_force` property at all. Only
  # `stop_loss_order_config` and `stop_limit_order_config` echo it back on a read. So a
  # limit order's `time_in_force` is knowable from the `place_order/3` call that set it, not
  # from re-reading the order afterwards — `get_order/3` and `cancel_order/3` on a LIMIT
  # order honestly decode `nil` here, always, because the venue never sends the field for
  # that type. `configured_time_in_force/1` below still scans every `*_order_config`
  # generically rather than special-casing this: it costs nothing when the key is absent,
  # and it means this stays correct without a rewrite if the vendor ever adds the field to
  # `limit_order_config` too.
  #
  # All four of the venue's values are representable. `gfw` and `gfm` decoded to `nil` for
  # one release — not invented locally and not mapped to a nearest-match value — because
  # Core's `time_in_force` vocabulary had no atom for "good for week" or "good for month".
  # Core 0.1.45 added `:gfw`/`:gfm` (`DpExchange.Core.Capabilities`), so the gap is closed
  # and every value this venue documents now round-trips. `gfd` maps to Core's `:day`,
  # which is the same meaning under the family's own name rather than a second spelling
  # of it.
  @tif_names %{gtc: "gtc", day: "gfd", gfw: "gfw", gfm: "gfm"}
  @tif_atoms Map.new(@tif_names, fn {atom, name} -> {name, atom} end)

  @doc "Base URL, overridable for tests."
  @spec base_url(keyword()) :: String.t()
  def base_url(opts), do: Config.opt(opts, :base_url, @base_url)

  @doc """
  Best bid and ask for `symbol` — the top of the book, not a traded price.

  Reads v2's `best_bid_ask`, the only quote-adjacent endpoint this venue serves. **v2's
  response (`V2BestBidAsk`) is three fields: `symbol`, `bid`, `ask`** — not v1's
  spread-inclusive names, and no `timestamp`. Carried as sent rather than adjusted back to
  a raw book.

  This is the whole of what `best_bid_ask` gives: no trade price. See the moduledoc on why
  there is no `get_price/3` reading this same payload, and on the v1/v2 field-name defect
  this function used to carry.

  One symbol, one signed request. See `get_top_of_book_bulk/3` for the repeatable-`symbol`
  form this endpoint also serves, which `Feed` uses as its normal path and falls back to
  this function per symbol only when the bulk call is itself refused.
  """
  @spec get_top_of_book(String.t(), map(), keyword()) ::
          {:ok, TopOfBook.t()} | {:error, term()} | {:refused, term()}
  def get_top_of_book(symbol, credentials, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    path = "/api/v2/crypto/marketdata/best_bid_ask/?symbol=" <> URI.encode(native)

    with {:ok, body} <- get(path, credentials, opts),
         {:ok, row} <- result_for(body, native) do
      {:ok, to_top_of_book(SymbolFormat.to_canonical_symbol(native), row)}
    end
  end

  @doc """
  Best bid and ask for every symbol in `symbols` — **one signed request**, not one per
  symbol.

  `best_bid_ask`'s `symbol` query parameter is documented as repeatable —
  `?symbol=BTC-USD&symbol=ETH-USD` — and `V2BestBidAskResponse.results` is a plain array of
  `V2BestBidAsk` rows, one per symbol the venue answered for. Confirmed against the
  vendor's own OpenAPI document, `docs.robinhood.com/crypto/trading/`, 2026-09-06. See
  `docs/design/ideas/bulk-best-bid-ask-fetch.md` for why this package did not use it
  sooner, and `Feed` for how a whole-batch refusal is handled without guessing at venue
  semantics the vendor's document never states.

  **A `results` array shorter than `symbols` is not this function's problem to solve.**
  Every row present is mapped; every symbol absent from `results` simply is not in the
  returned list — the caller (`Core.PollingFeed`, via `Feed`) already treats "asked for but
  not in the response" as uncovered-and-retried, never as a refusal, and this function does
  nothing that would turn silence into a statement (see `first_result/1` below for the same
  principle on the single-symbol path, and DpCryptoManagement issue #25 for what mistaking
  the two costs).

  An empty `symbols` list returns `{:ok, []}` without a network call: the venue's own
  document does not say what a `best_bid_ask` request carrying no `symbol` parameter at all
  does, and there is nothing to ask for.
  """
  @spec get_top_of_book_bulk([String.t()], map(), keyword()) ::
          {:ok, [TopOfBook.t()]} | {:error, term()} | {:refused, term()}
  def get_top_of_book_bulk([], _credentials, _opts), do: {:ok, []}

  def get_top_of_book_bulk(symbols, credentials, opts) do
    query = Enum.map(symbols, &{"symbol", SymbolFormat.to_exchange_symbol(&1)})
    path = "/api/v2/crypto/marketdata/best_bid_ask/" <> query_string(query)

    with {:ok, body} <- get(path, credentials, opts),
         {:ok, rows} <- bulk_rows(body) do
      {:ok, rows |> Enum.map(&row_to_top_of_book/1) |> Enum.reject(&is_nil/1)}
    end
  end

  defp bulk_rows(%{"results" => rows}) when is_list(rows), do: {:ok, rows}
  defp bulk_rows(_other), do: {:error, :unexpected_response_shape}

  # Every row this venue actually returns from `V2BestBidAskResponse` carries its own
  # `symbol` — read from the ROW, not from the request order, because a `results` array
  # shorter than (or reordered against) what was asked for is exactly the shape this
  # function has to tolerate. A row missing `symbol` entirely is dropped rather than
  # published under a fabricated one: `Core.Types.TopOfBook.symbol` is how every consumer
  # keys coverage, and a nil key there is worse than one fewer row this cycle.
  defp row_to_top_of_book(%{"symbol" => symbol} = row) when is_binary(symbol),
    do: to_top_of_book(SymbolFormat.to_canonical_symbol(symbol), row)

  defp row_to_top_of_book(_row), do: nil

  defp to_top_of_book(symbol, row) do
    %TopOfBook{
      symbol: symbol,
      bid: decimal(row["bid"]),
      ask: decimal(row["ask"]),
      bid_size: nil,
      ask_size: nil,
      venue_time: top_of_book_time(row),
      observed_at: DateTime.utc_now(),
      provider: :robinhood
    }
  end

  # `V2BestBidAsk` — the schema the venue's own OpenAPI document names for this response —
  # has no `timestamp` property at all, so `row["timestamp"]` is absent on every real call
  # today and this always returns `nil`. Left as a lookup rather than hardcoded `nil`
  # outright: harmless if the vendor ever adds the field, and it shares `venue_time/1` with
  # nothing else that would need a second copy.
  defp top_of_book_time(row) do
    case venue_time(row) do
      {:ok, at} -> at
      _no_venue_time -> nil
    end
  end

  @doc """
  Every tradable pair, canonical.

  Calls **`/api/v2/crypto/trading/trading_pairs/`** (D5). The endpoint paginates, so this
  walks it. v2's response shape is identical for this purpose — `results` rows carrying
  `symbol`, and a `next` cursor — which is why this half of the v2 migration was safe to
  make and the quote half was not; see this module's moduledoc.

  Measured by the prior adapter on 2026-08-05 against v1: 86 symbols, every one quoted in
  USD — **as seen by that credential**. Listings can differ by account tier, so a consumer
  holding a different key may see a different catalogue, and the figure has not been
  retaken against v2.
  """
  @spec get_symbols(map(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()} | {:refused, term()}
  def get_symbols(credentials, opts) do
    with {:ok, rows} <- walk_trading_pairs(credentials, opts) do
      {:ok,
       rows
       |> Enum.flat_map(&row_symbol/1)
       |> Enum.map(&SymbolFormat.to_canonical_symbol/1)
       |> Enum.sort()}
    end
  end

  @doc """
  Every tradable pair as a `Core.Instrument` — base, quote, instrument type and status —
  from the same paginated `trading_pairs` endpoint `get_symbols/2` already walks.

  `get_symbols/2` extracts only `symbol` and discards the rest; this reads `asset_code`
  and `quote_code` off the same rows for base and quote, never parsed back out of the
  canonical symbol string. Every row is `:spot` — Robinhood Crypto's trading-pairs
  endpoint lists no other instrument type.
  """
  @spec list_instruments(map(), keyword()) ::
          {:ok, [Instrument.t()]} | {:error, term()} | {:refused, term()}
  def list_instruments(credentials, opts) do
    with {:ok, rows} <- walk_trading_pairs(credentials, opts) do
      {:ok,
       rows
       |> Enum.filter(&has_symbol?/1)
       |> Enum.map(&to_instrument/1)}
    end
  end

  # A row's symbol, as a one-element list, or `[]` for a row that is not an object or whose
  # `symbol` is not a string. Both used to raise here, inside the caller's process
  # (`Access` on a non-map, `SymbolFormat` on a non-string). Found by mutating real
  # response bodies, 2026-09-27. An absent symbol was already skipped, and so are these.
  #
  # **`is_api_tradable: false` excludes the row entirely, and only here.** `V2TradingPair`'s
  # own field — confirmed against the vendor's OpenAPI document, `docs.robinhood.com`,
  # 2026-09-29 — "indicates whether the trading pair is supported on API trading v2
  # endpoints". `get_symbols/2` used to publish every listed pair regardless: a symbol the
  # venue itself refuses on `best_bid_ask`, `estimated_price` and `orders` was handed to a
  # poller as though it were quotable, which is a 400 every cycle rather than a catalogue
  # gap this package can state up front. `list_instruments/2` does NOT exclude the row —
  # see `has_symbol?/1` and `instrument_status/1` below — a consumer building a catalogue
  # may still want to know the pair exists; only its status is marked `:unknown` rather than
  # `:tradable`. The field being ABSENT (not `false`) is unmeasured, not a negative: this
  # venue did not say, and the row is kept exactly as it was before this field existed to
  # this package.
  defp row_symbol(%{"symbol" => symbol, "is_api_tradable" => false}) when is_binary(symbol),
    do: []

  defp row_symbol(%{"symbol" => symbol}) when is_binary(symbol), do: [symbol]
  defp row_symbol(_row), do: []

  # `list_instruments/2`'s own row filter — deliberately NOT `row_symbol/1`, which also
  # excludes an `is_api_tradable: false` row for `get_symbols/2`'s purpose. This callback
  # keeps that row (see `row_symbol/1`'s comment) and only needs to know a usable symbol is
  # present at all.
  defp has_symbol?(%{"symbol" => symbol}) when is_binary(symbol), do: true
  defp has_symbol?(_row), do: false

  defp to_instrument(row) do
    Instrument.new(
      symbol: SymbolFormat.to_canonical_symbol(row["symbol"]),
      base: row["asset_code"],
      quote: row["quote_code"],
      instrument: :spot,
      status: instrument_status(row)
    )
  end

  # `is_api_tradable` is what actually gates whether this package's own v2 endpoints
  # (`best_bid_ask`, `estimated_price`, `orders`) will accept the symbol at all —
  # `status` alone does not say that; a pair can read `"tradable"` (v1-tradable) and still
  # answer 400 on every quote or order call this package makes for it, because it is not
  # API-tradable under v2. `Core.Instrument.status/0` offers exactly `:tradable`,
  # `:delisted` or `:unknown` — no "listed but API-refused" state — so `:unknown` is the
  # closest honest reading rather than a fourth value invented here (Core is not changed
  # for this; checked `dp_exchange_core`'s `Instrument` module directly, 2026-09-29).
  # Absent entirely (not `false`) is unmeasured: `status` alone decides, same as before this
  # field existed to this package.
  defp instrument_status(%{"is_api_tradable" => false}), do: :unknown
  defp instrument_status(row), do: instrument_status_from_string(Map.get(row, "status"))

  # `Core.Instrument.status_from/1` recognises the vocabulary Coinbase and Gemini send
  # (`online`, `open`, `closed`, ...); this venue's own `V2TradingPair` schema sends
  # `"tradable"` for a listed pair — a different word for the same state, not a gap in
  # `status_from/1`, so it is read directly here instead. Anything other than the one
  # value this package has actually seen is `:unknown` rather than assumed `:delisted`:
  # a status string never seen on this venue must not manufacture a delisting nothing
  # said.
  defp instrument_status_from_string("tradable"), do: :tradable
  defp instrument_status_from_string(_other), do: :unknown

  # `seen` is a loop guard, and it is not defensive decoration.
  #
  # A cursor walk trusts the venue to eventually stop saying "next". If it ever points at
  # a page already fetched — its bug, or a cursor this package fails to carry forward —
  # the walk runs forever: the caller hangs with no error, and the venue is hammered by a
  # signed request every few milliseconds from a process nothing will interrupt.
  #
  # There is no safe number of pages to allow, so the bound is on *repetition* rather than
  # on count: a page already visited ends the walk with what was collected, and says so.
  @doc """
  Rounds a price and quantity to what the venue will actually accept, from the same
  `trading_pairs` endpoint `get_symbols/2` already calls.

  `get_symbols/2` extracts only `symbol` from each row and discards the rest —
  `asset_increment`, `quote_increment`, `max_order_size` and `min_order_amount` are real
  fields on `V2TradingPair` (Robinhood's own OpenAPI schema, `docs.robinhood.com`), not
  invented here. `min_order_size` is absent from the schema itself despite being named in
  the *prose* beside `estimated_price` ("quantity must be between `min_order_size` and
  `max_order_size` as defined in our Get Crypto Trading Pairs endpoint") — the vendor's
  own documentation names a field its own schema does not define. Carried as `nil` rather
  than guessed at from `min_order_amount`, which is a cash minimum, not a unit minimum.
  """
  @spec quantization(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def quantization(symbol, credentials, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    path = @trading_pairs_path <> "?symbol=" <> URI.encode(native)

    with {:ok, body} <- get(path, credentials, opts),
         {:ok, row} <- result_for(body, native) do
      {:ok,
       %{
         price_increment: decimal(row["quote_increment"]),
         quantity_increment: decimal(row["asset_increment"]),
         # The schema names no unit minimum — see the moduledoc above.
         min_quantity: nil,
         max_quantity: decimal(row["max_order_size"]),
         min_quote_size: decimal(row["min_order_amount"]),
         status: row["status"]
       }}
    end
  end

  # **Deliberately does not read `is_api_tradable`.** This answers "how would an order for
  # this symbol be rounded", not "will the venue accept one" — `get_symbols/2` and
  # `list_instruments/2` are where `is_api_tradable: false` is read, because they build a
  # catalogue a consumer trusts to be quotable and tradable. A caller that already has a
  # symbol in hand (from wherever) and wants its increments is asking a rounding question,
  # and the trading-pair row answers it the same way whether or not the pair is currently
  # API-tradable. Checked deliberately, not skipped: recorded here so the omission reads as
  # a decision, 2026-09-29.

  # Bounds every paginated walk this module runs — `trading_pairs` (`get_symbols/2`,
  # `list_instruments/2`, both via `walk_trading_pairs/2`), `holdings` (`get_balances/2`,
  # when the venue paginates them), and `orders` (`get_orders/2`, when the caller does not
  # cap itself with `opts[:limit]`) — matching `dp_exchange_coinbase`'s
  # `@max_account_pages`/`@max_fill_pages` and `dp_exchange_webull`'s `@max_pages`. Robinhood
  # was the one venue in the family walking any cursor with no page bound at all; that gap
  # is closed once, here, for every endpoint that walks rather than once per endpoint.
  #
  # **The cycle guard below does not cover this, and that is the whole point.** `seen`
  # catches a venue that hands back a path it already gave us; it cannot catch one that
  # hands back a NEW path every time (`?cursor=1`, `?cursor=2`, …), because no path ever
  # repeats. A venue-side defect of that shape would walk forever, holding a caller and a
  # rate-limit budget with it. Fifty pages is the family's figure, not a measured one for
  # this venue — Robinhood Crypto lists on the order of a hundred trading pairs, so this is
  # roughly two orders of magnitude of headroom for that endpoint; holdings and orders have
  # not been measured against it at all, and the same figure is used for lack of a better
  # one rather than a per-endpoint guess.
  @max_pages 50

  # `get_symbols/2` and `list_instruments/2` share this walk of `trading_pairs` — each maps
  # the same raw rows to what it needs, rather than the walk deciding ahead of time which
  # fields anyone wants.
  defp walk_trading_pairs(credentials, opts),
    do: walk(@trading_pairs_path, credentials, opts, [], 0, [], :too_many_trading_pair_pages)

  # Collects raw rows across every page of a `{"next", "previous", "results"}` cursor —
  # `V2TradingPairsResponse`, `V2HoldingsResponse` and `V2OrdersResponse` are the same shape
  # for this purpose (confirmed against the vendor's OpenAPI document, 2026-09-29), which is
  # what let this walk generalise from `trading_pairs` alone to all three. `too_many_error`
  # is the atom a caller gets back on the page bound below — `walk_trading_pairs/2` above
  # fixes it at `:too_many_trading_pair_pages` to keep that one call site's existing error
  # unchanged; `get_balances/2` and `get_orders/2` pass their own.
  #
  # Fails closed on the bound rather than returning what it has: a truncated catalogue,
  # holdings list or order history answered as `{:ok, rows}` is a partial list presented as
  # complete, which is the "nearby substitute where an error belongs" failure this family
  # keeps paying for. Every other venue's pagination bound in this family answers the same
  # way.
  defp walk(_path, _credentials, _opts, _pages, page, _seen, too_many_error)
       when page >= @max_pages,
       do: {:error, too_many_error}

  defp walk(path, credentials, opts, pages, page, seen, too_many_error) do
    if path in seen do
      {:error, {:pagination_loop, path}}
    else
      case get(path, credentials, opts) do
        {:ok, %{"results" => results} = body} when is_list(results) ->
          # Pages are accumulated as a list OF PAGES and concatenated once at the end.
          # This was `acc ++ results`, which copies the whole accumulator on every page —
          # quadratic in the number of rows, for a walk whose entire job is to grow a list.
          # `seen` stays a plain list: the scan is linear, but @max_pages now bounds it at
          # 50 entries, so a MapSet buys nothing measurable — and it cost a dialyzer opacity
          # warning, which is a worse trade than the scan it removed.
          pages = [results | pages]

          case next_path(body) do
            nil -> {:ok, pages |> Enum.reverse() |> Enum.concat()}
            next -> walk(next, credentials, opts, pages, page + 1, [path | seen], too_many_error)
          end

        # `"results": null` is an empty page, the same convention `account_rows/1` and
        # `order_rows/1` both give their own single-page endpoints — carried here so a
        # WALKED endpoint (holdings) reads a null page identically rather than refusing a
        # page that said nothing was wrong. `trading_pairs` and `orders` have never been
        # observed to send this; harmless for them either way.
        {:ok, %{"results" => nil} = body} ->
          case next_path(body) do
            nil -> {:ok, pages |> Enum.reverse() |> Enum.concat()}
            next -> walk(next, credentials, opts, pages, page + 1, [path | seen], too_many_error)
          end

        {:ok, _unexpected} ->
          {:error, :unexpected_response_shape}

        error ->
          error
      end
    end
  end

  # The venue returns an absolute URL for the next page; the signature covers a path, so
  # only the path-and-query part is carried forward.
  defp next_path(%{"next" => next}) when is_binary(next) and next != "" do
    uri = URI.parse(next)
    if uri.query, do: uri.path <> "?" <> uri.query, else: uri.path
  end

  defp next_path(_no_more), do: nil

  # --- accounts, holdings and trading (v2) --------------------------------

  @doc """
  The crypto trading account — `GET /api/v2/crypto/trading/accounts/`.

  **The account number this returns is a parameter on almost everything else.** v2 takes
  `account_number` as a query parameter on holdings, on the order list, on one order, and on
  placing one — where v1 took none. A caller that skipped this call has nothing to address
  those with.

  Returned as the venue's own map.

  **Deliberately does not walk `next`/`previous`, unlike `get_symbols/2`.**
  `V2AccountsResponse` carries the same cursor fields the trading-pairs response does, so
  the shape supports paging. This does not follow it: one account per credential is this
  venue's common case (a crypto brokerage account is singular by design), the risk of a
  truncated result silently reads as "the credential's one account" either way, and walking
  here would be undischarged complexity against a case that has never been observed. This is
  a recorded decision, not an oversight — revisit if a credential is ever seen with more than
  one page.
  """
  @spec get_accounts(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_accounts(credentials, opts) do
    with {:ok, body} <- get("/api/v2/crypto/trading/accounts/", credentials, opts) do
      account_rows(body)
    end
  end

  defp account_rows(%{"results" => rows}) when is_list(rows), do: {:ok, rows}
  # **The wrapper is never a row.** When `"results"` is present it decides the shape whatever
  # it holds; only a response with no `"results"` key at all is treated as one bare object.
  # The catch-all used to take the wrapper too: a page `{"next": null, "results": null}`
  # came back as an ACCOUNT, `{:ok, [%{"next" => nil, "results" => nil}]}`. The same defect
  # `dp_exchange_webull`'s `rows/1` had, found the same day.
  #
  # `null` is an empty page. **Anything else that is not a list is not a page this package
  # can read**, and it used to be read as no accounts, like `null`: `"results": "denied"` or a
  # body that is not an object at all answered `{:ok, []}`. A host told a credential holds
  # no account stops asking, which is the wrong outcome for a response that said nothing
  # about accounts.
  defp account_rows(%{"results" => nil}), do: {:ok, []}
  defp account_rows(%{"results" => _unreadable}), do: {:error, :unexpected_response_shape}
  defp account_rows(%{} = row), do: {:ok, [row]}
  defp account_rows(_other), do: {:error, :unexpected_response_shape}

  @doc """
  Crypto holdings — `GET /api/v2/crypto/trading/holdings/`.

  `opts[:account_number]` is **required by v2** and refused here when missing rather than
  sent: v1 took none and answered for the credential's own account, so a call without one
  is a v1 habit that v2 will not honour.

  **Three quantities, kept apart.** The venue publishes `total_quantity`,
  `quantity_available_for_trading` and — where it holds any — an amount that is neither: a
  balance in an open order is real and is not tradable. `Types.Balance` carries the total
  and the available separately for that reason, and the difference is what is on hold.

  `opts[:asset_codes]` narrows to particular assets; without it the venue returns all of
  them.

  **Walks every page.** `V2HoldingsResponse` is `{"next", "previous", "results"}` — the same
  cursor shape `trading_pairs` uses — confirmed against the vendor's OpenAPI document,
  2026-09-29. This used to read only the first page: a holding on page two was simply
  absent from the reply, which reads as "the credential holds none of that asset" —
  `to_balance/2`'s own comment calls the equivalent single-row case the dangerous one, and a
  whole missing PAGE of rows is the same failure at a larger scale. Bounded the same way
  `walk/7` bounds `trading_pairs`, and fails closed on the bound for the same reason: a
  truncated holdings list answered as `{:ok, balances}` is money a caller is told it does
  not have.

  **The account's cash is appended as one more `Balance`, after the holdings** —
  dp-exchange-core issue #35: holdings are crypto assets only, so a funded account's cash
  never appeared, and a host summing cash across venues read zero on an account actually
  holding money. It comes from `GET /api/v2/crypto/trading/accounts/` (`get_accounts/2`),
  matched to this call's `account_number` — `buying_power` as `available_balance`,
  `buying_power_currency` as `currency`, and `balance: nil` because the venue states no
  total cash figure, only what is available. When `opts[:asset_codes]` is given, the cash
  row is included only if that list names the account's currency.

  This second call can refuse on its own, on top of every way the holdings call can:
  `{:error, {:account_not_found, account}}` when no row in `get_accounts/2`'s reply matches
  `account_number`, or `{:error, :unexpected_response_shape}` / `{:error,
  {:missing_required_field, :buying_power}}` when the matched row has no readable currency
  or amount. Answering without the cash row would be the zero-dollar answer this exists to
  stop, so a holdings list that decoded cleanly still refuses if the account's cash cannot
  be read.
  """
  @spec get_balances(map(), keyword()) ::
          {:ok, [Balance.t()]} | {:error, term()} | {:refused, term()}
  def get_balances(credentials, opts) do
    with {:ok, account} <- required_account(opts) do
      asset_codes = List.wrap(Config.opt(opts, :asset_codes, []))

      query =
        [{"account_number", account}] ++ Enum.map(asset_codes, &{"asset_code", &1})

      path = "/api/v2/crypto/trading/holdings/" <> query_string(query)
      asked_at = DateTime.utc_now()

      with {:ok, rows} <- walk(path, credentials, opts, [], 0, [], :too_many_holdings_pages),
           {:ok, holdings} <- to_balances(rows, asked_at),
           {:ok, cash} <- cash_balance(account, asset_codes, credentials, opts, asked_at) do
        {:ok, holdings ++ cash}
      end
    end
  end

  # **The account's cash is a balance too.** Holdings are crypto assets only, so a funded
  # account's cash never appeared: a host summing its cash across venues read zero on a
  # Robinhood account holding $47.79, and refused to reset a strategy ledger for want of
  # starting cash (dp-exchange-core issue #35). Every other venue's `Balance` list carries
  # its quote cash. Here it lives on the account, as `buying_power` in
  # `buying_power_currency` (`V2Account`, docs/reference/robinhood/openapi/
  # crypto-trading.openapi.json).
  #
  # `buying_power` is "the available buying power", so it is `available_balance`. The venue
  # states no total cash figure, so `balance` is `nil` rather than a copy of the available
  # amount dressed up as one. Every field is required: an account this call cannot find, or
  # one with no readable amount or currency, refuses the reply, because answering without the
  # cash row is the zero-dollar answer this exists to stop.
  #
  # A caller narrowing by `:asset_codes` gets the cash row only when it named that currency.
  defp cash_balance(account, asset_codes, credentials, opts, asked_at) do
    with {:ok, rows} <- get_accounts(credentials, opts),
         {:ok, row} <- account_row(rows, account),
         {:ok, currency} <- required_currency(row["buying_power_currency"]),
         {:ok, amount} <- required_amount(row["buying_power"]) do
      if asset_codes == [] or currency in asset_codes do
        {:ok,
         [
           %Balance{
             currency: currency,
             balance: nil,
             available_balance: amount,
             hold: nil,
             timestamp: asked_at,
             provider: :robinhood
           }
         ]}
      else
        {:ok, []}
      end
    end
  end

  defp account_row(rows, account) do
    case Enum.find(rows, &match?(%{"account_number" => ^account}, &1)) do
      nil -> {:error, {:account_not_found, account}}
      row -> {:ok, row}
    end
  end

  defp required_amount(value) do
    case decimal(value) do
      %Decimal{} = amount -> {:ok, amount}
      _unreadable -> {:error, {:missing_required_field, :buying_power}}
    end
  end

  # Refuses a holdings row this package cannot read, rather than emitting an unusable
  # `Balance` and reporting it as success.
  #
  # `Core.Types.Balance`'s `new/1` refuses a `nil` in `:currency`. Nothing here called
  # `new/1` — this built the struct literally, the way all five venues do — so the check
  # never ran, and `currency` came straight out of the venue's JSON by key. A renamed or
  # absent `asset_code` produced `%Balance{currency: nil}`: an amount attributable to no
  # asset, returned inside `{:ok, balances}`, which a consumer cannot size, book or
  # reconcile against. It is the renamed-field scenario `Core.Types.Validate`'s moduledoc
  # exists for, arriving through the one path that bypassed the constructor written to
  # catch it.
  #
  # `total_quantity` is deliberately NOT guarded the same way. `Core.Types.Balance` states
  # that `:balance` may honestly be `nil` while `:currency` may not, and the two are not the
  # same kind of required: an unknown quantity is still a balance, an unattributable one is
  # not. `dp_exchange_gemini` made and recorded the same call for its own amount field. This
  # matters more here since the NaN guard landed — `decimal/1` now maps `"NaN"` and `"Inf"`
  # to `nil` rather than to a poisonous `Decimal`, which is right, and which makes a `nil`
  # total reachable from a value that was present all along.
  defp to_balance(%{} = row, asked_at) do
    with {:ok, currency} <- required_currency(row["asset_code"]) do
      {:ok,
       %Balance{
         currency: currency,
         balance: decimal(row["total_quantity"]),
         available_balance: decimal(row["quantity_available_for_trading"]),
         # The venue publishes no hold figure. Subtracting would produce a number it never
         # stated, and one that is wrong the moment either side is missing.
         hold: nil,
         timestamp: asked_at,
         provider: :robinhood
       }}
    end
  end

  # One unreadable row refuses the whole reply rather than leaving a gap in it. A balance
  # list with an entry silently missing reads as "you hold none of that asset", which is a
  # different and more dangerous statement than "this response could not be read".
  # A holdings row that is not an object is unreadable, and refused like one with no
  # currency. It used to raise in `Access`, inside the caller's process.
  defp to_balance(_unreadable_row, _asked_at), do: {:error, :unexpected_response_shape}

  defp to_balances(rows, asked_at) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case to_balance(row, asked_at) do
        {:ok, balance} -> {:cont, {:ok, [balance | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, balances} -> {:ok, Enum.reverse(balances)}
      error -> error
    end
  end

  defp required_currency(code) when is_binary(code) and code != "", do: {:ok, code}
  defp required_currency(_absent), do: {:error, :unexpected_response_shape}

  @doc """
  An execution estimate — `GET /api/v2/crypto/trading/estimated_price/`.

  **This endpoint moved between versions**: v1 served it under `marketdata`, v2 under
  `trading`. A package pointed at the v1 path gets a 404 that reads like an outage.

  **Not a quote and not a fill.** It is what the venue estimates a given quantity would
  execute at *now*, which is a different number from `get_top_of_book/3`'s top of book —
  the second price on this venue, and the only one that accounts for size. There is no
  third: this venue publishes no last trade at any endpoint, which is why the facade's
  `get_price/2` is `:unsupported` (see this module's moduledoc).

  `side` is the venue's own `bid`, `ask` or `both`. Several quantities can be asked at once:
  the venue takes them comma-separated, and asking for `0.1,1,10` in one request is how a
  caller sees the slope rather than three points taken at three times.
  """
  @spec get_estimated_price(
          String.t(),
          String.t(),
          String.t() | [String.t()],
          map(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_estimated_price(symbol, side, quantity, credentials, opts) do
    query = [
      {"symbol", SymbolFormat.to_exchange_symbol(symbol)},
      {"side", to_string(side)},
      {"quantity", quantity_param(quantity)}
    ]

    path = "/api/v2/crypto/trading/estimated_price/" <> query_string(query)

    with {:ok, body} <- get(path, credentials, opts), do: {:ok, body}
  end

  defp quantity_param(list) when is_list(list),
    do: list |> Enum.map(&decimal_string/1) |> Enum.join(",")

  defp quantity_param(value), do: decimal_string(value)

  # Full notation, never scientific: `1.0e-4` is not a quantity this venue reads. A float
  # goes through `Decimal` too, because `to_string(0.00001)` IS `"1.0e-5"`.
  defp decimal_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  defp decimal_string(value) when is_float(value),
    do: value |> Decimal.from_float() |> Decimal.to_string(:normal)

  defp decimal_string(value), do: to_string(value)

  @doc """
  Orders on one account — `GET /api/v2/crypto/trading/orders/`.

  `opts[:account_number]` is required by v2. `opts[:created_at_start]` and the venue's other
  filters are passed through under its own names, and none is defaulted — a start date
  chosen here would return a real list of orders over a window the caller did not ask about.
  The filters read are `:created_at_start`, `:created_at_end`, `:updated_at_start`,
  `:updated_at_end`, `:symbol`, `:side`, `:type` and `:state`. A `%DateTime{}` passed for
  any of the four dates is sent as ISO 8601 (`DateTime.to_iso8601/1`); a string is sent
  unchanged. `:state` takes the venue's word or a `Core` status atom, mapped back to the
  venue's spelling (`:cancelled` is `"canceled"`, `:rejected` is `"failed"`).

  **Paging changed.** This used to read only the first page and return it as `{:ok, _}`,
  documented as a deliberate choice — "a caller filtering by date wants the page it asked
  for". That was true of the filters and false of the result: a caller who did not also
  pass `opts[:cursor]` had no way to reach page two, so any account with more than one
  page of matching orders silently lost every order past the first, reported as complete
  success. `Core`'s contract types this `[Order.t()]`, not a cursor-bearing page, so there
  is no way to hand a `next` back through the return value either.

  What it does now: with `opts[:limit]` given, exactly **one** page is fetched and
  returned — the venue's own `GET orders` endpoint takes no `limit` parameter at all
  (confirmed against the vendor's OpenAPI document, 2026-09-29: its query parameters are
  `account_number`, `cursor`, `created_at_start`, `created_at_end`, `updated_at_start`,
  `updated_at_end`, `symbol`, `side`, `type`, `state` — no `limit`), so `:limit` is read
  here as "do not walk `next`", not as a count this package can ask the venue to cap; pass
  `opts[:cursor]` alongside it to choose which page. Without `opts[:limit]`, every page is
  walked to the end with the same bounded `walk/7` `get_symbols/2` uses, failing closed
  (`{:error, :too_many_order_pages}`) rather than returning a truncated history as
  complete.
  """
  @spec get_orders(map(), keyword()) ::
          {:ok, [Order.t()]} | {:error, term()} | {:refused, term()}
  def get_orders(credentials, opts) do
    with {:ok, account} <- required_account(opts) do
      query =
        [{"account_number", account}]
        |> put_query("created_at_start", iso8601_param(Keyword.get(opts, :created_at_start)))
        |> put_query("created_at_end", iso8601_param(Keyword.get(opts, :created_at_end)))
        |> put_query("updated_at_start", iso8601_param(Keyword.get(opts, :updated_at_start)))
        |> put_query("updated_at_end", iso8601_param(Keyword.get(opts, :updated_at_end)))
        |> put_query("symbol", order_symbol(Keyword.get(opts, :symbol)))
        |> put_query("side", Keyword.get(opts, :side))
        |> put_query("type", Keyword.get(opts, :type))
        |> put_query("state", order_state_param(Keyword.get(opts, :state)))
        |> put_query("cursor", Keyword.get(opts, :cursor))

      path = "/api/v2/crypto/trading/orders/" <> query_string(query)

      if Keyword.has_key?(opts, :limit) do
        get_orders_one_page(path, credentials, opts)
      else
        with {:ok, rows} <- walk(path, credentials, opts, [], 0, [], :too_many_order_pages) do
          to_orders(rows)
        end
      end
    end
  end

  defp get_orders_one_page(path, credentials, opts) do
    with {:ok, body} <- get(path, credentials, opts),
         {:ok, rows} <- order_rows(body) do
      to_orders(rows)
    end
  end

  # Vendor: ISO 8601 date-time (`created_at_start`/`created_at_end`, both `format:
  # "date-time"` in the OpenAPI schema). `put_query/3`'s blanket `to_string/1` on a
  # `%DateTime{}` gives `"2026-09-01 12:00:00Z"` — space-separated, Elixir's own
  # `String.Chars` rendering, not the `T`-separated wire format the vendor's schema
  # documents. A string the caller already built is sent exactly as given; only a
  # `%DateTime{}` struct is reformatted here.
  defp iso8601_param(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601_param(value), do: value

  @doc """
  One order — `GET /api/v2/crypto/trading/orders/{order_id}/`.

  `opts[:account_number]` is required by v2.

  **This path is not in the vendor's OpenAPI `paths`.** It appears only in the sample client
  in the spec's own `info.description` (its `get_order` method). Its response is decoded as
  `V2CryptoOrder`, the schema the documented cancel path returns, and the test fixture is
  built from that schema, not captured from the venue
  (`test/fixtures/spec_examples/README.md`). Unmeasured.
  """
  @spec get_order(map(), String.t(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def get_order(credentials, order_id, opts) when is_binary(order_id) do
    with {:ok, account} <- required_account(opts) do
      path =
        "/api/v2/crypto/trading/orders/" <>
          URI.encode(order_id) <> "/" <> query_string([{"account_number", account}])

      with {:ok, body} <- get(path, credentials, opts), do: to_order(body)
    end
  end

  @doc """
  Places an order — `POST /api/v2/crypto/trading/orders/`. **This moves funds.**

  **`client_order_id` is generated here when the caller does not supply one, and it is an
  idempotency key.** Re-sending the same one returns the original order instead of placing a
  second; a caller retrying a request whose response it never saw should pass the *same* id
  rather than let a new one be made, which is why the option exists.

  **The order's configuration goes under a key named after its own type** — `market` takes
  `market_order_config`, `limit` takes `limit_order_config`, and so on. This package builds
  that key from the type rather than taking it from the caller: a config under the wrong key
  is silently ignored by the venue and the order is placed with none.

  `symbol`, `side`, `order_type` and a quantity are required. The quantity goes in as
  `asset_quantity` — the venue's own field — and a limit order also needs `limit_price`.
  """
  @spec place_order(map(), map(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def place_order(credentials, request, opts) do
    with {:ok, account} <- required_account(opts),
         {:ok, body} <- order_body(request, opts) do
      path = "/api/v2/crypto/trading/orders/" <> query_string([{"account_number", account}])

      with {:ok, response} <- post(path, body, credentials, opts), do: to_order(response)
    end
  end

  @doc """
  Cancels an order — `POST /api/v2/crypto/trading/orders/{order_id}/cancel/`.

  **A POST, not a DELETE**, and it takes no account number where every other order call
  does.

  **v2's cancel response is a full `V2CryptoOrder`, decoded the same way `get_order/3` and
  `place_order/3` decode theirs** — confirmed against the vendor's own OpenAPI document,
  2026-09-06: `200` on `/api/v2/crypto/trading/orders/{id}/cancel/` is
  `application/json` against `$ref: V2CryptoOrder`, the identical schema `get_order/3`
  reads. This function used to discard that body and return a fabricated stub with
  `status: :open` hardcoded regardless of what the venue actually said — correct for v1's
  cancel endpoint (`text/plain`, `"Cancel request was submitted for order {id}"`, genuinely
  no outcome), wrong for the v2 endpoint this module actually calls, which reports the
  order's real state (`open` if the cancel is still in flight, `canceled` once it lands,
  or `filled`/`partially_filled` if a fill won the race). Read that state rather than
  assume it.
  """
  @spec cancel_order(map(), String.t(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def cancel_order(credentials, order_id, opts) when is_binary(order_id) do
    path = "/api/v2/crypto/trading/orders/" <> URI.encode(order_id) <> "/cancel/"

    with {:ok, body} <- post(path, %{}, credentials, opts), do: to_order(body)
  end

  defp required_account(opts) do
    case Keyword.get(opts, :account_number) do
      account when is_binary(account) -> {:ok, account}
      _missing -> {:error, {:account_number_required, :robinhood}}
    end
  end

  defp order_symbol(nil), do: nil
  defp order_symbol(symbol), do: SymbolFormat.to_exchange_symbol(symbol)

  defp order_body(request, opts) do
    with {:ok, symbol} <- order_field(request, :symbol),
         {:ok, side} <- order_field(request, :side),
         {:ok, type} <- order_field(request, :order_type),
         {:ok, config} <- order_config(type, request) do
      wire_type = wire_order_type(type)

      {:ok,
       %{
         "client_order_id" => client_order_id(opts),
         "side" => to_string(side),
         "type" => wire_type,
         "symbol" => SymbolFormat.to_exchange_symbol(symbol),
         "#{wire_type}_order_config" => config
       }}
    end
  end

  # The wire's own spelling for the `"type"` field and the `"#{type}_order_config"` key it
  # selects — never the raw, interpolated `type` the caller passed. `order_config/2` below
  # accepts both `:stop` (this contract's shared atom) and `:stop_loss` (the venue's own),
  # but the venue itself answers to exactly one spelling, `"stop_loss"`, on both the `type`
  # field and the config key. Interpolating the caller's atom directly produced
  # `"stop_order_config"` for a caller that passed `:stop` — the very atom
  # `capabilities().supported_order_types` declares — which the venue does not recognise
  # and silently drops, so the order shipped with no config object at all rather than
  # refusing.
  defp wire_order_type(:stop), do: "stop_loss"
  defp wire_order_type(type), do: to_string(type)

  defp order_field(request, key) do
    case Map.get(request, key) do
      nil -> {:error, {:missing_field, key}}
      value -> {:ok, value}
    end
  end

  # The venue's four order types, and what each config must carry. A limit without a price
  # is an order the venue rejects; refusing here says which field rather than relaying a
  # message about a config key.
  #
  # `market_order_config` carries no `time_in_force` in the vendor's schema, so a market
  # order never gets one — even if the caller supplied one, it would have nowhere honest to
  # go.
  defp order_config(type, request) when type in [:market, "market"] do
    with {:ok, quantity} <- order_field(request, :quantity) do
      {:ok, %{"asset_quantity" => decimal_string(quantity)}}
    end
  end

  defp order_config(type, request) when type in [:limit, "limit"] do
    with {:ok, quantity} <- order_field(request, :quantity),
         {:ok, price} <- order_field(request, :price),
         {:ok, tif} <- order_time_in_force(request) do
      {:ok,
       %{"asset_quantity" => decimal_string(quantity), "limit_price" => decimal_string(price)}
       |> put_time_in_force(tif)}
    end
  end

  # `:stop` is the shared contract's atom for this order type and is what a consumer moving
  # between venues passes; `:stop_loss` is this venue's own wire name for the same thing.
  # Only the second was accepted until 2026-09-07, so a caller passing the atom
  # `capabilities/0` now declares — and that `DpExchange.Webull` already maps the same way,
  # `:stop` -> `"STOP_LOSS"` — was refused with `{:unsupported_order_type, :stop}` on a
  # venue that serves it. Both are accepted; the venue's own spelling is not withdrawn.
  defp order_config(type, request) when type in [:stop, :stop_loss, "stop_loss"] do
    with {:ok, quantity} <- order_field(request, :quantity),
         {:ok, stop} <- order_field(request, :stop_price),
         {:ok, tif} <- order_time_in_force(request) do
      {:ok,
       %{"asset_quantity" => decimal_string(quantity), "stop_price" => decimal_string(stop)}
       |> put_time_in_force(tif)}
    end
  end

  defp order_config(type, request) when type in [:stop_limit, "stop_limit"] do
    with {:ok, quantity} <- order_field(request, :quantity),
         {:ok, price} <- order_field(request, :price),
         {:ok, stop} <- order_field(request, :stop_price),
         {:ok, tif} <- order_time_in_force(request) do
      {:ok,
       %{
         "asset_quantity" => decimal_string(quantity),
         "limit_price" => decimal_string(price),
         "stop_price" => decimal_string(stop)
       }
       |> put_time_in_force(tif)}
    end
  end

  defp order_config(type, _request), do: {:error, {:unsupported_order_type, type}}

  # `opts[:time_in_force]` is absent for almost every caller today, and absence must build
  # exactly the config this package built before this atom existed — no key at all, not a
  # key holding a default the venue was never asked for. A value present but unrepresentable
  # (an atom `tif_name/1` has no wire name for — `:ioc`, `:fok`, `:gtd`, or one of Core's
  # `:gfw`/`:gfm` when those ship) is refused, rather than sent as nothing and silently
  # ignored the way a wrong config key already is on this venue.
  defp order_time_in_force(request) do
    case Map.get(request, :time_in_force) do
      nil ->
        {:ok, nil}

      tif ->
        case tif_name(tif) do
          nil -> {:error, {:unsupported_time_in_force, tif}}
          name -> {:ok, name}
        end
    end
  end

  defp put_time_in_force(config, nil), do: config
  defp put_time_in_force(config, name), do: Map.put(config, "time_in_force", name)

  defp tif_name(tif), do: Map.get(@tif_names, tif)
  defp tif_atom(name), do: Map.get(@tif_atoms, name)

  # A v4 UUID from the VM's own CSPRNG. The venue treats `client_order_id` as an idempotency
  # key, so a collision would return someone else's order — worth generating correctly, and
  # not worth a dependency for sixteen bytes.
  # **`Config.opt/3`, not `Keyword.get/3` with a default — and a string, or a fresh key.**
  #
  # This was `Keyword.get(opts, :client_order_id, generate_client_order_id())`. `Keyword.get/3`
  # substitutes its default only for an ABSENT key, never for one that is present and `nil`,
  # and this family forwards `opts` unchanged through every layer by convention — the facade
  # passes `with_limiter(opts)` straight here. So a caller whose own caller never set a
  # `client_order_id` handed through `client_order_id: nil`, and the order went out with
  # `"client_order_id": null`.
  #
  # Measured against a transport answering 500: **three submissions of the same order, each
  # carrying `client_order_id: null`**, because `request_opts/1` forwards `:retry_attempts`
  # and `Core.HttpClient`'s default of 3 applied. The key is the whole reason those retries
  # are safe — "re-sending one returns the original order instead of placing a second" —
  # and a null one is no key at all. It is the same forwarded-`nil` trap `Core.Config.opt/3`
  # exists for, which this family has recorded three times already under
  # `rate_limit_blocking`.
  #
  # The two sibling venues had already got this right, each its own way:
  # `dp_exchange_coinbase` reads `Map.get(request, :client_order_id) || generate()` and
  # `dp_exchange_webull` matches `nil ->` explicitly. Anything that is not a non-empty
  # string is treated as absent — an empty key is a key every order would share.
  defp client_order_id(opts) do
    case Config.opt(opts, :client_order_id, nil) do
      id when is_binary(id) and id != "" -> id
      _absent -> generate_client_order_id()
    end
  end

  defp generate_client_order_id do
    <<a::32, b::16, _version::4, c::12, _variant::2, d::62>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-4~3.16.0b-a~3.16.0b-~12.16.0b", [
      a,
      b,
      c,
      Bitwise.bsr(d, 50),
      Bitwise.band(d, 0xFFFFFFFFFFFF)
    ])
    |> to_string()
  end

  # Refuses a body that is not an order object, rather than answering with an empty one.
  #
  # This used to fall through to a hand-built `%Order{}` with `id`, `symbol`, `side`,
  # `order_type`, `quantity` and `status` all `nil`, returned as `{:ok, order}` from
  # `get_order/3`, `place_order/3` and `cancel_order/3`. A caller that placed an order and
  # got that back could not tell it apart from a real order the venue had declined to
  # describe: every field was plausible-looking `nil` and the tuple said success. For
  # `place_order/3` in particular that is the worst possible answer to "did my money move?"
  # — the request may well have been accepted, and the reply asserts nothing about it while
  # claiming to have worked.
  #
  # `Types.Order` genuinely does allow each of those fields to be `nil` (see its "Why the
  # enforced keys still admit `nil`" — Robinhood's own cancel acknowledgement is the case it
  # was widened for), so the struct itself cannot distinguish "the venue said nothing about
  # this field" from "there was no order object at all". That distinction has to be made
  # here, where the shape is still visible. `{:error, :unexpected_response_shape}` is the
  # same refusal `DpExchange.Gemini.Private.to_order/1` returns for the same condition.
  # **An order with no id is refused, and so is a list whose shape is not a page.**
  #
  # Found by feeding every active facade call plausible-but-wrong bodies. `get_orders/2` read
  # its rows through `account_rows/1`, whose last clause wraps any bare object as one row —
  # right for the accounts endpoint, which can answer with a single account, and wrong here:
  # `{}` became `{:ok, [%Order{id: nil, symbol: nil, side: nil, …}]}`. `get_order/3` did the
  # same with any map at all. An order a caller cannot cancel or look up again is not a weaker
  # answer; it is a phantom.
  #
  # Refused rather than dropped, which is this module's own rule for this list —
  # `to_orders/1` refuses the whole batch on one unreadable row, because a list with an order
  # silently missing reads as complete. `Core.Types.Order` admits `id: nil` for
  # acknowledgements that carry little else; this venue's V2 order object always carries one.
  defp to_order(%{"id" => id} = row) when is_binary(id) and id != "",
    do: {:ok, order_struct(row)}

  defp to_order(row) when is_map(row), do: {:error, {:missing_required_field, :id}}
  defp to_order(_row), do: {:error, :unexpected_response_shape}

  # The orders endpoint answers with a page, `{"next": …, "results": [...]}`, and never with a
  # bare order — so, unlike `account_rows/1`, there is no bare-object clause to fall into.
  defp order_rows(%{"results" => rows}) when is_list(rows), do: {:ok, rows}
  # `null` is an empty page; any other non-list is unreadable, not empty. See `account_rows/1`:
  # `"results": "denied"` used to answer `{:ok, []}`, "no orders", about an account that may
  # hold open ones.
  defp order_rows(%{"results" => nil}), do: {:ok, []}
  defp order_rows(%{"results" => _unreadable}), do: {:error, :unexpected_response_shape}
  defp order_rows(_other), do: {:error, :unexpected_response_shape}

  # One bad row refuses the whole list rather than seeding it with a blank order among real
  # ones — the hardest version of this to notice, and the reason `get_orders/2` does not
  # simply `Enum.map/2` here.
  defp to_orders(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case to_order(row) do
        {:ok, order} -> {:cont, {:ok, [order | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, orders} -> {:ok, Enum.reverse(orders)}
      error -> error
    end
  end

  defp order_struct(row) do
    %Order{
      id: row["id"],
      symbol: order_canonical(row["symbol"]),
      side: order_side(row["side"]),
      order_type: order_kind(row["type"]),
      time_in_force: tif_atom(configured_time_in_force(row)),
      # `quantity` is the order's own SIZE, read from the type-named `*_order_config` it
      # was placed or echoed with — never from `filled_asset_quantity`. Per the vendor's
      # own `OrderResponse` schema, `filled_asset_quantity` is "Portion of total amount
      # that have been filled" and is always present on the response, filled or not — this
      # used to read `row["filled_asset_quantity"] || configured_quantity(row)`, so an
      # order with SOME fill (a real, non-`nil`, non-zero-that-truthy-still-passes value)
      # always took that branch and `quantity` silently became `filled_quantity`'s own
      # value. A resting order with a partial fill reported its ORIGINAL size as however
      # much of it had filled so far — an open 0.5, filled 0.25, read back as
      # `quantity: 0.25`, indistinguishable from a smaller order placed and fully filled.
      quantity: decimal(configured_quantity(row)),
      # `price` and `stop_price` were never read at all — `%Order{}`'s struct literal below
      # simply had no `price:`/`stop_price:` key, so both stayed `nil` on every decode,
      # silently, for every order this package has ever read back. Per the vendor's own
      # `OrderResponse` schema (confirmed 2026-09-29): `limit_order_config.limit_price` and
      # `stop_limit_order_config.limit_price` are exactly what `Core.Types.Order.price`
      # exists to carry, and `stop_loss_order_config.stop_price` /
      # `stop_limit_order_config.stop_price` are what `.stop_price` exists to carry — the
      # same type-named-config scan `configured_quantity/1` already does for
      # `asset_quantity`, generalised the same way `configured_time_in_force/1` generalises
      # it for `time_in_force`. Found via `spec_examples_test.exs`: a fixture built strictly
      # from the vendor's schema decoded a limit order with a real `limit_price` and the
      # returned `Order.price` was `nil` regardless.
      price: decimal(configured_price(row)),
      stop_price: decimal(configured_stop_price(row)),
      filled_quantity: decimal(row["filled_asset_quantity"]),
      average_price: decimal(row["average_price"]),
      status: order_status(row["state"]),
      # `V2CryptoOrder` (the vendor's own schema for what these v2 endpoints return) carries
      # `fee_charged` — the exact data this package chose v2 in order to get. It also
      # carries `estimated_fee_remaining`, which has no slot on `Types.Order` and is not
      # decoded here for that reason: there is nowhere honest to put it.
      #
      # `fee_currency` is left `nil` rather than assumed to be the quote currency: the
      # vendor's schema does not state a currency for `fee_charged`, and this venue's fee is
      # denominated in the pair's quote asset by convention rather than by anything the
      # schema declares — a convention is not the venue's word.
      fee: decimal(row["fee_charged"]),
      fee_currency: nil,
      created_at: order_time(row["created_at"]),
      # Same gap as `price`/`stop_price` above, found the same way: `OrderResponse.updated_at`
      # is a real, always-present field on the vendor's own schema — "the timestamp of when
      # the order was updated" — and `Core.Types.Order.updated_at` exists for exactly it, but
      # nothing here ever read it. `order_time/1` is the same parser `created_at` already
      # uses, so a value in the same wire format decodes identically.
      updated_at: order_time(row["updated_at"]),
      provider: :robinhood
    }
  end

  defp configured_quantity(row) do
    row
    |> Enum.find_value(fn
      {"" <> key, %{"asset_quantity" => quantity}} ->
        if String.ends_with?(key, "_order_config"), do: quantity

      _other ->
        nil
    end)
  end

  # `limit_price` and `stop_price` live inside the type-named config object, same as
  # `asset_quantity` and `time_in_force` — but never both in the same config.
  # `limit_order_config` and `stop_limit_order_config` carry `limit_price`;
  # `stop_loss_order_config` and `stop_limit_order_config` carry `stop_price`. A
  # `market_order_config` row has neither key, so both scans simply find nothing for a
  # market order, which is correct: this venue's market orders have no price at all.
  defp configured_price(row) do
    row
    |> Enum.find_value(fn
      {"" <> key, %{"limit_price" => price}} ->
        if String.ends_with?(key, "_order_config"), do: price

      _other ->
        nil
    end)
  end

  defp configured_stop_price(row) do
    row
    |> Enum.find_value(fn
      {"" <> key, %{"stop_price" => price}} ->
        if String.ends_with?(key, "_order_config"), do: price

      _other ->
        nil
    end)
  end

  # `time_in_force` lives inside the type-named config object, same as `asset_quantity` —
  # but on the RESPONSE side the venue only puts it there for `stop_loss_order_config` and
  # `stop_limit_order_config` (see the module attribute comment above `@tif_names`).
  # `market_order_config` never carries one (see `order_config/2`'s market clause), and
  # `limit_order_config` never carries one EITHER on a response, despite taking one on the
  # request — both yield `nil` here honestly, for two different reasons the venue's own
  # schema states.
  defp configured_time_in_force(row) do
    row
    |> Enum.find_value(fn
      {"" <> key, %{"time_in_force" => tif}} ->
        if String.ends_with?(key, "_order_config"), do: tif

      _other ->
        nil
    end)
  end

  # Not a string is not a symbol, and is `nil` like an absent one. `SymbolFormat` raised on
  # it, inside the caller's process.
  defp order_canonical(symbol) when is_binary(symbol),
    do: SymbolFormat.to_canonical_symbol(symbol)

  defp order_canonical(_absent_or_unreadable), do: nil

  defp order_side("buy"), do: :buy
  defp order_side("sell"), do: :sell
  defp order_side(_other), do: nil

  defp order_kind("market"), do: :market
  defp order_kind("limit"), do: :limit
  defp order_kind("stop_loss"), do: :stop
  defp order_kind("stop_limit"), do: :stop_limit
  defp order_kind(_other), do: nil

  # The venue's own states. `open` is a live order and `canceled` is a dead one; a state
  # this package does not know is `nil` rather than the nearest, because a caller branching
  # on `:filled` must never be handed it for a word that merely looked close.
  defp order_status("open"), do: :open
  defp order_status("partially_filled"), do: :partially_filled
  defp order_status("filled"), do: :filled
  defp order_status("canceled"), do: :cancelled
  defp order_status("failed"), do: :rejected
  defp order_status(_other), do: nil

  # The reverse, for the `state` filter. A `Core` status atom stringified as-is asked the
  # venue for `"cancelled"` and `"rejected"`, words its enum does not have. A string is the
  # venue's own word and is sent unchanged.
  defp order_state_param(:cancelled), do: "canceled"
  defp order_state_param(:rejected), do: "failed"
  defp order_state_param(state), do: state

  defp order_time(nil), do: nil

  defp order_time(value) do
    case parse_time(value) do
      {:ok, at} -> at
      _other -> nil
    end
  end

  defp put_query(query, _name, nil), do: query
  defp put_query(query, name, value), do: query ++ [{name, to_string(value)}]

  # No clause for an empty list: every caller of this passes at least the account number,
  # which v2 requires. Dialyzer proved the empty case unreachable, and a clause for a shape
  # that never arrives reads as though it had been tested.
  defp query_string(pairs), do: "?" <> URI.encode_query(pairs)

  defp post(path, body, credentials, opts) do
    encoded = Jason.encode!(body)

    # Signed per attempt, not once: see `signer/4`.
    url = base_url(opts) <> path

    case HttpClient.request(
           :post,
           url,
           signer("POST", path, encoded, credentials, opts),
           encoded,
           request_opts(opts)
         ) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        decoded_body(response)

      {:ok, %{status: status, body: response}} when status in [400, 401, 403, 404] ->
        {:refused, refusal(status, response)}

      {:ok, %{status: status, body: response}} ->
        {:error, {:exchange_error, :robinhood, "HTTP #{status}: #{inspect(response)}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # **A retry is signed again, not replayed.** The signature carries `x-timestamp`, and the
  # venue's own OpenAPI document states the window directly, on the `Timestamp` security
  # scheme: "timestamps are only valid for 30 seconds after they're generated, and an
  # expired timestamp will be rejected" — confirmed against the Robinhood docs bundle,
  # 2026-09-29. (An earlier version of this comment said the 30-second figure came from
  # third-party client libraries and write-ups, and that the vendor's own page "renders
  # client-side and was not read directly" — that was wrong on both counts: the page does
  # state it, in the security-scheme description above, and that is where this figure comes
  # from now.) `Core.HttpClient` used to retry with the first attempt's headers, and a first
  # attempt that timed out took the whole 30-second `:timeout`. So its retry went out stale,
  # and the venue refused it as unauthorised: `{:refused, _}`, a credential problem the
  # caller does not have. Passing a function makes the client sign each attempt afresh. A
  # write stays safe to retry because `client_order_id` is this venue's idempotency key.
  defp signer(method, path, body, credentials, opts),
    do: fn -> Auth.headers(method, path, body, credentials, opts) end

  # --- request ------------------------------------------------------------

  defp get(path, credentials, opts) do
    url = base_url(opts) <> path

    case HttpClient.request(
           :get,
           url,
           signer("GET", path, "", credentials, opts),
           nil,
           request_opts(opts)
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decoded_body(body)

      # Permanent for the request as sent. A caller whose key was rotated signs again
      # with the new one, which is a different request rather than a retry of this.
      {:ok, %{status: status, body: body}} when status in [400, 401, 403, 404] ->
        {:refused, refusal(status, body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:exchange_error, :robinhood, "HTTP #{status}: #{inspect(body)}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_opts(opts) do
    opts
    |> Keyword.take([
      :limiter,
      :timeout,
      :retry_attempts,
      :log_requests,
      :plug,
      :req_adapter,
      :rate_limit_blocking
    ])
    |> Keyword.merge(provider: :robinhood, raw_status: true)
  end

  # --- decoding -----------------------------------------------------------

  # An empty `results` array is NOT the venue stating the symbol does not exist — it is
  # this specific request coming back with nothing, which a network blip, a transient
  # venue hiccup or an as-yet-unindexed symbol can all produce just as easily as an
  # actual absence from the catalog. `{:refused, _}` is reported once and never retried
  # (`Core.PollingFeed`'s own contract), so mistaking silence for a statement here is
  # permanent: DpCryptoManagement's issue #25 measured 56 of 83 held refusals as exactly
  # this — `BTC-USD`, `ETH-USD`, `LTC-USD`, `LINK-USD`, `DOGE-USD` among them — pairs that
  # answer normally on the very next call. Clearing only those 56 took one consumer's
  # collection scope from 5 pairs to 63, 62 of them fresh within 60 seconds.
  #
  # `{:refused, :not_listed}` stays reserved for where the venue actually SAYS so: a 400,
  # 401, 403 or 404 with a body, handled by `refusal/2` below on the HTTP status rather
  # than on the shape of a 200. Those genuine statements (e.g. `{:venue_error, 400,
  # "Invalid symbol: ALGO-USD"}`) were the other 27 of the 83 and are unaffected by this.
  #
  # The row is the one naming the symbol asked for, not merely the first. Both callers
  # label the answer with the REQUESTED symbol, so a reordered or unfiltered `results`
  # published another pair's bid/ask, or its increments, under this one's name. A row that
  # names a different symbol is not this symbol's answer; a row that names none is taken
  # only when it is the sole row, which is what a filtered single-symbol request returns.
  defp result_for(%{"results" => []}, _native), do: {:error, :empty_result}

  defp result_for(%{"results" => rows}, native) when is_list(rows) do
    case Enum.find(rows, &match?(%{"symbol" => ^native}, &1)) do
      nil -> unnamed_sole_row(rows)
      row -> {:ok, row}
    end
  end

  defp result_for(_other, _native), do: {:error, :unexpected_response_shape}

  defp unnamed_sole_row([row]) when is_map(row) and not is_map_key(row, "symbol"),
    do: {:ok, row}

  defp unnamed_sole_row(_rows), do: {:error, :symbol_not_in_response}

  defp venue_time(row) do
    case row["timestamp"] do
      nil -> {:error, :missing_venue_timestamp}
      "" -> {:error, :missing_venue_timestamp}
      raw -> parse_time(raw)
    end
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      _not_iso ->
        case Integer.parse(value) do
          {epoch, ""} -> from_epoch(epoch)
          _other -> {:error, {:unparseable_venue_timestamp, value}}
        end
    end
  end

  defp parse_time(value) when is_integer(value), do: from_epoch(value)
  defp parse_time(other), do: {:error, {:unparseable_venue_timestamp, other}}

  # Ten digits is seconds, thirteen is milliseconds. A threshold rather than a fallback:
  # guessing wrong puts a 2026 quote in 1970 or in the year 58,000, and both are loud.
  # Non-positive is refused before the unit question is even asked.
  #
  # `DateTime.from_unix/2` answers `{:ok, ~U[1970-01-01 00:00:00Z]}` for 0 and a 1969 instant
  # for negatives — valid `DateTime`s, which is exactly why they are the dangerous case.
  # `0` is a common venue sentinel for "unknown", and the comment below calls 1970 "loud"
  # while it is not: a consumer computing an age gets fifty-six years and may well skip the
  # row, but one that logs or charts the timestamp shows 1970 and calls it data. The family
  # settled this for level timestamps — "an unreadable level timestamp does not become the
  # epoch" — and the same answer applies wherever an epoch is converted.
  #
  # `{:error, :invalid_unix_time}` is the shape an out-of-range value already produces here,
  # so every caller handles it unchanged.
  defp from_epoch(value) when value <= 0, do: {:error, :invalid_unix_time}

  defp from_epoch(value) when value > 100_000_000_000, do: DateTime.from_unix(value, :millisecond)
  defp from_epoch(value), do: DateTime.from_unix(value)

  defp refusal(status, body) do
    case refusal_body(body) do
      %{"detail" => detail} when is_binary(detail) -> {:venue_error, status, detail}
      %{"errors" => [%{"detail" => detail} | _rest]} -> {:venue_error, status, detail}
      _other -> {:venue_error, status}
    end
  end

  # A 2xx body this package cannot decode is NOT an empty object.
  #
  # This used to collapse any unparseable body to `%{}` and hand it on as success. Nothing
  # downstream could tell that apart from a real but sparse response: `%{}` flows into
  # `order_struct/1`, `to_balance/2` and `to_top_of_book/2` and comes out as a well-formed
  # struct with every field `nil`, returned as `{:ok, value}`. The realistic way to get
  # there is not malformed JSON from the venue but a `200` that is not the venue at all —
  # an interstitial, a captive portal, or a CDN maintenance page, all of which answer `200`
  # with HTML. A caller polling balances through one of those was told, truthfully-looking,
  # that it held nothing.
  #
  # Refuse instead. `refusal_body/1` below stays lenient on purpose, for a body being read
  # for a different reason.
  defp decoded_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, {:undecodable_response, :robinhood}}
    end
  end

  defp decoded_body(body), do: {:ok, body}

  # Deliberately lenient, unlike `decoded_body/1`. A refusal's body is read for a
  # human-readable reason and "there wasn't one in it" is an honest answer — the refusal
  # itself is already established by the status code, so collapsing an unparseable body to
  # `%{}` here loses nothing and `{:venue_error, status}` remains true. On a 2xx body the
  # identical collapse invents a success, which is the whole difference.
  defp refusal_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{}
    end
  end

  defp refusal_body(body), do: body

  defp decimal(nil), do: nil
  defp decimal(""), do: nil
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  # `Decimal.new/1` raises on a string that is not a number. `Decimal.parse/1`, requiring
  # the whole string be consumed (`{d, ""}`), is the family's established idiom for this.
  # `Decimal.parse/1` requiring the whole string be consumed is NOT a sufficient guard on
  # its own, which is the half this copy was missing. "NaN", "Inf" and "-Inf" all parse
  # fully and case-insensitively — `"-nan"` and `"inf"` too — so each arrived here as a
  # perfectly well-formed `Decimal` and flowed onward as a real price.
  #
  # That is worse than the raise this parse replaced, and it fails a long way from the
  # cause. Measured: `Decimal.add(nan, 1)` is NaN, so it poisons a consumer's arithmetic
  # silently; `Decimal.compare(nan, _)` RAISES `invalid_operation: operation on NaN`, in
  # the consumer's own process, with a message naming Decimal rather than the venue that
  # sent it. An Infinity is quieter still — it compares greater than everything and never
  # raises at all.
  #
  # `dp_exchange_webull` found this and guarded both of its own copies; the other four
  # venues guarded none of their nine. Fixed where it was found, not where it applied —
  # which is why this comment is in each of them now rather than one of them.
  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {parsed, ""} ->
        if Decimal.nan?(parsed) or Decimal.inf?(parsed), do: nil, else: parsed

      _unparsable ->
        nil
    end
  end

  defp decimal(_other), do: nil
end
