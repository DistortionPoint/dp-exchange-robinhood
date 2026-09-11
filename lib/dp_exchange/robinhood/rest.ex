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

  alias DpExchange.Core.{HttpClient, Instrument}
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
  def base_url(opts), do: Keyword.get(opts, :base_url, @base_url)

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
         {:ok, row} <- first_result(body) do
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
    with {:ok, rows} <- walk(@trading_pairs_path, credentials, opts, [], 0, []) do
      {:ok,
       rows
       |> Enum.map(& &1["symbol"])
       |> Enum.reject(&is_nil/1)
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
    with {:ok, rows} <- walk(@trading_pairs_path, credentials, opts, [], 0, []) do
      {:ok,
       rows
       |> Enum.reject(&is_nil(&1["symbol"]))
       |> Enum.map(&to_instrument/1)}
    end
  end

  defp to_instrument(row) do
    Instrument.new(
      symbol: SymbolFormat.to_canonical_symbol(row["symbol"]),
      base: row["asset_code"],
      quote: row["quote_code"],
      instrument: :spot,
      status: instrument_status(row["status"])
    )
  end

  # `Core.Instrument.status_from/1` recognises the vocabulary Coinbase and Gemini send
  # (`online`, `open`, `closed`, ...); this venue's own `V2TradingPair` schema sends
  # `"tradable"` for a listed pair — a different word for the same state, not a gap in
  # `status_from/1`, so it is read directly here instead. Anything other than the one
  # value this package has actually seen is `:unknown` rather than assumed `:delisted`:
  # a status string never seen on this venue must not manufacture a delisting nothing
  # said.
  defp instrument_status("tradable"), do: :tradable
  defp instrument_status(_other), do: :unknown

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
         {:ok, row} <- first_result(body) do
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

  # Bounds the `trading_pairs` pagination walk, matching `dp_exchange_coinbase`'s
  # `@max_account_pages`/`@max_fill_pages` and `dp_exchange_webull`'s `@max_pages` — this
  # was the one venue in the family walking a cursor with no page bound at all.
  #
  # **The cycle guard below does not cover this, and that is the whole point.** `seen`
  # catches a venue that hands back a path it already gave us; it cannot catch one that
  # hands back a NEW path every time (`?cursor=1`, `?cursor=2`, …), because no path ever
  # repeats. A venue-side defect of that shape would walk forever, holding a caller and a
  # rate-limit budget with it. Fifty pages is the family's figure, not a measured one for
  # this venue — Robinhood Crypto lists on the order of a hundred pairs, so this is roughly
  # two orders of magnitude of headroom.
  @max_pages 50

  # Collects raw `trading_pairs` rows across every page — `get_symbols/2` and
  # `list_instruments/2` each map the same rows to what they need, rather than this
  # walk deciding ahead of time which fields anyone wants.
  #
  # Fails closed on the bound rather than returning what it has: a truncated catalogue
  # answered as `{:ok, rows}` is a partial list presented as complete, which is the
  # "nearby substitute where an error belongs" failure this family keeps paying for. Every
  # other venue's pagination bound in this family answers the same way.
  defp walk(_path, _credentials, _opts, _pages, page, _seen) when page >= @max_pages,
    do: {:error, :too_many_trading_pair_pages}

  defp walk(path, credentials, opts, pages, page, seen) do
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
            next -> walk(next, credentials, opts, pages, page + 1, [path | seen])
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
      {:ok, body |> account_rows() |> List.wrap()}
    end
  end

  defp account_rows(%{"results" => rows}) when is_list(rows), do: rows
  defp account_rows(%{} = row), do: [row]
  defp account_rows(_other), do: []

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
  """
  @spec get_balances(map(), keyword()) ::
          {:ok, [Balance.t()]} | {:error, term()} | {:refused, term()}
  def get_balances(credentials, opts) do
    with {:ok, account} <- required_account(opts) do
      query =
        [{"account_number", account}] ++
          Enum.map(List.wrap(Keyword.get(opts, :asset_codes, [])), &{"asset_code", &1})

      path = "/api/v2/crypto/trading/holdings/" <> query_string(query)
      asked_at = DateTime.utc_now()

      with {:ok, body} <- get(path, credentials, opts) do
        {:ok, body |> account_rows() |> Enum.map(&to_balance(&1, asked_at))}
      end
    end
  end

  defp to_balance(row, asked_at) do
    total = decimal(row["total_quantity"])
    available = decimal(row["quantity_available_for_trading"])

    %Balance{
      currency: row["asset_code"],
      balance: total,
      available_balance: available,
      # The venue publishes no hold figure. Subtracting would produce a number it never
      # stated, and one that is wrong the moment either side is missing.
      hold: nil,
      timestamp: asked_at,
      provider: :robinhood
    }
  end

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

  # Full notation, never scientific: `1.0e-4` is not a quantity this venue reads.
  defp decimal_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal_string(value), do: to_string(value)

  @doc """
  Orders on one account — `GET /api/v2/crypto/trading/orders/`.

  `opts[:account_number]` is required by v2. `opts[:created_at_start]` and the venue's other
  filters are passed through under its own names, and none is defaulted — a start date
  chosen here would return a real list of orders over a window the caller did not ask about.

  This does **not** page. The venue returns a cursor and `get_symbols/2` walks one for the
  catalogue; an order list is a different case — a caller filtering by date wants the page
  it asked for, and following the cursor silently would fetch a history it did not.
  `opts[:cursor]` continues where the caller decides to.
  """
  @spec get_orders(map(), keyword()) ::
          {:ok, [Order.t()]} | {:error, term()} | {:refused, term()}
  def get_orders(credentials, opts) do
    with {:ok, account} <- required_account(opts) do
      query =
        [{"account_number", account}]
        |> put_query("created_at_start", Keyword.get(opts, :created_at_start))
        |> put_query("created_at_end", Keyword.get(opts, :created_at_end))
        |> put_query("symbol", order_symbol(Keyword.get(opts, :symbol)))
        |> put_query("state", Keyword.get(opts, :state))
        |> put_query("cursor", Keyword.get(opts, :cursor))

      path = "/api/v2/crypto/trading/orders/" <> query_string(query)

      with {:ok, body} <- get(path, credentials, opts) do
        body |> account_rows() |> to_orders()
      end
    end
  end

  @doc """
  One order — `GET /api/v2/crypto/trading/orders/{order_id}/`.

  `opts[:account_number]` is required by v2.
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
         "client_order_id" => Keyword.get(opts, :client_order_id, generate_client_order_id()),
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
  defp to_order(row) when is_map(row), do: {:ok, order_struct(row)}
  defp to_order(_row), do: {:error, :unexpected_response_shape}

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
      quantity: decimal(row["filled_asset_quantity"] || configured_quantity(row)),
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

  defp order_canonical(nil), do: nil
  defp order_canonical(symbol), do: SymbolFormat.to_canonical_symbol(symbol)

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

    with {:ok, headers} <- Auth.headers("POST", path, encoded, credentials, opts) do
      url = base_url(opts) <> path

      case HttpClient.request(:post, url, headers, encoded, request_opts(opts)) do
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
  end

  # --- request ------------------------------------------------------------

  defp get(path, credentials, opts) do
    with {:ok, headers} <- Auth.headers("GET", path, "", credentials, opts) do
      url = base_url(opts) <> path

      case HttpClient.request(:get, url, headers, nil, request_opts(opts)) do
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
  defp first_result(%{"results" => [row | _rest]}) when is_map(row), do: {:ok, row}
  defp first_result(%{"results" => []}), do: {:error, :empty_result}
  defp first_result(_other), do: {:error, :unexpected_response_shape}

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
