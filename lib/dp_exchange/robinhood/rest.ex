defmodule DpExchange.Robinhood.Rest do
  @moduledoc """
  Robinhood Crypto's REST surface — internal.

  ## Every call is signed, including the quotes

  There is no anonymous endpoint here. `best_bid_ask` needs the same Ed25519 signature as
  an order, which is why this venue declares `credential_benefit: :required` and why
  `get_top_of_book/3` takes credentials.

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
  @host "trading.robinhood.com"
  @loopback_hosts ["localhost", "127.0.0.1", "::1", "[::1]"]
  @trading_pairs_path "/api/v2/crypto/trading/trading_pairs/"
  @accounts_path "/api/v2/crypto/trading/accounts/"

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

  @doc """
  Base URL, overridable for tests. Every request is signed, so it must be `https` with a
  host (a loopback host may use `http` for a local stub); anything else is refused before
  anything is signed, as `{:error, {:insecure_base_url, scheme}}` or `{:error,
  {:invalid_base_url, :not_a_string}}`.
  """
  @spec base_url(keyword()) :: term()
  def base_url(opts), do: Config.opt(opts, :base_url, @base_url)

  # **Every call here is signed, so every call carries `x-api-key` and a live signature.**
  # `:base_url` is a consumer option (and a `Config` seam), and it was concatenated into the
  # request URL unchecked: `base_url: "http://..."` sent the api key, the signature and an
  # order body in cleartext, and a non-string raised inside the caller's process. Fail
  # closed: the scheme must be `https` with a host. The one exception is a loopback host
  # (`localhost`, `127.0.0.1`, `::1`) over `http`, which is the documented seam for a local
  # stub server and never leaves the machine. The refusal names the scheme only, never the
  # URL: a consumer may have put userinfo in it.
  defp secure_base_url(opts) do
    case base_url(opts) do
      url when is_binary(url) -> check_base_uri(URI.parse(url), url)
      _not_a_string -> {:error, {:invalid_base_url, :not_a_string}}
    end
  end

  # The trailing slash is trimmed because the signed path starts with one: `base <> path`
  # would send `//api/...` while the signature covers `/api/...`.
  defp check_base_uri(%URI{scheme: "https", host: host}, url)
       when is_binary(host) and host != "",
       do: {:ok, String.trim_trailing(url, "/")}

  defp check_base_uri(%URI{scheme: "http", host: host}, url) when host in @loopback_hosts,
    do: {:ok, String.trim_trailing(url, "/")}

  defp check_base_uri(%URI{scheme: scheme}, _url),
    do: {:error, {:insecure_base_url, scheme}}

  @doc """
  Best bid and ask for `symbol` — the top of the book, not a traded price.

  Reads v2's `best_bid_ask`, the only quote-adjacent endpoint this venue serves. **v2's
  response (`V2BestBidAsk`) is three fields: `symbol`, `bid`, `ask`** — not v1's
  spread-inclusive names, and no `timestamp`. Carried as sent rather than adjusted back to
  a raw book.

  This is the whole of what `best_bid_ask` gives: no trade price. See the moduledoc on why
  there is no `get_price/3` reading this same payload, and on the v1/v2 field-name defect
  this function used to carry.

  **`nil` on a side means the venue says there is no order there.** A `bid` or `ask` of `0`
  is that, and so is an absent or `null` side. A side that is present but unreadable (empty
  string, NaN, non-number, negative) is `{:error, {:invalid_decimal, :bid | :ask, value}}`;
  neither key at all is `{:error, {:missing_required_field, :bid_ask}}`.

  One symbol, one signed request. See `get_top_of_book_bulk/3` for the repeatable-`symbol`
  form this endpoint also serves, which `Feed` uses as its normal path and falls back to
  this function per symbol only when the bulk call is itself refused.
  """
  @spec get_top_of_book(String.t(), map(), keyword()) ::
          {:ok, TopOfBook.t()} | {:error, term()} | {:refused, term()}
  def get_top_of_book(symbol, credentials, opts) do
    # A symbol that is not a non-empty string is refused before anything is signed;
    # `SymbolFormat` raised on it in the caller's process, and `""` built `symbol=`.
    with {:ok, native} <- native_symbol(symbol) do
      # `query_string/1`, not `URI.encode/1`: that leaves `&`, `=`, `#` and `/` alone, so a
      # symbol like `"BTC-USD&symbol=ETH-USD"` smuggled a second parameter into a SIGNED path.
      path = "/api/v2/crypto/marketdata/best_bid_ask/" <> query_string([{"symbol", native}])

      with {:ok, body} <- get(path, credentials, opts),
           {:ok, row} <- result_for(body, native) do
        to_top_of_book(SymbolFormat.to_canonical_symbol(native), row)
      end
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
  nothing that would turn silence into a statement (see the comment on `result_for/2` for the
  same principle on the single-symbol path, and DpCryptoManagement issue #25 for what
  mistaking the two costs). A row naming a symbol that was not asked for is dropped, and a
  symbol answered twice is returned once (its first readable row).

  More than `max_bulk_symbols/0` distinct symbols is refused as
  `{:error, {:too_many_symbols, cap}}` before anything is signed; `Feed` chunks to the cap.

  An empty `symbols` list returns `{:ok, []}` without a network call: the venue's own
  document does not say what a `best_bid_ask` request carrying no `symbol` parameter at all
  does, and there is nothing to ask for.
  """
  @spec get_top_of_book_bulk([String.t()], map(), keyword()) ::
          {:ok, [TopOfBook.t()]} | {:error, term()} | {:refused, term()}
  def get_top_of_book_bulk([], _credentials, _opts), do: {:ok, []}

  def get_top_of_book_bulk(symbols, credentials, opts) do
    with {:ok, natives} <- native_symbols(symbols),
         :ok <- within_bulk_cap(natives) do
      path = "/api/v2/crypto/marketdata/best_bid_ask/" <> query_string(natives)

      with {:ok, body} <- get(path, credentials, opts),
           {:ok, rows} <- bulk_rows(body) do
        {:ok, answered_books(rows, natives)}
      end
    end
  end

  # Only the symbols asked for, each once. A row for a symbol that was not requested is not
  # an answer to this call (a caller keying on the result would publish it under a name it
  # never subscribed), and a symbol the venue answers twice is published once, as its first
  # readable row, rather than as two books that may disagree. One pass, one `MapSet`.
  defp answered_books(rows, natives) do
    asked =
      MapSet.new(natives, fn {"symbol", native} -> SymbolFormat.to_canonical_symbol(native) end)

    {books, _seen} =
      Enum.reduce(rows, {[], MapSet.new()}, fn row, {books, seen} = acc ->
        case row_to_top_of_book(row) do
          %TopOfBook{symbol: symbol} = book ->
            if MapSet.member?(asked, symbol) and not MapSet.member?(seen, symbol),
              do: {[book | books], MapSet.put(seen, symbol)},
              else: acc

          nil ->
            acc
        end
      end)

    Enum.reverse(books)
  end

  # The vendor states no maximum number of `symbol` parameters (nothing measured), and the
  # whole query string is part of the SIGNED path, so an unbounded list is an unbounded URL
  # (about 20 bytes a symbol: 1,000 symbols is a 20 KB request line, which proxies and CDNs
  # commonly refuse with a 414/431 that would then be bisected as if a symbol were at fault).
  # This is OUR conservative cap, not the venue's: about 2 KB of query at the longest pairs.
  # `Feed` chunks to it; a direct caller over it is refused rather than sent.
  @max_bulk_symbols 100

  @doc """
  The most symbols one `get_top_of_book_bulk/3` request carries: 100.

  A conservative cap of this package's own choosing. The vendor publishes no maximum and
  none has been measured; the cap keeps the signed URL near 2 KB. `Feed` splits a larger
  universe into requests of at most this many symbols.
  """
  @spec max_bulk_symbols() :: pos_integer()
  def max_bulk_symbols, do: @max_bulk_symbols

  defp within_bulk_cap(natives) when length(natives) <= @max_bulk_symbols, do: :ok
  defp within_bulk_cap(_natives), do: {:error, {:too_many_symbols, @max_bulk_symbols}}

  # Every symbol is a non-empty string, or the whole call is refused; a repeated symbol is
  # asked for once.
  defp native_symbols(symbols) when is_list(symbols) do
    if proper_list?(symbols), do: native_symbols_checked(symbols), else: invalid_symbols(symbols)
  end

  defp native_symbols(not_a_list), do: invalid_symbols(not_a_list)

  defp invalid_symbols(value), do: {:error, {:invalid_symbols, value}}

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_improper), do: false

  defp native_symbols_checked(symbols) do
    symbols
    |> Enum.reduce_while({:ok, []}, fn symbol, {:ok, acc} ->
      case native_symbol(symbol) do
        {:ok, native} -> {:cont, {:ok, [native | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, natives} ->
        {:ok, natives |> Enum.reverse() |> Enum.uniq() |> Enum.map(&{"symbol", &1})}

      error ->
        error
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
  #
  # A row whose bid AND ask both fail to decode is dropped the same way, for the same
  # reason: it would be published as a well-formed book with no prices.
  defp row_to_top_of_book(%{"symbol" => symbol} = row) when is_binary(symbol) do
    case to_top_of_book(SymbolFormat.to_canonical_symbol(symbol), row) do
      {:ok, book} -> book
      {:error, _unreadable} -> nil
    end
  end

  defp row_to_top_of_book(_row), do: nil

  # Found 2026-10-10 by reading the path: nothing checked that `bid` or `ask` was readable.
  # A renamed field (v1's names against the v2 path were exactly this once), an empty string
  # or a `NaN` all decode to `nil`, and the result was a `TopOfBook{bid: nil, ask: nil}`
  # delivered as `{:ok, _}` — an empty book that reads as a quiet market rather than a
  # parser that has stopped understanding the venue. Both sides unreadable is refused; one
  # side is a real one-sided book and is still returned.
  #
  # **Tick R (MD6): `nil` means the venue said there is no order, and nothing else.** A bid or
  # ask of `0` is no resting order on that side (`nil`). A side that is PRESENT but cannot be
  # read - a non-number, an empty string, NaN, a negative - refuses the book as
  # `{:error, {:invalid_decimal, :bid | :ask, value}}`; it used to become `nil`, which
  # `TopOfBook` reads as "no resting order", a statement the venue never made. A side that is
  # absent or `null` is `nil`; with BOTH absent the row names no book at all and is refused as
  # before. (In `get_top_of_book_bulk/3` a refused row is dropped, like any unreadable row:
  # that symbol is uncovered this cycle and the rest of the batch is unaffected.)
  defp to_top_of_book(symbol, row) do
    with {:ok, bid} <- book_side(row["bid"], :bid),
         {:ok, ask} <- book_side(row["ask"], :ask),
         :ok <- stated_book(row) do
      {:ok,
       %TopOfBook{
         symbol: symbol,
         bid: bid,
         ask: ask,
         bid_size: nil,
         ask_size: nil,
         venue_time: top_of_book_time(row),
         observed_at: DateTime.utc_now(),
         provider: :robinhood
       }}
    end
  end

  defp book_side(nil, _side), do: {:ok, nil}

  defp book_side(raw, side) do
    case decimal(raw) do
      nil -> {:error, {:invalid_decimal, side, bounded_raw(raw)}}
      price -> side_price(Decimal.compare(price, 0), price, raw, side)
    end
  end

  defp side_price(:gt, price, _raw, _side), do: {:ok, price}
  defp side_price(:eq, _price, _raw, _side), do: {:ok, nil}

  defp side_price(:lt, _price, raw, side),
    do: {:error, {:invalid_decimal, side, bounded_raw(raw)}}

  # The venue's value, quoted into an error tuple: a short one comes back as sent, anything
  # long is cut so a hostile or broken reply cannot ride the error into every log.
  defp bounded_raw(raw) when is_binary(raw) and byte_size(raw) <= 64, do: raw
  defp bounded_raw(raw) when is_number(raw), do: raw
  defp bounded_raw(raw), do: inspect(raw, limit: 10, printable_limit: 64)

  defp stated_book(row) do
    if is_nil(row["bid"]) and is_nil(row["ask"]),
      do: {:error, {:missing_required_field, :bid_ask}},
      else: :ok
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
  #
  # **A blank symbol is no symbol.** `"symbol": ""` (or whitespace) used to be published as a
  # catalogue entry, `""`, which no call can ask about and every consumer then keys on.
  defp row_symbol(%{"symbol" => symbol, "is_api_tradable" => false}) when is_binary(symbol),
    do: []

  defp row_symbol(%{"symbol" => symbol}) when is_binary(symbol),
    do: if(String.trim(symbol) == "", do: [], else: [symbol])

  defp row_symbol(_row), do: []

  # `list_instruments/2`'s own row filter — deliberately NOT `row_symbol/1`, which also
  # excludes an `is_api_tradable: false` row for `get_symbols/2`'s purpose. This callback
  # keeps that row (see `row_symbol/1`'s comment) and only needs to know a usable symbol is
  # present at all.
  defp has_symbol?(%{"symbol" => symbol}) when is_binary(symbol),
    do: String.trim(symbol) != ""

  defp has_symbol?(_row), do: false

  defp to_instrument(row) do
    Instrument.new(
      symbol: SymbolFormat.to_canonical_symbol(row["symbol"]),
      base: code_or_nil(row["asset_code"]),
      quote: code_or_nil(row["quote_code"]),
      instrument: :spot,
      status: instrument_status(row)
    )
  end

  # `Core.Instrument`'s `base` and `quote` are `String.t() | nil`. A code that is a number, a
  # map or a blank string is not one, and used to ride into the struct as sent.
  defp code_or_nil(code) when is_binary(code) do
    if String.trim(code) == "", do: nil, else: code
  end

  defp code_or_nil(_not_a_code), do: nil

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
    with {:ok, native} <- native_symbol(symbol) do
      path = @trading_pairs_path <> query_string([{"symbol", native}])

      with {:ok, body} <- get(path, credentials, opts),
           {:ok, row} <- result_for(body, native) do
        to_quantization(row)
      end
    end
  end

  # Found 2026-10-10 by reading the path: a row whose `quote_increment` AND `asset_increment`
  # were both unreadable (renamed, empty, `NaN`) answered `{:ok, %{price_increment: nil,
  # quantity_increment: nil, ...}}` -- rounding rules that state no rounding at all, which a
  # caller reads as "any precision is accepted". One unreadable increment is still returned
  # as `nil` (the other is real); both unreadable means the parser has stopped understanding
  # the row, and is refused.
  defp to_quantization(row) do
    price_increment = positive_decimal(row["quote_increment"])
    quantity_increment = positive_decimal(row["asset_increment"])

    if is_nil(price_increment) and is_nil(quantity_increment) do
      {:error, {:missing_required_field, :increments}}
    else
      {:ok,
       %{
         price_increment: price_increment,
         quantity_increment: quantity_increment,
         # The schema names no unit minimum — see the moduledoc above.
         min_quantity: nil,
         max_quantity: positive_decimal(row["max_order_size"]),
         min_quote_size: non_negative_decimal(row["min_order_amount"]),
         status: if(is_binary(row["status"]), do: row["status"])
       }}
    end
  end

  # **A rounding rule or a size bound is a positive number, or it is not stated.** An
  # increment of `0` is a division by zero for the first caller that rounds to it, a negative
  # one rounds the wrong way, and a `max_order_size` of `-5` or `0` is a bound nothing can
  # satisfy. All of them decoded as the number the venue sent; each is `nil` ("unreadable")
  # here, the same as `NaN` or an empty string.
  defp positive_decimal(raw) do
    case decimal(raw) do
      %Decimal{} = value -> if Decimal.positive?(value), do: value
      nil -> nil
    end
  end

  # A cash minimum may honestly be zero ("no minimum"); it may not be negative.
  defp non_negative_decimal(raw) do
    case decimal(raw) do
      %Decimal{} = value -> if Decimal.negative?(value), do: nil, else: value
      nil -> nil
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
      with {:ok, body} <- get(path, credentials, opts),
           {:ok, results} <- page_results(body),
           {:ok, next} <- next_page(body, path, opts) do
        # Pages are accumulated as a list OF PAGES and concatenated once at the end.
        # This was `acc ++ results`, which copies the whole accumulator on every page —
        # quadratic in the number of rows, for a walk whose entire job is to grow a list.
        # `seen` stays a plain list: the scan is linear, but @max_pages now bounds it at
        # 50 entries, so a MapSet buys nothing measurable — and it cost a dialyzer opacity
        # warning, which is a worse trade than the scan it removed.
        pages = [results | pages]

        case next do
          nil -> {:ok, pages |> Enum.reverse() |> Enum.concat()}
          next -> walk(next, credentials, opts, pages, page + 1, [path | seen], too_many_error)
        end
      end
    end
  end

  # `"results": null` is an empty page, the same convention `account_rows/1` and
  # `order_rows/1` both give their own single-page endpoints — carried here so a WALKED
  # endpoint (holdings) reads a null page identically rather than refusing a page that said
  # nothing was wrong. Anything else that is not a list is not a page.
  defp page_results(%{"results" => results}) when is_list(results), do: {:ok, results}
  defp page_results(%{"results" => nil}), do: {:ok, []}
  defp page_results(_unexpected), do: {:error, :unexpected_response_shape}

  # The venue returns an absolute URL for the next page; the signature covers a path, so
  # only the path-and-query part is carried forward, and it is requested from THIS
  # package's own base URL -- never from the host the cursor names.
  #
  # **A cursor is the venue's word, and it is checked before it is followed.** Three ways
  # it used to go wrong, each reachable from a response body alone:
  #
  #   * A `next` on another host was followed anyway, with its path silently re-homed onto
  #     the base URL. Not a request to the foreign host, but not the walk the venue
  #     described either: the page fetched was one nobody offered. Refused instead.
  #   * A `next` with no path (`"?cursor=2"`, or a bare host) raised in `<>` on `nil`, inside
  #     the caller's process. Refused instead.
  #   * A `next` that was present but not a string (a number, an object) was treated as "no
  #     more pages", so a truncated list came back as complete. `nil` and `""` are the only
  #     spellings of "no more"; anything else is unreadable.
  #
  # The host must be the configured base URL's or the venue's own (`trading.robinhood.com`,
  # which is what the venue's cursors actually name when a test or proxy overrides the base).
  defp next_path(%{"next" => next}, opts) when is_binary(next) and next != "" do
    with {:ok, %URI{path: path, query: query}} <- cursor_uri(URI.parse(next), opts),
         :ok <- cursor_path(path),
         :ok <- cursor_query(query) do
      {:ok, if(query, do: path <> "?" <> query, else: path)}
    end
  end

  defp next_path(%{"next" => next}, _opts) when next in [nil, ""], do: {:ok, nil}
  defp next_path(%{"next" => _unreadable}, _opts), do: {:error, :unexpected_response_shape}
  defp next_path(_no_next_key, _opts), do: {:ok, nil}

  # The query is the cursor, and it goes into a SIGNED request line. It is printable ASCII
  # with no whitespace, within 2 KB, or it is not one this package will put on the wire: a
  # space, a control character or a megabyte of text is the venue's bug (or a hostile reply),
  # not a page to follow.
  @max_cursor_query 2_048

  defp cursor_query(nil), do: :ok

  defp cursor_query(query) do
    if byte_size(query) <= @max_cursor_query and String.match?(query, ~r/\A[\x21-\x7E]*\z/),
      do: :ok,
      else: {:error, :unexpected_response_shape}
  end

  # **A cursor continues THE SAME endpoint.** A `next` naming `/api/` somewhere else (holdings
  # from an orders walk, say) used to be followed, and its rows were decoded as the wrong
  # kind: balances out of order rows, or worse rows that happen to decode. Nothing in the
  # vendor's pagination description allows it ("the API request endpoint that includes the
  # next cursor"), so a different path is refused rather than followed. Only the path is
  # compared; the query is the cursor.
  defp next_page(body, current, opts) do
    with {:ok, next} <- next_path(body, opts), do: same_endpoint(next, current)
  end

  defp same_endpoint(nil, _current), do: {:ok, nil}

  defp same_endpoint(next, current) do
    if path_only(next) == path_only(current),
      do: {:ok, next},
      else: {:error, {:unexpected_next_path, path_only(next)}}
  end

  defp path_only(path_and_query), do: path_and_query |> String.split("?", parts: 2) |> hd()

  defp cursor_uri(%URI{host: nil} = uri, _opts), do: {:ok, uri}

  defp cursor_uri(%URI{host: host} = uri, opts) do
    if host in [@host, URI.parse(base_url(opts)).host],
      do: {:ok, uri},
      else: {:error, {:foreign_next_url, bounded_raw(host)}}
  end

  defp cursor_path("/api/" <> _rest), do: :ok
  defp cursor_path(path), do: {:error, {:unexpected_next_path, path}}

  # --- accounts, holdings and trading (v2) --------------------------------

  @doc """
  The crypto trading account — `GET /api/v2/crypto/trading/accounts/`.

  **The account number this returns is a parameter on almost everything else.** v2 takes
  `account_number` as a query parameter on holdings, on the order list, on one order, and on
  placing one — where v1 took none. A caller that skipped this call has nothing to address
  those with.

  Returned as the venue's own map.

  **Walks `next` when the venue offers one.** `V2AccountsResponse` carries the same cursor
  fields the trading-pairs response does. This used to read the first page only, recorded as
  a decision ("one account per credential is the common case"). That decision was wrong in
  the way that matters: `get_balances/2` finds its account by number in this list, so an
  account on page two read as `{:error, {:account_not_found, _}}` -- and `get_accounts/2`
  itself answered a truncated list as the complete one. Pages after the first are fetched
  with the same bounded, loop-guarded, host-checked `walk/7` as every other cursor here, and
  fail closed (`{:error, :too_many_account_pages}`) on the bound.
  """
  @spec get_accounts(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_accounts(credentials, opts) do
    with {:ok, body} <- get(@accounts_path, credentials, opts),
         {:ok, rows} <- account_rows(body),
         {:ok, more} <- remaining_account_rows(body, credentials, opts) do
      all_accounts(rows ++ more)
    end
  end

  # `[map()]` is the contract, and an account is a row that NAMES one (as the bare-object
  # clause of `account_rows/1` already requires). A number, a string or an object with no
  # account number is not an account, and was handed to the caller inside `{:ok, accounts}`
  # for it to raise on, or to pass an absent number on to every account-scoped call.
  defp all_accounts(rows) do
    if Enum.all?(rows, &named_account?/1),
      do: {:ok, rows},
      else: {:error, :unexpected_response_shape}
  end

  defp named_account?(%{"account_number" => number}), do: is_binary(number) and number != ""
  defp named_account?(_row), do: false

  defp remaining_account_rows(body, credentials, opts) do
    case next_page(body, @accounts_path, opts) do
      {:ok, nil} ->
        {:ok, []}

      {:ok, next} ->
        walk(next, credentials, opts, [], 1, [@accounts_path], :too_many_account_pages)

      error ->
        error
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
  # A bare object is an account only if it NAMES one. `V2AccountsResponse` is always a page,
  # so a bare object is already off-spec; `{}` or an error-shaped `{"detail": ...}` answered
  # with a 200 became `{:ok, [%{}]}` -- a phantom account, whose absent number a caller then
  # fails to find (or worse, passes on to every account-scoped call).
  defp account_rows(%{"account_number" => number} = row) when is_binary(number) and number != "",
    do: {:ok, [row]}

  defp account_rows(_other), do: {:error, :unexpected_response_shape}

  @doc """
  Crypto holdings — `GET /api/v2/crypto/trading/holdings/`.

  `opts[:account_number]` is **required by v2** and refused here when missing rather than
  sent: v1 took none and answered for the credential's own account, so a call without one
  is a v1 habit that v2 will not honour.

  **Total and available, kept apart.** The venue publishes `total_quantity` and
  `quantity_available_for_trading`; the difference is a balance that is real and not
  tradable (for example, sitting in an open order). `Types.Balance` carries them as
  `balance` and `available_balance`. **`hold` is always `nil`**: the venue publishes no hold
  figure, and subtracting one from the other would state a number it never sent.

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
    with {:ok, account} <- required_account(opts),
         {:ok, asset_codes} <- asset_codes(opts) do
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

  @doc """
  The `opts[:asset_codes]` narrowing as a list, or `{:error, {:invalid_field, :asset_codes}}`
  when any entry is not a non-blank string. `get_balances/2` sends each as an `asset_code`
  query parameter; a `nil` or a map in the list used to become `asset_code=` (or raise
  inside the query encoder) on a signed request. A single string is a one-entry list and
  absence is `[]`. Exposed so `DpExchange.Robinhood.Fake` refuses the same.
  """
  @spec asset_codes(keyword()) :: {:ok, [String.t()]} | {:error, {:invalid_field, :asset_codes}}
  def asset_codes(opts) do
    codes = List.wrap(Config.opt(opts, :asset_codes, []))

    if Enum.all?(codes, &(is_binary(&1) and String.trim(&1) != "")),
      do: {:ok, codes},
      else: {:error, {:invalid_field, :asset_codes}}
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

  **Refused locally, before anything is signed:** a `side` outside `bid`/`ask`/`both`
  (atom or string), a `quantity` that is not a positive finite number (zero, negative, `NaN`,
  `Infinity`, unparseable text, an empty list) as `{:error, {:invalid_field, :quantity}}`,
  and a `symbol` that is not a string. Each used to go on the wire as whatever `to_string/1`
  made of it.

  **The numeric fields of each result row come back as `Decimal`, not float.** The venue
  sends `quantity`, `bid`, `ask`, `fee_ratio`, `est_fee`, `est_total_cost` and
  `est_total_credit` as JSON numbers, which decode to floats -- money in binary floating
  point. A float is converted with `Decimal.from_float/1`, which is the shortest decimal that
  round-trips, so the value is the one on the wire. Every other key is returned as sent.
  """
  @spec get_estimated_price(
          String.t(),
          atom() | String.t(),
          Decimal.t() | number() | String.t() | [Decimal.t() | number() | String.t()],
          map(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_estimated_price(symbol, side, quantity, credentials, opts) do
    with {:ok, native} <- native_symbol(symbol),
         {:ok, side} <- estimate_side(side),
         {:ok, quantity} <- quantity_param(quantity),
         path = estimate_path(native, side, quantity),
         {:ok, body} <- get(path, credentials, opts) do
      estimate_body(body)
    end
  end

  defp estimate_path(native, side, quantity) do
    query = [{"symbol", native}, {"side", side}, {"quantity", quantity}]
    "/api/v2/crypto/trading/estimated_price/" <> query_string(query)
  end

  # A symbol that is not a string, or is blank once trimmed, is `{:invalid_symbol, value}`,
  # decided here before anything is signed or sent (a blank one built `symbol=`).
  defp native_symbol(symbol) when is_binary(symbol) do
    if String.trim(symbol) == "",
      do: {:error, {:invalid_symbol, symbol}},
      else: {:ok, SymbolFormat.to_exchange_symbol(symbol)}
  end

  defp native_symbol(other), do: {:error, {:invalid_symbol, other}}

  defp estimate_side(side) when side in [:bid, :ask, :both], do: {:ok, Atom.to_string(side)}
  defp estimate_side(side) when side in ["bid", "ask", "both"], do: {:ok, side}
  defp estimate_side(side), do: {:error, {:unsupported_side, side}}

  defp quantity_param([_first | _rest] = list) do
    list
    |> Enum.map(&positive_string/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, string}, {:ok, acc} -> {:cont, {:ok, [string | acc]}}
      :error, _acc -> {:halt, {:error, {:invalid_field, :quantity}}}
    end)
    |> case do
      {:ok, strings} -> {:ok, strings |> Enum.reverse() |> Enum.join(",")}
      error -> error
    end
  end

  defp quantity_param(value) when is_list(value), do: {:error, {:invalid_field, :quantity}}

  defp quantity_param(value) do
    case positive_string(value) do
      {:ok, string} -> {:ok, string}
      :error -> {:error, {:invalid_field, :quantity}}
    end
  end

  @estimate_numbers ~w(quantity bid ask fee_ratio est_fee est_total_cost est_total_credit)

  # `V2EstimatedPriceResponse` is `{"results": [...]}`. A body with no `results` list (`{}`, an
  # error-shaped `{"detail": ...}` answered with a 200, `"results": "x"`) used to be handed back
  # as the estimate, a success that estimates nothing. `null` is an empty page, as elsewhere.
  defp estimate_body(%{"results" => rows} = body) when is_list(rows) do
    with {:ok, decoded} <- estimate_rows(rows), do: {:ok, %{body | "results" => decoded}}
  end

  defp estimate_body(%{"results" => nil} = body), do: {:ok, body}
  defp estimate_body(_other), do: {:error, :unexpected_response_shape}

  defp estimate_rows(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case estimate_row(row) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  # A numeric field that is present must be a number. A JSON number becomes a `Decimal`; a
  # string that parses as a finite number is carried as sent; anything else (`"abc"`, `"NaN"`,
  # `true`, a list) is `{:error, {:invalid_decimal, key, value}}` rather than a price a caller
  # reads. `null` and an absent key are left as they are: nothing was said.
  defp estimate_row(row) when is_map(row) do
    Enum.reduce_while(@estimate_numbers, {:ok, row}, fn key, {:ok, acc} ->
      case estimate_number(Map.get(acc, key)) do
        :absent -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        :error -> {:halt, {:error, {:invalid_decimal, key, bounded_raw(Map.get(acc, key))}}}
      end
    end)
  end

  defp estimate_row(other), do: {:ok, other}

  defp estimate_number(nil), do: :absent
  defp estimate_number(value) when is_number(value), do: {:ok, decimal(value)}

  defp estimate_number(value) when is_binary(value),
    do: if(decimal(value) == nil, do: :error, else: {:ok, value})

  defp estimate_number(_other), do: :error

  # A quantity or price this package is about to put on the wire: a positive, finite number
  # in full notation, never scientific -- `1.0e-4` is not a quantity this venue reads, and a
  # float goes through `Decimal` too because `to_string(0.00001)` IS `"1.0e-5"`.
  #
  # **Anything else is `:error`, and used to be sent.** The fallback clause was
  # `to_string(value)`, so `"abc"`, `"NaN"`, `"-1"` and `"0"` all went into a
  # SIGNED order body, on a call that moves funds, to be refused (or worse, interpreted) by
  # the venue. `0` and negatives are not quantities, and `NaN`/`Infinity` are not numbers.
  # The venue's own bounds (`max_order_size`, increments) are its to state, not guessed here.
  defp positive_string(value) do
    case input_decimal(value) do
      %Decimal{} = amount ->
        # `|exp| > 40` would expand to a string of that many zeros ("1e999999999" is a
        # gigabyte); no crypto quantity or price needs more than 40 decimal places.
        if Decimal.positive?(amount) and abs(amount.exp) <= 40,
          do: {:ok, Decimal.to_string(amount, :normal)},
          else: :error

      nil ->
        :error
    end
  end

  defp input_decimal(%Decimal{} = value),
    do: if(Decimal.nan?(value) or Decimal.inf?(value), do: nil, else: value)

  defp input_decimal(value) when is_number(value) or is_binary(value), do: decimal(value)
  defp input_decimal(_other), do: nil

  @doc """
  Orders on one account — `GET /api/v2/crypto/trading/orders/`.

  `opts[:account_number]` is required by v2. `opts[:created_at_start]` and the venue's other
  filters are passed through under its own names, and none is defaulted — a start date
  chosen here would return a real list of orders over a window the caller did not ask about.
  The filters read are `:created_at_start`, `:created_at_end`, `:updated_at_start`,
  `:updated_at_end`, `:symbol`, `:side`, `:type` (`:stop` is sent as the venue's
  `"stop_loss"`) and `:state` (the venue also knows `"pending"`). A `%DateTime{}` passed for
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
  (`{:error, :history_truncated}`, the family's one spelling for a history that could not be
  read to its end; it was `:too_many_order_pages`) rather than returning a truncated history
  as complete.
  """
  @spec get_orders(map(), keyword()) ::
          {:ok, [Order.t()]} | {:error, term()} | {:refused, term()}
  def get_orders(credentials, opts) do
    with {:ok, account} <- required_account(opts),
         {:ok, filters} <- order_filters(opts),
         {:ok, cursor} <- cursor_param(Keyword.get(opts, :cursor)) do
      query = ([{"account_number", account}] ++ filters) |> put_query("cursor", cursor)

      path = "/api/v2/crypto/trading/orders/" <> query_string(query)

      # `Config.opt/3`, not `Keyword.has_key?/2`: a forwarded `limit: nil` is an absent
      # option, and took the one-page branch, returning a truncated history as complete.
      if Config.opt(opts, :limit, nil) != nil do
        get_orders_one_page(path, credentials, opts)
      else
        with {:ok, rows} <- walk(path, credentials, opts, [], 0, [], :history_truncated) do
          to_orders(rows)
        end
      end
    end
  end

  # A cursor is the venue's own opaque text, so the only thing a caller can hand back is a
  # non-blank string. It went through `to_string/1`, which raises on a map or a tuple inside
  # the caller's process and turned a number into text the venue never issued.
  defp cursor_param(nil), do: {:ok, nil}

  defp cursor_param(cursor) when is_binary(cursor) do
    if String.trim(cursor) == "", do: {:error, {:invalid_field, :cursor}}, else: {:ok, cursor}
  end

  defp cursor_param(_other), do: {:error, {:invalid_field, :cursor}}

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
  #
  # Anything else (a `NaiveDateTime`, a `Date`, a number) used to go through `to_string/1` in
  # Elixir's own format, which the venue does not document: refused instead.
  defp iso8601_param(nil), do: {:ok, nil}
  defp iso8601_param(%DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}
  # A string must parse as an ISO 8601 date-time with an offset (`DateTime.from_iso8601/1`);
  # it is then sent exactly as given. Text that does not parse is the caller's mistake and is
  # refused rather than sent for the venue to 400.
  defp iso8601_param(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> {:ok, value}
      {:error, _reason} -> :error
    end
  end

  defp iso8601_param(_other), do: :error

  @doc """
  The instant a date filter value (`%DateTime{}` or ISO 8601 string) stands for, `nil` for
  `nil`, `:error` when it is neither. Exposed so `DpExchange.Robinhood.Fake` compares
  against exactly what `get_orders/2` would send.
  """
  @spec filter_instant(term()) :: {:ok, DateTime.t() | nil} | :error
  def filter_instant(nil), do: {:ok, nil}
  def filter_instant(%DateTime{} = value), do: {:ok, value}

  def filter_instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  def filter_instant(_other), do: :error

  # The `side`, `type` and `state` filters are enums in the committed spec
  # (docs/reference/robinhood/openapi, `GET /api/v2/crypto/trading/orders/`): side `buy`,
  # `sell`; type `market`, `limit`, `stop_loss`, `stop_limit`; state `open`, `canceled`,
  # `filled`, `failed`, `pending` (v2's filter has no `partially_filled`). Contract atoms map
  # to the venue's words; anything else is refused before signing. `symbol` must be a
  # non-empty string.
  defp filter_symbol(nil), do: {:ok, nil}

  defp filter_symbol(symbol) when is_binary(symbol) and symbol != "",
    do: {:ok, SymbolFormat.to_exchange_symbol(symbol)}

  defp filter_symbol(_other), do: :error

  defp filter_side(nil), do: {:ok, nil}
  defp filter_side(side) when side in [:buy, "buy"], do: {:ok, "buy"}
  defp filter_side(side) when side in [:sell, "sell"], do: {:ok, "sell"}
  defp filter_side(_other), do: :error

  defp filter_type(nil), do: {:ok, nil}
  defp filter_type(type) when type in [:market, "market"], do: {:ok, "market"}
  defp filter_type(type) when type in [:limit, "limit"], do: {:ok, "limit"}

  defp filter_type(type) when type in [:stop, :stop_loss, "stop", "stop_loss"],
    do: {:ok, "stop_loss"}

  defp filter_type(type) when type in [:stop_limit, "stop_limit"], do: {:ok, "stop_limit"}
  defp filter_type(_other), do: :error

  defp filter_state(nil), do: {:ok, nil}
  defp filter_state(state) when state in [:open, "open"], do: {:ok, "open"}

  defp filter_state(state) when state in [:cancelled, :canceled, "canceled"],
    do: {:ok, "canceled"}

  defp filter_state(state) when state in [:filled, "filled"], do: {:ok, "filled"}
  defp filter_state(state) when state in [:rejected, :failed, "failed"], do: {:ok, "failed"}
  defp filter_state(state) when state in [:pending, "pending"], do: {:ok, "pending"}
  defp filter_state(_other), do: :error

  defp order_filters(opts) do
    Enum.reduce_while(filter_converters(), {:ok, []}, fn {key, convert}, {:ok, acc} ->
      case convert.(Keyword.get(opts, key)) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, acc ++ [{Atom.to_string(key), value}]}}
        :error -> {:halt, {:error, {:invalid_field, key}}}
      end
    end)
  end

  defp filter_converters do
    [
      created_at_start: &iso8601_param/1,
      created_at_end: &iso8601_param/1,
      updated_at_start: &iso8601_param/1,
      updated_at_end: &iso8601_param/1,
      symbol: &filter_symbol/1,
      side: &filter_side/1,
      type: &filter_type/1,
      state: &filter_state/1
    ]
  end

  @doc """
  Whether the order filters in `opts` (`:created_at_start`, `:created_at_end`,
  `:updated_at_start`, `:updated_at_end`, `:symbol`, `:side`, `:type`, `:state`) are ones
  `get_orders/2` would send, answered with its refusal, `{:error, {:invalid_field, key}}`,
  and without sending anything. Exposed so `DpExchange.Robinhood.Fake` refuses the same.
  """
  @spec validate_order_filters(keyword()) :: :ok | {:error, {:invalid_field, atom()}}
  def validate_order_filters(opts) do
    with {:ok, _filters} <- order_filters(opts), do: :ok
  end

  @doc """
  One order — `GET /api/v2/crypto/trading/orders/{order_id}/`.

  `opts[:account_number]` is required by v2, otherwise `{:error, {:missing_option,
  :account_number}}`. An id that is not a non-blank string is `{:error, {:invalid_order_id,
  id}}`, decided before the account option and before credentials. A 404 is
  `{:refused, :not_found}`.

  **This path is not in the vendor's OpenAPI `paths`.** It appears only in the sample client
  in the spec's own `info.description` (its `get_order` method). Its response is decoded as
  `V2CryptoOrder`, the schema the documented cancel path returns, and the test fixture is
  built from that schema, not captured from the venue
  (`test/fixtures/spec_examples/README.md`). Unmeasured.
  """
  @spec get_order(map(), String.t(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def get_order(credentials, order_id, opts) do
    with {:ok, segment} <- order_id_segment(order_id),
         {:ok, account} <- required_account(opts) do
      path =
        "/api/v2/crypto/trading/orders/" <>
          segment <> "/" <> query_string([{"account_number", account}])

      path |> get(credentials, opts) |> read_order()
    end
  end

  # An order endpoint's answer as an order. A 404 is the venue saying it holds no such order
  # (`{:refused, :not_found}`, the family's one spelling); every other refusal keeps the
  # venue's own status and detail.
  defp read_order({:ok, body}), do: to_order(body)
  defp read_order({:refused, reason}), do: {:refused, order_refusal(reason)}
  defp read_order({:error, _reason} = error), do: error

  defp order_refusal({:venue_error, 404}), do: :not_found
  defp order_refusal({:venue_error, 404, _detail}), do: :not_found
  defp order_refusal(other), do: other

  # An order id is ONE path segment, and it is part of what is signed. `URI.encode/1` leaves
  # `/`, `?`, `#` and `&` alone, so an id like `"x/cancel/?y"` rewrote the signed path into a
  # different endpoint's: a `get_order/3` that cancelled, or a `cancel_order/3` aimed at
  # another resource. Every reserved character is percent-encoded instead. A blank id would
  # collapse the segment (`/orders//cancel/`) and is refused rather than sent.
  defp order_id_segment(order_id) when is_binary(order_id) do
    if String.trim(order_id) == "",
      do: {:error, {:invalid_order_id, order_id}},
      else: {:ok, URI.encode(order_id, &URI.char_unreserved?/1)}
  end

  # `nil` or an atom raised `FunctionClauseError` in the caller's process, on a call that
  # moves funds; it is an invalid id like a blank one (the family's `{:invalid_order_id, v}`).
  defp order_id_segment(not_a_string), do: {:error, {:invalid_order_id, not_a_string}}

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
  `asset_quantity` — the venue's own field — a limit order also needs `price` (the venue's
  `limit_price`), a `:stop` / `:stop_loss` order needs `stop_price` and a `:stop_limit` order
  needs both.

  **Refused locally, before anything is signed or sent, in this order:** a request that is
  not a map `{:invalid_order_request, request}`; a key this builder does not read
  (`post_only`, `reduce_only`, ...) `{:unsupported_order_field, key}`; a `symbol` that is
  not a non-blank string `{:invalid_symbol, v}`; a `side` other than `buy`/`sell` (atom or
  string, any case) `{:invalid_side, v}`; a missing field `{:missing_field, key}`
  (`order_type` is never defaulted or inferred); an order type outside `:market`, `:limit`,
  `:stop` (or the venue's `:stop_loss`) and `:stop_limit` `{:unsupported_order_type, type}`;
  a `time_in_force`: **a market order's config has no duration, so a supplied one is
  `{:unexpected_field, :time_in_force}`; the other three types require one**
  (`{:missing_field, :time_in_force}`, never a silent venue default) and it must be one of
  `:gtc`, `:day`, `:gfw`, `:gfm`, otherwise `{:unsupported_order_combination, type, tif}`;
  a quantity that is not a positive finite `Decimal`, integer or numeric string
  `{:invalid_quantity, v}` (a float has already lost digits and is refused); the same for
  `{:invalid_price, v}` and `{:invalid_stop_price, v}`; a `price` the type does not use
  (market, stop) or a `stop_price` on a type without one (market, limit)
  `{:unexpected_field, key}` rather than dropped; a `client_order_id` that is not a UUID
  `{:invalid_client_order_id, v}`; no `opts[:account_number]` `{:missing_option,
  :account_number}`; then missing or malformed credentials. The body is sent with
  `content-type: application/json`, as the vendor's own client sends it.

  **An unconfirmed write is never a bare error.** Once the request may have reached the
  venue and success is not proven — a transport failure or timeout after retries, a 5xx, a
  2xx whose body is not JSON, is not an order object or has no `id`, or a refusal on an
  attempt after the first (the earlier attempt may have been accepted) — the answer is
  `{:error, {:order_unconfirmed, client_order_id, reason}}`, carrying the `client_order_id`
  actually sent (the package-generated one included), so the caller can look the order up
  with `get_order/3` or re-send the SAME id. Our own rate limiter refusing before the first
  send stays a plain `{:error, reason}`, and so does the venue's 429 on the ONLY attempt.
  **Every other 4xx the venue answers to the only attempt is `{:refused, _}`** (405, 406,
  415, 422, 409 and the rest: it received the request and did not act). A 429, or a 4xx, on
  a RETRY stays unconfirmed. A 2xx that carries an `id` is a confirmed order even
  if a field holds a value this package does not know: the order exists, so it is
  `{:ok, %Order{}}` with that field `nil`.
  """
  @spec place_order(map(), map(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def place_order(credentials, request, opts) do
    with {:ok, parts} <- normalize_order_request(request),
         {:ok, supplied} <- supplied_client_order_id(request, opts),
         {:ok, account} <- required_account(opts),
         :ok <- Auth.validate_credentials(credentials),
         # Checked here as well as in `post/5`: a refusal out of `post/5` would be read by
         # `confirm_order/4` as a send that may have happened, and nothing has been sent.
         {:ok, _base} <- secure_base_url(opts) do
      client_order_id = supplied || generate_client_order_id()
      path = "/api/v2/crypto/trading/orders/" <> query_string([{"account_number", account}])
      calls = :atomics.new(1, signed: false)
      body = order_body(parts, client_order_id)

      path
      |> post(body, credentials, opts, &counting(&1, calls))
      |> confirm_order(client_order_id, calls, opts)
    end
  end

  # Counts how many times a request was signed. `Core.HttpClient` signs once per attempt
  # (twice on a blocking limiter), so the count is how a failure is told apart: an error with
  # nothing yet sent is a refusal to send, and an error after a first attempt is an
  # unconfirmed write.
  # Only a signature that was produced counts: a signing failure sends nothing.
  defp counting(signer, calls) do
    fn ->
      case signer.() do
        {:ok, _headers} = signed ->
          :atomics.add(calls, 1, 1)
          signed

        other ->
          other
      end
    end
  end

  # How many attempts actually left the process. Blocking limiter: signed before and after the
  # limiter wait, so two calls per attempt. Otherwise one per attempt, the last of which was
  # never sent when it was the limiter that refused.
  defp sent_attempts(calls, opts, limiter_refused?) do
    signed = :atomics.get(calls, 1)

    cond do
      Config.opt(opts, :rate_limit_blocking, false) -> div(signed, 2)
      limiter_refused? -> max(signed - 1, 0)
      true -> signed
    end
  end

  defp confirm_order({:ok, decoded}, client_order_id, _calls, _opts) do
    case to_order(decoded, :lenient) do
      {:ok, _order} = confirmed -> confirmed
      {:error, reason} -> unconfirmed(client_order_id, reason)
    end
  end

  defp confirm_order({:refused, reason}, client_order_id, calls, opts) do
    if sent_attempts(calls, opts, false) > 1,
      do: unconfirmed(client_order_id, {:refused_after_retry, reason}),
      else: {:refused, order_refusal(reason)}
  end

  # Three answers. Our own limiter refusing before anything was sent, and the venue's 429 on
  # the ONLY attempt, are plain errors: the order cannot exist. (Every OTHER 4xx on the only
  # attempt is `{:refused, _}`, handled above: tick R, DV6.) Everything else, and a 429 to a
  # RETRY (an earlier attempt may have been accepted), is unconfirmed.
  defp confirm_order({:error, reason}, client_order_id, calls, opts) do
    limiter? = limiter_refusal?(reason)

    cond do
      limiter? -> limiter_answer(reason, client_order_id, sent_attempts(calls, opts, true))
      throttled?(reason) and sent_attempts(calls, opts, false) <= 1 -> {:error, reason}
      true -> unconfirmed(client_order_id, reason)
    end
  end

  defp limiter_answer(reason, _client_order_id, 0), do: {:error, reason}
  defp limiter_answer(reason, client_order_id, _sent), do: unconfirmed(client_order_id, reason)

  defp throttled?({:exchange_error, _provider, "Rate limited by the venue" <> _rest}),
    do: true

  # Deliberate defence, not a path today: `Core.HttpClient` never hands a 429 back (it is
  # always "Rate limited by the venue" above), but if it ever did, `post_to/6` would turn it
  # into this text, and a throttled first send must stay a plain error, not an unconfirmed one.
  defp throttled?({:exchange_error, _provider, "HTTP 429" <> _rest}), do: true
  defp throttled?(_reason), do: false

  defp limiter_refusal?(
         {:exchange_error, _provider, "Throttled by our own rate limiter" <> _rest}
       ),
       do: true

  defp limiter_refusal?({:exchange_error, _provider, "Rate limiter unavailable"}), do: true
  defp limiter_refusal?({:exchange_error, _provider, :rate_limit_timeout}), do: true
  defp limiter_refusal?(_reason), do: false

  defp unconfirmed(client_order_id, reason),
    do: {:error, {:order_unconfirmed, client_order_id, bound_reason(reason)}}

  # A reason carried in an error tuple is data a caller stores and logs; past a couple of
  # kilobytes it is text, not a reason.
  defp bound_reason(reason) do
    if :erlang.external_size(reason) <= 2_048,
      do: reason,
      else: inspect(reason, limit: 20, printable_limit: 512)
  end

  @doc """
  Cancels an order — `POST /api/v2/crypto/trading/orders/{order_id}/cancel/`.

  **A POST, not a DELETE**, and it takes no account number where every other order call
  does. It sends **no body** (signed as the empty string), as the vendor's own client does.
  The id is one percent-encoded path segment; a blank id is refused as `{:error,
  {:invalid_order_id, id}}` rather than sent as `/orders//cancel/`.

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

  **A cancel is sent once.** It is never retried internally, whatever `:retry_attempts`
  says: a second attempt after a timeout cannot tell the caller whether the first took
  effect, and the answer to "is it cancelled" is `get_order/3`. A blank or non-string id is
  `{:error, {:invalid_order_id, id}}`, decided before credentials, and a 404 is
  `{:refused, :not_found}`.
  """
  @spec cancel_order(map(), String.t(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def cancel_order(credentials, order_id, opts) do
    with {:ok, segment} <- order_id_segment(order_id) do
      path = "/api/v2/crypto/trading/orders/" <> segment <> "/cancel/"

      path |> post(nil, credentials, Keyword.put(opts, :retry_attempts, 1)) |> read_order()
    end
  end

  defp required_account(opts) do
    # A blank account number is no account number: `account_number=` went out signed and the
    # venue answered for nothing it could name.
    case Keyword.get(opts, :account_number) do
      account when is_binary(account) ->
        if String.trim(account) == "",
          do: {:error, {:missing_option, :account_number}},
          else: {:ok, account}

      _missing ->
        {:error, {:missing_option, :account_number}}
    end
  end

  @doc """
  The order `request` describes, validated and normalised, without sending anything.

  `{:ok, parts}` with `:symbol` (as given), `:side` (`:buy` or `:sell`), `:type` (the
  contract's `:market`, `:limit`, `:stop` or `:stop_limit`; `:stop_loss` is `:stop`),
  `:time_in_force` (an atom, or `nil` for a market order), `:quantity` (the wire string),
  and `:price` / `:stop_price` (wire strings, `nil` where the type has none) — or the
  refusal `place_order/3` would give, in the order `place_order/3` checks (see its doc). It
  is the code `place_order/3` builds its body from, exposed so `DpExchange.Robinhood.Fake`
  refuses exactly what the real path refuses and answers with the same normalised fields.
  """
  @spec normalize_order_request(term()) :: {:ok, map()} | {:error, term()}
  def normalize_order_request(request), do: order_parts(request)

  @order_keys [
    :symbol,
    :side,
    :order_type,
    :quantity,
    :price,
    :stop_price,
    :time_in_force,
    :client_order_id
  ]

  # A request that is not a map used to raise (`BadMapError`) inside the caller's process,
  # on the call that moves funds; it is a refusal like any other malformed order.
  defp order_parts(request) when not is_map(request),
    do: {:error, {:invalid_order_request, request}}

  defp order_parts(request) do
    with :ok <- known_order_keys(request),
         {:ok, symbol} <- order_symbol_field(request),
         {:ok, side} <- order_side_field(request),
         {:ok, type} <- order_type_field(request),
         {:ok, tif} <- order_time_in_force(type, request),
         {:ok, quantity} <- order_amount(request, :quantity, :invalid_quantity),
         {:ok, prices} <- order_prices(type, request) do
      {:ok,
       Map.merge(
         %{symbol: symbol, side: side, type: type, time_in_force: tif, quantity: quantity},
         prices
       )}
    end
  end

  # Any key this builder does not read is refused: `post_only: true` or `reduce_only: true`
  # was ignored, and the order went out without the constraint the caller asked for.
  defp known_order_keys(request) do
    case Enum.find(Map.keys(request), &(&1 not in @order_keys)) do
      nil -> :ok
      key -> {:error, {:unsupported_order_field, key}}
    end
  end

  # `SymbolFormat` raises on a non-string, and a blank one builds `"symbol": ""`.
  defp order_symbol_field(request) do
    case Map.fetch(request, :symbol) do
      # An absent symbol is `{:invalid_symbol, nil}` on every venue, exactly as `symbol: nil`
      # (family tick R, DV2; it was `{:missing_field, :symbol}`).
      :error ->
        {:error, {:invalid_symbol, nil}}

      {:ok, symbol} when is_binary(symbol) ->
        if String.trim(symbol) == "", do: {:error, {:invalid_symbol, symbol}}, else: {:ok, symbol}

      {:ok, unusable} ->
        {:error, {:invalid_symbol, unusable}}
    end
  end

  # The venue's `side` enum is `buy`/`sell`. Any other atom used to go out as
  # `to_string(side)` -- `:hold` became `"hold"` -- in a signed order body. A string is
  # accepted in any case.
  defp order_side_field(request) do
    with {:ok, side} <- order_field(request, :side) do
      case side_name(side) do
        "buy" -> {:ok, :buy}
        "sell" -> {:ok, :sell}
        _other -> {:error, {:invalid_side, side}}
      end
    end
  end

  defp side_name(side) when is_atom(side) and not is_nil(side), do: side |> Atom.to_string()
  defp side_name(side) when is_binary(side), do: String.downcase(side)
  defp side_name(_other), do: nil

  # The order type is required, never defaulted or inferred from which prices are present.
  # The venue's four types, the contract's `:stop` and the venue's own `:stop_loss` (and the
  # string spellings the wire uses) all name a type; anything else is named back.
  defp order_type_field(request) do
    with {:ok, type} <- order_field(request, :order_type) do
      case type do
        type when type in [:market, "market"] -> {:ok, :market}
        type when type in [:limit, "limit"] -> {:ok, :limit}
        type when type in [:stop, :stop_loss, "stop", "stop_loss"] -> {:ok, :stop}
        type when type in [:stop_limit, "stop_limit"] -> {:ok, :stop_limit}
        other -> {:error, {:unsupported_order_type, other}}
      end
    end
  end

  # `market_order_config` carries no `time_in_force` in the vendor's schema, so a market
  # order has nowhere honest to put one: a supplied duration is refused, not dropped. The
  # other three types send one, and the venue's default for an absent one is not this
  # package's to assume, so it is required and must be one `capabilities/0` declares.
  defp order_time_in_force(:market, request) do
    case Map.get(request, :time_in_force) do
      nil -> {:ok, nil}
      _supplied -> {:error, {:unexpected_field, :time_in_force}}
    end
  end

  defp order_time_in_force(type, request) do
    with {:ok, tif} <- order_field(request, :time_in_force) do
      if Map.has_key?(@tif_names, tif),
        do: {:ok, tif},
        else: {:error, {:unsupported_order_combination, type, tif}}
    end
  end

  # `price` is the venue's `limit_price` and exists for `limit` and `stop_limit`;
  # `stop_price` exists for `stop` and `stop_limit`. A field the type does not use is
  # refused rather than dropped; one it needs is required.
  defp order_prices(type, request) do
    uses_price? = type in [:limit, :stop_limit]
    uses_stop? = type in [:stop, :stop_limit]

    with :ok <- unused_field(request, :price, uses_price?),
         :ok <- unused_field(request, :stop_price, uses_stop?),
         {:ok, price} <- optional_amount(request, :price, :invalid_price, uses_price?),
         {:ok, stop} <- optional_amount(request, :stop_price, :invalid_stop_price, uses_stop?) do
      {:ok, %{price: price, stop_price: stop}}
    end
  end

  defp unused_field(request, key, uses?) do
    if not uses? and Map.get(request, key) != nil,
      do: {:error, {:unexpected_field, key}},
      else: :ok
  end

  defp optional_amount(_request, _key, _tag, false), do: {:ok, nil}
  defp optional_amount(request, key, tag, true), do: order_amount(request, key, tag)

  # A quantity or price: present AND a positive, finite number, as the wire string. A float
  # is refused: it has already lost the digits the caller meant. See `positive_string/1`.
  defp order_amount(request, key, tag) do
    with {:ok, value} <- order_field(request, key) do
      case order_number(value) do
        {:ok, string} -> {:ok, string}
        :error -> {:error, {tag, value}}
      end
    end
  end

  defp order_number(value) when is_float(value), do: :error
  defp order_number(value), do: positive_string(value)

  defp order_body(parts, client_order_id) do
    wire_type = wire_order_type(parts.type)

    %{
      "client_order_id" => client_order_id,
      "side" => Atom.to_string(parts.side),
      "type" => wire_type,
      "symbol" => SymbolFormat.to_exchange_symbol(parts.symbol),
      "#{wire_type}_order_config" => order_config(parts)
    }
  end

  # The wire's own spelling for the `"type"` field and the `"#{type}_order_config"` key it
  # selects — never the raw, interpolated `type` the caller passed. The venue answers to
  # exactly one spelling, `"stop_loss"`, on both the `type` field and the config key.
  # Interpolating the caller's `:stop` produced `"stop_order_config"`, which the venue does
  # not recognise and silently drops, so the order shipped with no config object at all
  # rather than refusing.
  defp wire_order_type(:stop), do: "stop_loss"
  defp wire_order_type(type), do: Atom.to_string(type)

  defp order_field(request, key) do
    case Map.get(request, key) do
      nil -> {:error, {:missing_field, key}}
      value -> {:ok, value}
    end
  end

  # What each of the venue's four configs carries: the size always, `limit_price` for limit
  # and stop-limit, `stop_price` for stop and stop-limit, and a duration for all but market.
  defp order_config(parts) do
    %{"asset_quantity" => parts.quantity}
    |> put_config("limit_price", parts.price)
    |> put_config("stop_price", parts.stop_price)
    |> put_config("time_in_force", parts.time_in_force && tif_name(parts.time_in_force))
  end

  defp put_config(config, _key, nil), do: config
  defp put_config(config, key, value), do: Map.put(config, key, value)

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
  #
  # **The request's own key first**, as `dp_exchange_coinbase` and `dp_exchange_gemini` read
  # it. Only `opts[:client_order_id]` was read, so a caller who put the key on the request
  # (where the other venues take it) got a fresh one on every call, and a caller-level retry
  # after a timeout placed a second order: the protection the key exists for, gone.
  #
  # **A supplied key must be a UUID.** The vendor's `AddOrderV2.client_order_id` is `format:
  # uuid` and its error example is "Must be a valid UUID." A key of any other shape reaches
  # the venue as a 400 on the call that moves funds, and a caller retrying with it retries a
  # request that can never succeed. Refused before signing instead. Canonical 8-4-4-4-12 hex,
  # either case; `nil` and `""` are still "none supplied", anything else that is not a string
  # is refused like a malformed one.
  @doc """
  The `client_order_id` the caller supplied for `request` (the request's own key first, then
  `opts[:client_order_id]`): `{:ok, nil}` when none was (`nil` or `""`), `{:ok, id}` for a
  canonical UUID, `{:error, {:invalid_client_order_id, value}}` for anything else. Exposed
  so `DpExchange.Robinhood.Fake` refuses exactly what `place_order/3` refuses.
  """
  @spec supplied_client_order_id(map(), keyword()) ::
          {:ok, String.t() | nil} | {:error, {:invalid_client_order_id, term()}}
  def supplied_client_order_id(request, opts) do
    case Map.get(request, :client_order_id) || Config.opt(opts, :client_order_id, nil) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      id -> if uuid?(id), do: {:ok, id}, else: {:error, {:invalid_client_order_id, id}}
    end
  end

  defp uuid?(id) when is_binary(id),
    do: Regex.match?(~r/\A[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}\z/, id)

  defp uuid?(_not_a_string), do: false

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
  #
  # **Two modes.** A read (`:strict`) refuses a present value outside the venue's enums, see
  # `known_enums/1`. The answer to a PLACEMENT (`:lenient`) cannot: the order exists, it
  # carries an id, and refusing it would hand the caller an error for an order that is live.
  # The field this package cannot read is `nil` and the caller reconciles with `get_order/3`.
  defp to_order(row), do: to_order(row, :strict)

  defp to_order(%{"id" => id} = row, mode) when is_binary(id) and id != "" do
    case mode do
      :lenient -> {:ok, order_struct(row)}
      :strict -> with :ok <- known_enums(row), do: {:ok, order_struct(row)}
    end
  end

  defp to_order(row, _mode) when is_map(row), do: {:error, {:missing_required_field, :id}}
  defp to_order(_row, _mode), do: {:error, :unexpected_response_shape}

  # A PRESENT value outside `OrderResponse`'s enums (`side`, `type`, `state`, and
  # `time_in_force` in the type-named config; `pending` is added to `state` as the venue's
  # own filter word) is refused rather than decoded as `nil`: an order whose state or side is
  # unreadable is not a weaker answer, it is one a caller may act on wrongly. An ABSENT
  # field stays `nil` -- nothing was said, and nothing is invented.
  @order_enums [
    side: ~w(buy sell),
    type: ~w(market limit stop_loss stop_limit),
    state: ~w(open partially_filled filled canceled failed pending)
  ]
  @tif_wire_names ~w(gtc gfd gfw gfm)

  defp known_enums(row) do
    checks =
      Enum.map(@order_enums, fn {field, allowed} ->
        {field, row[Atom.to_string(field)], allowed}
      end) ++ [{:time_in_force, configured_time_in_force(row), @tif_wire_names}]

    Enum.find_value(checks, :ok, fn
      {_field, nil, _allowed} -> nil
      {field, value, allowed} -> if value in allowed, do: nil, else: unknown_enum(field, value)
    end)
  end

  # The venue's value, bounded: it rides an error tuple into every caller's log.
  defp unknown_enum(field, value), do: {:error, {:unknown_enum, field, bounded_raw(value)}}

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
  # `pending` is not in `OrderResponse.state`'s enum, but it IS in the `state` filter's enum
  # on the same endpoint (`open`, `canceled`, `filled`, `failed`, `pending`), so the venue
  # does name the word for an order. It is Core's own `:pending`, the same meaning under the
  # same name -- not a nearest match -- and decoding it as `nil` hid an order the venue had
  # accepted but not yet opened.
  defp order_status("pending"), do: :pending
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

  # **A JSON body travels with `content-type: application/json`; no body travels with
  # none.** The vendor's own sample client posts with `requests.post(..., json=...)`, which
  # sets that header, and for the bodiless cancel posts nothing at all
  # (`json=json.loads(body) if body else None`). This sent a JSON body with NO content-type
  # (`Req` sets none for a binary body, and `Auth.headers/5` is the three signature headers
  # only), which an API that parses by content type is entitled to refuse as 415 -- on the
  # one call that moves funds. And cancel sent `{}` where the vendor's sample sends nothing,
  # signed as `{}` rather than as the empty string the vendor's example signs. `body: nil`
  # is no body: signed as `""` and sent as none, exactly as the vendor's client does.
  defp post(path, body, credentials, opts, wrap \\ &Function.identity/1) do
    with {:ok, base} <- secure_base_url(opts),
         do: post_to(base <> path, path, body, credentials, opts, wrap)
  end

  defp post_to(url, path, body, credentials, opts, wrap) do
    {encoded, wire_body, extra} = post_body(body)

    # Signed per attempt, not once: see `signer/6`. `wrap` lets a caller observe each signing.
    case HttpClient.request(
           :post,
           url,
           wrap.(signer("POST", path, encoded, credentials, opts, extra)),
           wire_body,
           request_opts(opts)
         ) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        decoded_body(response)

      # **Every 4xx except 429 is the venue's refusal of the request it received** (family
      # tick R, DV6) - 405, 406, 415, 422 and 409 included, not only the four the error table
      # lists. `confirm_order/4` decides whether it answered the ONLY attempt (a refusal) or a
      # RETRY (the earlier attempt may have been accepted: unconfirmed). 429 is the venue
      # throttling; `Core.HttpClient` turns it into its "Rate limited by the venue" error
      # before it reaches here, and a 429 that did arrive is a plain error below.
      {:ok, %{status: status, body: response}} when status in 400..499 and status != 429 ->
        {:refused, refusal(status, response)}

      # Deliberate defence, not a path today: `Core.HttpClient` hands back only a 2xx or (with
      # `raw_status`) a 4xx, and turns a 5xx, a 3xx and a 429 into `{:error, _}` itself. A status
      # it ever did hand back is a plain error here, never a success and never a refusal.
      {:ok, %{status: status, body: response}} ->
        status_error(status, response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An error message built from a response body is capped, as Core caps its own
  # (`HttpClient`'s 2_048-byte excerpt). A 502/503 from a CDN is a whole HTML page, and this
  # put every byte of it into the error tuple a feed then logs and a consumer stores. Within
  # the limits the text is byte-identical to a plain `inspect/1`.
  defp status_error(status, body) do
    excerpt = inspect(body, limit: 50, printable_limit: 2_048)
    {:error, {:exchange_error, :robinhood, "HTTP #{status}: #{excerpt}"}}
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
  defp signer(method, path, body, credentials, opts, extra \\ []) do
    fn ->
      with {:ok, headers} <- Auth.headers(method, path, body, credentials, opts) do
        {:ok, headers ++ extra}
      end
    end
  end

  defp post_body(nil), do: {"", nil, []}

  defp post_body(body) do
    encoded = Jason.encode!(body)
    {encoded, encoded, [{"content-type", "application/json"}]}
  end

  # --- request ------------------------------------------------------------

  defp get(path, credentials, opts) do
    with {:ok, base} <- secure_base_url(opts), do: get_from(base <> path, path, credentials, opts)
  end

  defp get_from(url, path, credentials, opts) do
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
        status_error(status, body)

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
      :retry_delay,
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
  # A refusal is reserved for where the venue actually SAYS so: a 400, 401, 403 or 404 with
  # a body, handled by `refusal/2` below on the HTTP status rather than on the shape of a
  # 200, and carried as `{:refused, {:venue_error, status, detail}}`. Those genuine
  # statements (e.g. `{:venue_error, 400, "Invalid symbol: ALGO-USD"}`) were the other 27
  # of the 83 and are unaffected by this. (`DpExchange.Robinhood.Fake` answers an unlisted
  # symbol with that same `{:venue_error, 400, "Invalid symbol: ..."}` shape.)
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
      %{"detail" => detail} when is_binary(detail) ->
        {:venue_error, status, cap(detail)}

      # A detail that is not text (a list, an object) is not a reason: it used to ride into
      # the error tuple whole, however large, and into every log that printed it.
      %{"errors" => [%{"detail" => detail} | _rest]} when is_binary(detail) ->
        {:venue_error, status, cap(detail)}

      _other ->
        {:venue_error, status}
    end
  end

  # A refusal's detail is the venue's text and is kept whole up to a kilobyte; past that it
  # is a page, not a reason. Non-strings pass through as before.
  defp cap(detail) when is_binary(detail) and byte_size(detail) > 1_024,
    do: String.slice(detail, 0, 1_024)

  defp cap(detail), do: detail

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
  # No `%Decimal{}` clause: every caller passes a value out of the venue's JSON (Req's default
  # decode, which yields integers, floats and strings, never a `Decimal`) or, from
  # `input_decimal/1`, only a number or a binary. A caller's own `Decimal` is handled there.
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
      {parsed, ""} -> finite(parsed)
      _unparsable -> nil
    end
  end

  defp decimal(_other), do: nil

  # NaN, Infinity and an exponent beyond +-1000 are not a number here. `1E999999999` is finite
  # to `Decimal` and parses instantly, but the first `Decimal.compare/2` or add against it
  # aligns exponents and allocates an integer of a billion digits: a few bytes of venue reply
  # cost this process its memory. The same bound `dp_exchange_schwab` applies.
  defp finite(%Decimal{exp: exp} = value) do
    if Decimal.nan?(value) or Decimal.inf?(value) or abs(exp) > 1000, do: nil, else: value
  end
end
