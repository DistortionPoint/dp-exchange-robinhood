defmodule DpExchange.Robinhood.Rest do
  @moduledoc """
  Robinhood Crypto's REST surface — internal.

  ## Every call is signed, including the quotes

  There is no anonymous endpoint here. `best_bid_ask` needs the same Ed25519 signature as
  an order, which is why this venue declares `credential_benefit: :required` and why
  `get_price/2` takes credentials.

  ## The price is the ask, and that is worth stating plainly

  `best_bid_ask` returns `bid_inclusive_of_sell_spread` and
  `ask_inclusive_of_buy_spread` — the prices a taker would actually get. When the venue
  sends no separate `price`, this package uses the **ask** as the quote's price, because it
  is a real number the venue quoted and it is the one a buyer pays.

  It is not a mid, and it is not a last trade. **A series built from it sits a spread above
  a mid-based series from another venue**, which matters if two venues' prices are ever
  compared. `bid` and `ask` are both carried so a caller can compute whatever it actually
  wants; nothing here computes a mid, because what a price *means* is the caller's
  decision.

  ## No candles, no order book, no volume

  Robinhood Crypto publishes no historical-candle endpoint, no order book, and no volume on
  the quote. Those are `:unsupported` — and that is the venue's shape, not a gap in this
  package. Declaring them so lets a consumer route that work elsewhere instead of
  discovering an empty series.
  """

  alias DpExchange.Core.HttpClient
  alias DpExchange.Core.Types.{Balance, Order, Quote, TopOfBook}
  alias DpExchange.Robinhood.{Auth, SymbolFormat}

  @base_url "https://trading.robinhood.com"

  @doc "Base URL, overridable for tests."
  @spec base_url(keyword()) :: String.t()
  def base_url(opts), do: Keyword.get(opts, :base_url, @base_url)

  @doc """
  Best bid and ask for one symbol.

  Timestamped from the venue's own `timestamp`. A quote the venue did not date returns
  `{:error, :missing_venue_timestamp}` — the local clock is never substituted, which is
  what the adapter this replaces did.
  """
  @spec get_price(String.t(), map(), keyword()) ::
          {:ok, Quote.t()} | {:error, term()} | {:refused, term()}
  def get_price(symbol, credentials, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    path = "/api/v2/crypto/marketdata/best_bid_ask/?symbol=" <> URI.encode(native)

    with {:ok, body} <- get(path, credentials, opts),
         {:ok, row} <- first_result(body),
         {:ok, raw_price} <- quoted_price(row),
         {:ok, price} <- required_decimal(raw_price, :price),
         {:ok, timestamp} <- venue_time(row) do
      {:ok,
       %Quote{
         symbol: SymbolFormat.to_canonical_symbol(native),
         price: price,
         # The quote carries no volume, and there is no candle endpoint to source one
         # from. `nil`, never `0`.
         volume: nil,
         timestamp: timestamp,
         provider: :robinhood
       }}
    end
  end

  @doc """
  Best bid and ask for `symbol` — the top of the book, not a traded price.

  Reads the same `best_bid_ask` payload as `get_price/3`. **The venue's spread-inclusive
  fields are what it publishes** — `bid_inclusive_of_sell_spread` and
  `ask_inclusive_of_buy_spread` are the prices a caller would actually transact at, and are
  carried as sent rather than adjusted back to a raw book.

  This is the split that the `get_price/3` fix in Phase 1 made possible: the quote keeps
  only what traded, and the book comes back here.
  """
  @spec get_top_of_book(String.t(), map(), keyword()) ::
          {:ok, TopOfBook.t()} | {:error, term()} | {:refused, term()}
  def get_top_of_book(symbol, credentials, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    path = "/api/v2/crypto/marketdata/best_bid_ask/?symbol=" <> URI.encode(native)

    with {:ok, body} <- get(path, credentials, opts),
         {:ok, row} <- first_result(body) do
      {:ok,
       %TopOfBook{
         symbol: SymbolFormat.to_canonical_symbol(native),
         bid: decimal(row["bid_inclusive_of_sell_spread"]),
         ask: decimal(row["ask_inclusive_of_buy_spread"]),
         bid_size: nil,
         ask_size: nil,
         venue_time: top_of_book_time(row),
         observed_at: DateTime.utc_now(),
         provider: :robinhood
       }}
    end
  end

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
  make and the quote half was not; see `get_price/3`.

  Measured by the prior adapter on 2026-08-05 against v1: 86 symbols, every one quoted in
  USD — **as seen by that credential**. Listings can differ by account tier, so a consumer
  holding a different key may see a different catalogue, and the figure has not been
  retaken against v2.
  """
  @spec get_symbols(map(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()} | {:refused, term()}
  def get_symbols(credentials, opts) do
    walk("/api/v2/crypto/trading/trading_pairs/", credentials, opts, [], [])
  end

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
  `trading_pairs` endpoint `get_symbols/1` already calls.

  `get_symbols/1` extracts only `symbol` from each row and discards the rest —
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
    path = "/api/v2/crypto/trading/trading_pairs/?symbol=" <> URI.encode(native)

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

  defp walk(path, credentials, opts, acc, seen) do
    if path in seen do
      {:error, {:pagination_loop, path}}
    else
      case get(path, credentials, opts) do
        {:ok, %{"results" => results} = body} ->
          symbols = results |> Enum.map(& &1["symbol"]) |> Enum.reject(&is_nil/1)
          acc = acc ++ symbols

          case next_path(body) do
            nil ->
              {:ok, acc |> Enum.map(&SymbolFormat.to_canonical_symbol/1) |> Enum.sort()}

            next ->
              walk(next, credentials, opts, acc, [path | seen])
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
  execute at *now*, which is a different number from `get_price/3`'s last trade and from
  `get_top_of_book/3`'s top of book — the third price on this venue, and the only one that
  accounts for size.

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
        {:ok, body |> account_rows() |> Enum.map(&to_order/1)}
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

      with {:ok, body} <- get(path, credentials, opts), do: {:ok, to_order(body)}
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

      with {:ok, response} <- post(path, body, credentials, opts), do: {:ok, to_order(response)}
    end
  end

  @doc """
  Cancels an order — `POST /api/v2/crypto/trading/orders/{order_id}/cancel/`.

  **A POST, not a DELETE**, and it takes no account number where every other order call
  does.

  **The venue acknowledges the request and does not report an outcome**, so the `Order`
  returned carries `status: :open` — the order is still live until the venue says otherwise,
  and telling a caller it is gone invites a second order for the same exposure. Everything
  the venue did not state is `nil`. `get_order/3` is what says whether the cancel took.
  """
  @spec cancel_order(map(), String.t(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def cancel_order(credentials, order_id, opts) when is_binary(order_id) do
    path = "/api/v2/crypto/trading/orders/" <> URI.encode(order_id) <> "/cancel/"

    with {:ok, _body} <- post(path, %{}, credentials, opts) do
      {:ok,
       %Order{
         id: order_id,
         symbol: nil,
         side: nil,
         order_type: nil,
         quantity: nil,
         # Accepted, not cancelled. The venue reports no outcome here.
         status: :open,
         provider: :robinhood
       }}
    end
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
      {:ok,
       %{
         "client_order_id" => Keyword.get(opts, :client_order_id, generate_client_order_id()),
         "side" => to_string(side),
         "type" => to_string(type),
         "symbol" => SymbolFormat.to_exchange_symbol(symbol),
         "#{type}_order_config" => config
       }}
    end
  end

  defp order_field(request, key) do
    case Map.get(request, key) do
      nil -> {:error, {:missing_field, key}}
      value -> {:ok, value}
    end
  end

  # The venue's four order types, and what each config must carry. A limit without a price
  # is an order the venue rejects; refusing here says which field rather than relaying a
  # message about a config key.
  defp order_config(type, request) when type in [:market, "market"] do
    with {:ok, quantity} <- order_field(request, :quantity) do
      {:ok, %{"asset_quantity" => decimal_string(quantity)}}
    end
  end

  defp order_config(type, request) when type in [:limit, "limit"] do
    with {:ok, quantity} <- order_field(request, :quantity),
         {:ok, price} <- order_field(request, :price) do
      {:ok,
       %{"asset_quantity" => decimal_string(quantity), "limit_price" => decimal_string(price)}}
    end
  end

  defp order_config(type, request) when type in [:stop_loss, "stop_loss"] do
    with {:ok, quantity} <- order_field(request, :quantity),
         {:ok, stop} <- order_field(request, :stop_price) do
      {:ok, %{"asset_quantity" => decimal_string(quantity), "stop_price" => decimal_string(stop)}}
    end
  end

  defp order_config(type, request) when type in [:stop_limit, "stop_limit"] do
    with {:ok, quantity} <- order_field(request, :quantity),
         {:ok, price} <- order_field(request, :price),
         {:ok, stop} <- order_field(request, :stop_price) do
      {:ok,
       %{
         "asset_quantity" => decimal_string(quantity),
         "limit_price" => decimal_string(price),
         "stop_price" => decimal_string(stop)
       }}
    end
  end

  defp order_config(type, _request), do: {:error, {:unsupported_order_type, type}}

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

  defp to_order(row) when is_map(row) do
    %Order{
      id: row["id"],
      symbol: order_canonical(row["symbol"]),
      side: order_side(row["side"]),
      order_type: order_kind(row["type"]),
      # The venue publishes no time-in-force on a crypto order. `nil` says so.
      time_in_force: nil,
      quantity: decimal(row["filled_asset_quantity"] || configured_quantity(row)),
      filled_quantity: decimal(row["filled_asset_quantity"]),
      average_price: decimal(row["average_price"]),
      status: order_status(row["state"]),
      fee: nil,
      fee_currency: nil,
      created_at: order_time(row["created_at"]),
      provider: :robinhood
    }
  end

  defp to_order(_row) do
    %Order{
      id: nil,
      symbol: nil,
      side: nil,
      order_type: nil,
      quantity: nil,
      status: nil,
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
          {:ok, decode(response)}

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
          {:ok, decode(body)}

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
    |> Keyword.take([:limiter, :timeout, :retry_attempts, :log_requests, :plug, :req_adapter])
    |> Keyword.merge(provider: :robinhood, raw_status: true)
  end

  # --- decoding -----------------------------------------------------------

  defp first_result(%{"results" => [row | _rest]}) when is_map(row), do: {:ok, row}
  defp first_result(%{"results" => []}), do: {:refused, :not_listed}
  defp first_result(_other), do: {:error, :unexpected_response_shape}

  # The ask when the venue sends no explicit price — see the module doc. Neither present
  # is an unreadable quote rather than one with a nil price.
  # A bid or an ask is **not** a trade price.
  #
  # This used to read `row["price"] || row["ask_inclusive_of_buy_spread"]`, falling back to
  # the ask when the venue sent no price. That is the §0 substitution in its purest form:
  # the ask is a real number the venue really sent, so nothing looks wrong, and the meaning
  # is wrong. An ask is a resting order — what someone is *willing* to sell at. A price is
  # what something *traded* at. They coincide only when that order fills.
  #
  # A consumer computing a position value, a P&L or a stop from an ask believes it is using
  # a trade price. In a wide or thin book those are different numbers, and the error is
  # largest exactly when the market is least liquid — when it matters most.
  #
  # So there is no fallback. No price, no quote.
  defp quoted_price(row) do
    case row["price"] do
      nil -> {:error, :no_trade_price_in_response}
      "" -> {:error, :no_trade_price_in_response}
      price -> {:ok, price}
    end
  end

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
    case decode(body) do
      %{"detail" => detail} when is_binary(detail) -> {:venue_error, status, detail}
      %{"errors" => [%{"detail" => detail} | _rest]} -> {:venue_error, status, detail}
      _other -> {:venue_error, status}
    end
  end

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{}
    end
  end

  defp decode(body), do: body

  defp decimal(nil), do: nil
  defp decimal(""), do: nil
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  # `Decimal.new/1` raises on a string that is not a number. `Decimal.parse/1`, requiring
  # the whole string be consumed (`{d, ""}`), is the family's established idiom for this.
  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {parsed, ""} -> parsed
      _unparsable -> nil
    end
  end

  defp decimal(_other), do: nil

  # A garbage or missing value in a field this contract requires must not become a `nil`
  # carried into `@enforce_keys` — a struct's field list does not check that a value is
  # non-nil, only that the key was given. Refuse the record instead.
  defp required_decimal(nil, field), do: {:error, {:missing_required_field, field}}

  defp required_decimal(value, field) do
    case decimal(value) do
      nil -> {:error, {:invalid_decimal, field, value}}
      parsed -> {:ok, parsed}
    end
  end
end
