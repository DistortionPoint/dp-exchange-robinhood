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
  alias DpExchange.Core.Types.{Quote, TopOfBook}
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
    path = "/api/v1/crypto/marketdata/best_bid_ask/?symbol=" <> URI.encode(native)

    with {:ok, body} <- get(path, credentials, opts),
         {:ok, row} <- first_result(body),
         {:ok, price} <- quoted_price(row),
         {:ok, timestamp} <- venue_time(row) do
      {:ok,
       %Quote{
         symbol: SymbolFormat.to_canonical_symbol(native),
         price: decimal(price),
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
    path = "/api/v1/crypto/marketdata/best_bid_ask/?symbol=" <> URI.encode(native)

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
  defp decimal(value) when is_binary(value), do: Decimal.new(value)
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
end
