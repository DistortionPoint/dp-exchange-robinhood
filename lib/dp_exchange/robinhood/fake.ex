defmodule DpExchange.Robinhood.Fake do
  @moduledoc """
  An in-process Robinhood, for a consumer's tier-1 tests and for the conformance suite.

  **It is not a mock.** A real implementation of `DpExchange.Core.Venue` answering from
  memory, running the *same* conformance suite as the real adapter.

  ## What it models that is specific to this venue

  - **Credentials are required for every signed call**, because the real venue signs every
    request — including market data — and has no anonymous endpoint at all. Without them:
    `{:error, {:missing_credentials, :robinhood}}`, the exact shape
    `DpExchange.Robinhood.Auth.headers/5` returns for a request that never reaches the
    venue. Not `{:refused, ...}` — a refusal is the venue's own permanent word about a
    request it received (see `DpExchange.Core.Venue`'s moduledoc on the two); a missing
    local credential is never sent at all, and is `:error` for the same reason
    `Auth.headers/5` is. Checked by every function below that reaches a real endpoint on
    this venue, market data and trading alike — there is no venue-internal function this
    venue leaves ungated, because there is no venue-internal function the real venue
    leaves unsigned.
  - **Coverage is `:internal_poll`, not `:stream`** — the one place a consumer can see that
    this venue has no socket, and it shows up as *what is arriving*, never as *how*.
  - **No candles, no order book, no volume.** The venue serves none, so neither does this.
  - **`subscribe/2` honours `:to`** (default the calling process), as the real facade does:
    the pid is registered and receives the books. A `:to` that is not a pid or a registered
    name is `{:error, {:invalid_subscriber, to}}`, checked after the symbol list
    (`{:error, {:invalid_symbols, value}}`), as in the real facade. `update_symbols/2`
    honours no `:to`; it delivers a newly added symbol to whoever `subscribe/2` registered,
    and with nobody registered delivers nothing, so `coverage/1` (only symbols a book was
    delivered for) stays empty. `subscribe_notices/1` validates its `:to` the same way,
    registers nothing and sends no `:link_up`: it runs no feed, so it never raises a notice
    for a registrant to receive.

  ## Failure injection and anonymous mode

  Every function below that has a real success path (not an unconditional
  `Venue.not_supported()`) checks `DpExchange.Core.FakeInjection.next_outcome/1` or `/2`
  first — a queued or always-set outcome from `FakeInjection.queue_failures/2,3` or
  `fail_always/2,3` short-circuits the fake's normal logic and is returned as-is.
  `authenticated/1` also checks `FakeInjection.credentials_bypassed?/1` before its normal
  `{:error, {:missing_credentials, :robinhood}}` path. Neither changes anything for a test
  that never calls `FakeInjection` — see that module for the full contract.

  `subscribe/2`, `unsubscribe/2` and `update_symbols/2` are NOT wired: each takes a list
  of symbols in one call, and "this one symbol in the batch fails, the rest succeed" is a
  case whole-call injection cannot express — see `FakeInjection`'s own moduledoc.
  `subscribe_notices/1` IS wired, unlike those three: it takes no symbol list, so a queued
  or always-set outcome (for example `{:error, :feed_not_started}`, which the real facade
  answers when its feed is not running) applies to the whole call the same way it does for
  `get_symbols/1` or `market_status/1`.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.{Capabilities, Config, FakeInjection, Fanout, Instrument, Types, Venue}
  alias DpExchange.Robinhood.{Auth, Feed, Rest, SymbolFormat}

  # Every symbol here is presumed API-tradable. `Rest.get_symbols/2` and
  # `Rest.list_instruments/2` both read the real venue's `is_api_tradable` field
  # (`V2TradingPair`) and exclude or downgrade a row where it is explicitly `false` — this
  # fake has no such row to model, since its fixed universe carries no `is_api_tradable`
  # concept at all. Not "differently capable": there is nothing here for that distinction
  # to apply to, the same way this fake has nothing to page past `@symbols`' three entries.
  @symbols ~w(BTC-USD ETH-USD DOGE-USD)

  @price %{"BTC-USD" => "77845.79", "ETH-USD" => "2951.40", "DOGE-USD" => "0.1234"}

  # Fixed, not `utc_now/0`: a fake that stamps the current clock cannot be used to test
  # anything about freshness, and is itself the substitution this family refuses.
  @at ~U[2026-08-28 12:00:00Z]

  # The account's cash — mirrors the real venue's `buying_power`/`buying_power_currency`
  # on the account row `get_accounts/2` answers, and what `get_balances/2` appends as a
  # `Balance` (dp-exchange-core issue #35). Kept as attributes so the two stay consistent
  # with each other rather than two separately hand-typed figures drifting apart.
  @cash_currency "USD"
  @cash_amount "1000.00"

  # The one account the fake holds. `get_balances/2` answers only for it, as
  # `Rest.get_balances/2` answers only for an account `get_accounts/2` lists and otherwise
  # returns `{:account_not_found, account}`. Accepting any number let a consumer that
  # passed the wrong account see a portfolio here and a refusal against the venue.
  @account_number "RH-1"

  @impl true
  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def start_link(_opts), do: :ignore

  @impl true
  def provider_name, do: DpExchange.Robinhood.provider_name()
  @impl true
  def runtime_id, do: DpExchange.Robinhood.runtime_id()
  @impl true
  def asset_classes, do: DpExchange.Robinhood.asset_classes()
  @impl true
  def capabilities, do: DpExchange.Robinhood.capabilities()

  # This venue has no last-trade endpoint at all — see `DpExchange.Robinhood`'s moduledoc
  # on `get_price/2`, `:unsupported` since DpCryptoManagement's issue #21. A fake that kept
  # answering here, backed by `@price`, would make that gap untestable.
  @impl true
  def get_price(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_top_of_book(symbol, opts \\ []) do
    with_injection(symbol, fn ->
      with :ok <- fake_symbol(symbol),
           :ok <- authenticated(opts) do
        listed_book(symbol)
      end
    end)
  end

  # The book for a symbol, with no credential check — `get_top_of_book/2` gates it and
  # `subscribe/2` (whose real counterpart holds its credentials from boot) calls it directly.
  #
  # Canonicalised the way the real path is: `Rest.get_top_of_book/3` sends
  # `SymbolFormat.to_exchange_symbol/1` and answers under `to_canonical_symbol/1`, so `btc-usd`
  # is served as `BTC-USD`. Looked up verbatim, this fake refused `:not_listed` for a symbol
  # the real package serves.
  defp listed_book(symbol) do
    canonical = SymbolFormat.to_canonical_symbol(symbol)

    case Map.fetch(@price, canonical) do
      {:ok, price} ->
        {:ok,
         %Types.TopOfBook{
           symbol: canonical,
           # A spread straddling the traded price, equal to neither side.
           bid: Decimal.sub(Decimal.new(price), Decimal.new("0.01")),
           ask: Decimal.add(Decimal.new(price), Decimal.new("0.01")),
           bid_size: nil,
           ask_size: nil,
           # `nil`, always — matching `Rest.get_top_of_book/3` exactly. v2's
           # `best_bid_ask` schema (`V2BestBidAsk`) has no `timestamp` property at
           # all, so the real venue can never populate this field; a fake that filled
           # it with `@at` would hand a consumer's freshness check a value the real
           # venue can never produce. See this module's `Rest.get_top_of_book/3` doc.
           venue_time: nil,
           observed_at: @at,
           provider: :robinhood
         }}

      :error ->
        unlisted(canonical)
    end
  end

  # The venue's own answer for a symbol it does not list, as `Rest` delivers it: a 400 whose
  # detail names the symbol, measured live (DpCryptoManagement issue #25:
  # `{:venue_error, 400, "Invalid symbol: ALGO-USD"}`). This fake answered
  # `{:refused, :not_listed}`, a shape the real package never returns — see `Rest`'s
  # `result_for/2` comment — so a consumer matching on it passed here and never matched there.
  defp unlisted(canonical),
    do: {:refused, {:venue_error, 400, "Invalid symbol: " <> canonical}}

  @impl true
  def get_symbols(opts \\ []) do
    with_injection(fn ->
      # Sorted, as `Rest.get_symbols/2` sorts what it collects.
      with :ok <- authenticated(opts), do: {:ok, Enum.sort(@symbols)}
    end)
  end

  @impl true
  def get_historical_prices(_symbol, _timeframe, _range, _opts), do: Venue.not_supported()
  @impl true
  def get_order_book(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_trades(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_auction_imbalance(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_volume_profile(_symbol, _timeframe, _opts \\ []), do: Venue.not_supported()
  @impl true
  def get_market_overview(_opts), do: Venue.not_supported()
  @impl true
  def list_instruments(opts) do
    with_injection(fn ->
      with :ok <- authenticated(opts), do: {:ok, Enum.map(@symbols, &fake_instrument/1)}
    end)
  end

  # Base and quote split trivially off the fake's own single-quote symbols — the same
  # thing the real venue's `asset_code`/`quote_code` fields give directly, and the same
  # reason `Core.Instrument`'s moduledoc calls this catalogue shape "ceremony" to require.
  defp fake_instrument(symbol) do
    [base, quote_asset] = String.split(symbol, "-", parts: 2)
    # `status:` stated: Core no longer defaults an unstated status to `:tradable`, and every
    # pair this fake lists is one it serves.
    Instrument.new(
      symbol: symbol,
      base: base,
      quote: quote_asset,
      instrument: :spot,
      status: :tradable
    )
  end

  @impl true
  def get_balances(credentials, opts) do
    with_injection(fn ->
      with {:ok, account} <- fake_account(opts),
           {:ok, asset_codes} <- Rest.asset_codes(opts),
           :ok <- authenticated_credentials(credentials),
           :ok <- held_account(account) do
        # Total above available: the difference is a balance sitting in an open order, which
        # is the case a consumer reading only one of them gets wrong. `hold` stays nil, as in
        # the package — the venue publishes no such figure.
        holding = %Types.Balance{
          currency: "BTC",
          balance: Decimal.new("1.5"),
          available_balance: Decimal.new("1.0"),
          hold: nil,
          timestamp: DateTime.utc_now(),
          provider: :robinhood
        }

        # The account's cash, appended the same way `Rest.get_balances/2` appends it —
        # dp-exchange-core issue #35 — from this fake's own `get_accounts/2` account row,
        # so the two stay consistent with each other. `balance` is `nil` for the same
        # reason: the venue states no total cash figure, only what is available.
        # `:asset_codes` narrows the holdings too — the real path sends them as `asset_code`
        # query parameters and the venue returns only those assets. Answering BTC to a caller
        # who asked for ETH was a holding the real venue would not have sent.
        holdings = if narrowed_to?(asset_codes, holding.currency), do: [holding], else: []
        cash = if narrowed_to?(asset_codes, @cash_currency), do: [fake_cash_balance()], else: []

        {:ok, holdings ++ cash}
      end
    end)
  end

  defp narrowed_to?(asset_codes, currency), do: asset_codes == [] or currency in asset_codes

  defp fake_cash_balance do
    %Types.Balance{
      currency: @cash_currency,
      balance: nil,
      available_balance: Decimal.new(@cash_amount),
      hold: nil,
      timestamp: DateTime.utc_now(),
      provider: :robinhood
    }
  end

  @impl true
  def get_accounts(credentials, _opts) do
    with_injection(fn ->
      with :ok <- authenticated_credentials(credentials) do
        {:ok,
         [
           %{
             "account_number" => @account_number,
             "status" => "active",
             "buying_power" => @cash_amount,
             "buying_power_currency" => @cash_currency
           }
         ]}
      end
    end)
  end

  @impl true
  def get_fees(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_transfers(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def place_order(credentials, request, opts \\ []) do
    with_injection(fn ->
      # The order `Rest.place_order/3` refuses in: the request (unknown keys, symbol, side,
      # type, duration, size, prices), its `client_order_id`, the account option, and only
      # then credentials. An empty request used to be accepted here and answered with an open
      # order of all-`nil` fields, a success the real package can never give.
      with {:ok, parts} <- Rest.normalize_order_request(request),
           {:ok, key} <- Rest.supplied_client_order_id(request, opts),
           {:ok, _account} <- fake_account(opts),
           :ok <- authenticated_credentials(credentials) do
        # `open`, not `filled`: an accepted order is not an executed one, and a fake that
        # filled every order would let a consumer ship code that never handles a resting one.
        {:ok, place_once(parts, key)}
      end
    end)
  end

  # The order as `Rest` decodes it from the venue's reply, not the request echoed back:
  # a canonical symbol, `Decimal` amounts (a `Types.Order` carries no float or string
  # amount, and this echoed `quantity: "1"` and `0.00001` verbatim), the contract's own
  # `:stop` for the venue's `stop_loss`, and `price` / `stop_price` / `time_in_force` only for
  # the types whose config carries them -- `limit_order_config` echoes no `time_in_force`
  # on a read (`Rest`'s comment above `@tif_names`), and a market order has no price at all.
  # `parts` is `Rest.normalize_order_request/1`'s answer, so the side is an atom, the type is
  # the contract's and every amount is a validated wire string.
  defp fake_order(parts) do
    type = parts.type
    now = DateTime.utc_now()

    %Types.Order{
      id: next_order_id(),
      symbol: SymbolFormat.to_canonical_symbol(parts.symbol),
      side: parts.side,
      order_type: type,
      time_in_force: if(type in [:stop, :stop_limit], do: parts.time_in_force),
      quantity: Decimal.new(parts.quantity),
      price: parts.price && Decimal.new(parts.price),
      stop_price: parts.stop_price && Decimal.new(parts.stop_price),
      filled_quantity: Decimal.new("0"),
      average_price: nil,
      status: :open,
      fee: nil,
      fee_currency: nil,
      created_at: now,
      updated_at: now,
      provider: :robinhood
    }
  end

  # A UUID, per order: `OrderResponse.id` is `format: uuid` ("Unique per order",
  # `docs/reference/robinhood/openapi/crypto-trading.openapi.json`). The fake issued the one
  # literal `rh-order-1` for every placement, which is not a UUID and collided across two
  # orders in the same test. Counted per process, so it is deterministic and two async tests
  # never see each other's sequence; `get_order/3` and `cancel_order/3` accept any non-blank
  # id, as `Rest` does, so what was issued here is what they take back.
  @order_id_prefix "7b3c1f0e-5a2d-4c8e-9f41-"
  @order_counter_key {__MODULE__, :order_counter}
  # Orders this process placed, by id: what `get_order/3`, `get_orders/2` and `cancel_order/3`
  # answer from.
  @orders_key {__MODULE__, :orders}
  # `client_order_id` -> order id, for the idempotency the venue gives that key.
  @keys_key {__MODULE__, :client_order_ids}

  defp next_order_id do
    count = Process.get(@order_counter_key, 0) + 1
    Process.put(@order_counter_key, count)

    suffix = count |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")
    @order_id_prefix <> suffix
  end

  @impl true
  def place_orders(_credentials, _requests, _opts), do: Venue.not_supported()

  # Both refused, matching the real venue. A fake that answered where the real one
  # refuses lets a consumer's suite go green against behaviour that cannot happen.
  @impl true
  def preview_order(_credentials, _request, _opts \\ []), do: Venue.not_supported()

  @impl true
  def replace_order(_credentials, _id, _request, _opts \\ []), do: Venue.not_supported()

  @impl true
  def preview_replace(_credentials, _id, _changes, _opts \\ []), do: Venue.not_supported()

  @impl true
  def close_position(_credentials, _symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def cancel_all_orders(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def cancel_order(credentials, id, _opts \\ []) do
    with_injection(fn ->
      # `:cancelled`, matching `Rest.cancel_order/3`: the v2 endpoint this venue calls
      # returns a full `V2CryptoOrder` reflecting the venue's real state, not a bare
      # acknowledgement. A fake that answered `:open` here — the v1 behaviour, and the
      # wrong one for the v2 endpoint this package actually calls — would be "differently
      # capable" than the real adapter for the ordinary case: a consumer's test would see a
      # cancel confirmed here that the real venue would report cancelled for.
      #
      # No account check, matching `Rest.cancel_order/3`: this is the one order call that
      # takes no `account_number` — but it is still signed, so credentials are still
      # required.
      #
      # The order this process placed, now cancelled, in full: the symbol, side and size the
      # caller placed, not a bare `nil`-filled acknowledgement. An id this fake never issued
      # is the venue's 404, as `Rest` delivers it.
      with :ok <- fake_order_id(id),
           :ok <- authenticated_credentials(credentials),
           {:ok, order} <- find_order(id) do
        {:ok, remember_order(%{order | status: :cancelled, updated_at: DateTime.utc_now()})}
      end
    end)
  end

  @impl true
  def get_order(credentials, id, opts \\ []) do
    with_injection(fn ->
      # The id first, then the account option, then credentials: `Rest.get_order/3`'s order.
      with :ok <- fake_order_id(id),
           {:ok, _account} <- fake_account(opts),
           :ok <- authenticated_credentials(credentials) do
        find_order(id)
      end
    end)
  end

  @impl true
  def get_orders(credentials, opts \\ []) do
    with_injection(fn ->
      with {:ok, _account} <- fake_account(opts),
           :ok <- Rest.validate_order_filters(opts),
           :ok <- fake_cursor(Keyword.get(opts, :cursor)),
           :ok <- authenticated_credentials(credentials) do
        placed = @orders_key |> Process.get(%{}) |> Map.values() |> Enum.sort_by(& &1.id)
        {:ok, Enum.filter(placed, &order_matches?(&1, opts))}
      end
    end)
  end

  # The venue-side filters `Rest.get_orders/2` sends (`symbol`, `side`, `state`), applied to
  # what this process placed, so a caller asking for cancelled ETH-USD orders is not handed
  # an open BTC-USD one.
  defp order_matches?(order, opts) do
    in_window?(order.created_at, opts, :created_at_start, :created_at_end) and
      in_window?(order.updated_at, opts, :updated_at_start, :updated_at_end) and
      wanted?(Keyword.get(opts, :symbol), order.symbol, &SymbolFormat.to_canonical_symbol/1) and
      wanted?(Keyword.get(opts, :side), to_string(order.side), &to_string/1) and
      wanted?(Keyword.get(opts, :type), to_string(order.order_type), &type_name/1) and
      wanted?(Keyword.get(opts, :state), to_string(order.status), &state_name/1)
  end

  # `Rest`'s `:type` filter takes the contract's `:stop` or the venue's `stop_loss`, and an
  # order's `order_type` is the contract's. The fake ignored `:type` altogether, so a caller
  # asking for limit orders was handed every order placed.
  defp type_name(type) when type in [:stop, :stop_loss, "stop", "stop_loss"], do: "stop"
  defp type_name(type), do: to_string(type)

  # The date filters, on what this process recorded (`created_at`, and `updated_at` which a
  # cancel moves). Both bounds inclusive: the vendor's document does not say, so this is
  # unmeasured and a test should not rest on the boundary instant. `Rest.validate_order_
  # filters/1` has already refused anything that is not a `%DateTime{}` or an ISO 8601 string.
  defp in_window?(at, opts, start_key, end_key) do
    after_start?(at, Keyword.get(opts, start_key)) and before_end?(at, Keyword.get(opts, end_key))
  end

  defp after_start?(at, bound), do: bound_ok?(bound, &(DateTime.compare(at, &1) != :lt))
  defp before_end?(at, bound), do: bound_ok?(bound, &(DateTime.compare(at, &1) != :gt))

  defp bound_ok?(bound, check) do
    case Rest.filter_instant(bound) do
      {:ok, nil} -> true
      {:ok, instant} -> check.(instant)
    end
  end

  # The fake holds one page and issues no cursor, so any cursor is one it never gave out.
  # Refused rather than ignored: ignoring it would answer page one for a caller asking for
  # page two. `:limit` needs nothing here -- the venue's endpoint has no `limit` parameter,
  # it only stops `Rest` walking `next`, and this fake has no `next` to walk.
  defp fake_cursor(nil), do: :ok
  defp fake_cursor(_cursor), do: {:error, {:invalid_field, :cursor}}

  defp wanted?(nil, _actual, _normalise), do: true
  defp wanted?(wanted, actual, normalise), do: normalise.(wanted) == actual

  # The venue's spelling of a state, as `Rest.order_state_param/1` sends it, back to the
  # contract's status name.
  defp state_name(state) when state in ["canceled", :canceled, :cancelled], do: "cancelled"
  defp state_name(state) when state in ["failed", :rejected], do: "rejected"
  defp state_name(state), do: to_string(state)

  # An order this process placed. Anything else is an id the fake never issued, which the
  # venue answers with a 404, which `Rest` delivers as `{:refused, :not_found}`. This
  # answered a canned BTC-USD partially-filled order for ANY id.
  defp find_order(id) do
    case Map.fetch(Process.get(@orders_key, %{}), id) do
      {:ok, _order} = found -> found
      :error -> {:refused, :not_found}
    end
  end

  defp remember_order(%Types.Order{id: id} = order) do
    Process.put(@orders_key, Map.put(Process.get(@orders_key, %{}), id, order))
    order
  end

  # `client_order_id` is the venue's idempotency key (`Rest.place_order/3`'s doc): sending
  # the same one again returns the original order instead of placing a second. A fake that
  # placed a second let a consumer's retry-after-timeout test pass against behaviour the
  # venue does not have. The key is read where `Rest` reads it (the request first, then
  # `opts`), a blank or non-string one is no key, and the original is returned as it now
  # stands (a cancel since is visible), not as first placed.
  #
  # `key` is `Rest.supplied_client_order_id/2`'s answer, already checked to be a UUID (or
  # absent). UUIDs are hex, so case is not part of the identity: kept lower-cased.
  defp place_once(parts, key) do
    with key when is_binary(key) <- key && String.downcase(key),
         {:ok, id} <- Map.fetch(Process.get(@keys_key, %{}), key),
         {:ok, original} <- Map.fetch(Process.get(@orders_key, %{}), id) do
      original
    else
      _no_original ->
        order = remember_order(fake_order(parts))
        remember_key(key && String.downcase(key), order)
        order
    end
  end

  defp remember_key(nil, _order), do: :ok

  defp remember_key(key, %Types.Order{id: id}) do
    Process.put(@keys_key, Map.put(Process.get(@keys_key, %{}), key, id))
    :ok
  end

  # `Rest.get_order/3` and `Rest.cancel_order/3` refuse a blank id before signing anything
  # (an empty path segment is a different endpoint). The fake answered an order for `""`.
  defp fake_order_id(id) when is_binary(id) do
    if String.trim(id) == "", do: {:error, {:invalid_order_id, id}}, else: :ok
  end

  defp fake_order_id(not_a_string), do: {:error, {:invalid_order_id, not_a_string}}

  # `Rest` refuses a symbol that is not a non-empty string before signing; the canonicaliser
  # raises on one.
  defp fake_symbol(symbol) when is_binary(symbol) do
    if String.trim(symbol) == "", do: {:error, {:invalid_symbol, symbol}}, else: :ok
  end

  defp fake_symbol(other), do: {:error, {:invalid_symbol, other}}

  # After credentials, as in `Rest.get_balances/2`: the lookup needs the signed
  # `get_accounts/2` reply before it can say an account is not there.
  defp held_account(@account_number), do: :ok
  defp held_account(account), do: {:error, {:account_not_found, account}}

  # v2 takes the account number where v1 took none. A fake that answered without it would
  # let a v1 habit pass here and fail against the venue.
  defp fake_account(opts) do
    case Keyword.get(opts, :account_number) do
      account when is_binary(account) ->
        if String.trim(account) == "",
          do: {:error, {:missing_option, :account_number}},
          else: {:ok, account}

      _missing ->
        {:error, {:missing_option, :account_number}}
    end
  end

  @impl true
  def get_transactions(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def list_payment_methods(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def get_payment_method(_credentials, _id, _opts), do: Venue.not_supported()

  @impl true
  def add_payment_method(_details, _opts), do: Venue.not_supported()

  @impl true
  def transfer_internal(_asset, _amount, _opts, _request_opts), do: Venue.not_supported()

  @impl true
  def request_approved_address(_asset, _network, _address, _opts), do: Venue.not_supported()

  @impl true
  def remove_approved_address(_network, _address, _opts), do: Venue.not_supported()

  @impl true
  def list_networks(_asset, _opts), do: Venue.not_supported()

  @impl true
  def list_fee_promos(_opts), do: Venue.not_supported()

  @impl true
  def get_fx_rate(_pair, _at, _opts), do: Venue.not_supported()

  @impl true
  def get_notional_balances(_credentials, _currency, _opts), do: Venue.not_supported()

  @impl true
  def list_custody_fees(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_trade_history(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def test_connection(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_rate_limit_status(_credentials, _opts), do: Venue.not_supported()
  # `Venue.quantization/1` is the required arity, but the real `DpExchange.Robinhood.
  # quantization/2` takes a second, `opts`, argument beyond it — the only place credentials
  # can travel, because this venue signs `trading_pairs` same as every other call. A fake
  # that only defined arity 1 could never be swapped in for a caller using the real facade's
  # own documented signature (`quantization(symbol, opts)`) — `Fake.quantization/2` would be
  # undefined — and even at arity 1 it answered success unconditionally, never checking
  # `credentials:`, while the real `Rest.quantization/3` fails without them. Both are the
  # "differently capable" defect `usage-rules/testing.md` warns about: less capable than the
  # real adapter is fine, differently capable is not. Matches `get_top_of_book/2`,
  # `get_symbols/1` and `list_instruments/1` above, and — since this same audit found the
  # account and trading surface below had the identical gap — `get_balances/2`,
  # `get_accounts/2`, `place_order/3`, `cancel_order/3`, `get_order/3` and `get_orders/2`
  # too: every one of them now gates on `authenticated/1` or `authenticated_credentials/1`.
  @impl true
  def quantization(symbol, opts \\ []) do
    with_injection(symbol, fn ->
      with :ok <- fake_symbol(symbol),
           :ok <- authenticated(opts),
           true <- listed?(symbol) || unlisted(SymbolFormat.to_canonical_symbol(symbol)) do
        {:ok,
         %{
           price_increment: Decimal.new("0.01"),
           quantity_increment: Decimal.new("0.00000001"),
           min_quantity: nil,
           max_quantity: Decimal.new("1000"),
           min_quote_size: Decimal.new("1.00"),
           status: "tradable"
         }}
      end
    end)
  end

  # Matches the real facade — see `DpExchange.Robinhood.market_status/1`'s own doc for
  # why `:open` is the complete answer here rather than a guess: this venue's only asset
  # class is crypto, which has no exchange-mandated session to answer about.
  @impl true
  def market_status(_opts) do
    with_injection(fn -> {:ok, :open} end)
  end

  # Per-process, like the order book above: what was asked for, what a book was delivered
  # for, and who receives. Coverage reads only `@delivered_key`.
  @wanted_key {__MODULE__, :wanted}
  @delivered_key {__MODULE__, :delivered}
  @subscribers_key {__MODULE__, :subscribers}

  @impl true
  def subscribe(symbols, opts \\ []) do
    # The same checks, in the same order, as the real facade: symbols, then the subscriber.
    with {:ok, symbols} <- Feed.canonical_symbols(symbols),
         {:ok, to} <- Feed.valid_subscriber(Config.opt(opts, :to, self())) do
      do_subscribe(symbols, to)
    end
  end

  defp do_subscribe(symbols, to) do
    # **`opts[:to]` is honoured, default the caller**, as the real facade does: the pid is
    # registered as a data subscriber and receives this call's books, as would a poll
    # cycle's. `subscribe([])` registers it and delivers nothing.
    Process.put(@subscribers_key, MapSet.put(subscribers(), to))

    # A symbol the venue does not list is delivered as the refusal the real feed delivers for
    # it (`Feed`'s `on_refusal`), not skipped without a word: a consumer's refusal handling
    # was never reached by its tier-1 tests.
    deliver(symbols)

    # **Added to, never replacing.** This was the identical line `update_symbols/2`
    # carries below — the two callbacks were byte-for-byte the same function — so a
    # second `subscribe/2` dropped whatever the first had subscribed. The real
    # facade unions (`wanted: MapSet.union(state.wanted, MapSet.new(symbols))` in
    # `Feed`), so a consumer's tier-1 tests against this fake certified the opposite
    # of what the venue does: subscribe twice, keep one symbol here, keep both there.
    #
    # The contract settles which is right without needing a new sentence in it.
    # `c:DpExchange.Core.Venue.update_symbols/2` exists to "change a live
    # subscription's symbol set", and `c:unsubscribe/2` to stop delivery for named
    # symbols. Neither has any purpose if `subscribe/2` already replaces — you would
    # just subscribe the new list. Two callbacks the contract distinguishes,
    # implemented as one function, is the tell.
    Process.put(@wanted_key, MapSet.union(wanted(), MapSet.new(symbols)))

    :ok
  end

  @impl true
  def unsubscribe(symbols, _opts \\ []) do
    with {:ok, symbols} <- Feed.canonical_symbols(symbols) do
      Process.put(@wanted_key, MapSet.difference(wanted(), MapSet.new(symbols)))
      Process.put(@delivered_key, MapSet.difference(delivered(), MapSet.new(symbols)))
      :ok
    end
  end

  # Honours no `:to`, as the real `update_symbols/2` does not: it changes the polled set and
  # the books reach whoever `subscribe/2` registered. A symbol newly in the set is delivered
  # to those subscribers (a poll cycle's worth); with none registered nothing is delivered.
  @impl true
  def update_symbols(symbols, _opts \\ []) do
    with {:ok, symbols} <- Feed.canonical_symbols(symbols) do
      added = Enum.reject(symbols, &MapSet.member?(wanted(), &1))
      Process.put(@wanted_key, MapSet.new(symbols))
      Process.put(@delivered_key, MapSet.intersection(delivered(), MapSet.new(symbols)))
      deliver(added)
      :ok
    end
  end

  # `:internal_poll`, not `:stream`. The real venue has no socket, and a fake claiming one
  # would let a consumer build on a route that does not exist. Only symbols this fake has
  # actually delivered a book for: `update_symbols/2` with nobody subscribed delivers
  # nothing, and a refused symbol never delivers, so neither is covered.
  @impl true
  def coverage(_opts \\ []), do: Map.new(delivered(), &{&1, :internal_poll})

  @doc """
  `coverage/1`, split by kind. Same single-key shape as the real venue, and for the
  same reason: `get_top_of_book/2` above is this fake's only source of subscription
  data and it produces exclusively `Types.TopOfBook`, so `:top_of_book` is the only
  kind there is to report — see `DpExchange.Robinhood.coverage_by_kind/1` for why the
  family requires this callback even where a venue has nothing to split.
  """
  @impl true
  @spec coverage_by_kind(keyword()) ::
          %{Capabilities.data_kind() => %{Venue.symbol() => Venue.route()}}
  def coverage_by_kind(opts \\ []), do: %{top_of_book: coverage(opts)}

  @doc """
  Answers `:ok` for a registration of `opts[:to]` against this venue's own notices. The real
  facade honours `:to`; this fake has no feed and raises no notices,
  so it accepts the call and registers nothing — see this module's moduledoc.

  Routed through `with_injection/2`, unlike `subscribe/2`, `unsubscribe/2` and
  `update_symbols/2`: this call carries no symbol list, so there is no "one symbol in the
  batch" case for whole-call injection to fail at. That is what makes
  `{:error, :feed_not_started}` — the real facade's answer when its feed is not running —
  reachable here at all: `FakeInjection.fail_always(:robinhood, {:error, :feed_not_started})`
  or `queue_failures/2,3` produces it, exactly as they produce any other queued outcome.
  With nothing queued, this fake has no feed of its own to be down, so it answers `:ok` --
  except for a `:to` that is neither a pid nor a registered name, which is refused as
  `{:error, {:invalid_subscriber, to}}`, as the real feed refuses it. Registers nothing and
  sends no `:link_up`: the real feed sends none on registration either.
  """
  @impl true
  def subscribe_notices(opts \\ []) do
    with_injection(fn ->
      # Refuses what the real feed refuses (`nil` means the caller, as there).
      with {:ok, _to} <- Feed.valid_subscriber(Config.opt(opts, :to, self())), do: :ok
    end)
  end

  defp wanted, do: Process.get(@wanted_key, MapSet.new())
  defp delivered, do: Process.get(@delivered_key, MapSet.new())
  defp subscribers, do: Process.get(@subscribers_key, MapSet.new())

  # Sends each wanted symbol's book (or the venue's refusal of it) to every registered
  # subscriber still alive, and records a symbol as delivered only when a book was actually
  # sent to somebody. A registered name nothing holds is skipped, as `Core.Fanout` skips it.
  defp deliver(symbols) do
    # Unique, as `Core.Fanout.deliver/4` is: a process registered both as a pid and by name
    # receives each book once.
    recipients =
      subscribers() |> Enum.map(&Fanout.resolve/1) |> Enum.filter(&is_pid/1) |> Enum.uniq()

    if recipients != [] do
      for symbol <- symbols do
        case listed_book(symbol) do
          {:ok, book} ->
            Enum.each(recipients, &send(&1, {:dp_exchange, :robinhood, book}))
            Process.put(@delivered_key, MapSet.put(delivered(), symbol))

          {:refused, reason} ->
            refusal = {:dp_exchange, :robinhood, {:refused, symbol, reason}}
            Enum.each(recipients, &send(&1, refusal))
        end
      end
    end

    :ok
  end

  defp listed?(symbol), do: Map.has_key?(@price, SymbolFormat.to_canonical_symbol(symbol))

  # Every function that reaches a real endpoint on this venue is signed, market data
  # included — there is no anonymous endpoint to fall back to. `{:error,
  # {:missing_credentials, :robinhood}}` matches `DpExchange.Robinhood.Auth.headers/5`'s
  # own refusal exactly: `:error`, not `:refused`, because a missing local credential never
  # reaches the venue at all and is not the venue's word about anything — see
  # `DpExchange.Core.Venue`'s moduledoc on the two, and this module's own moduledoc.
  defp authenticated(opts), do: authenticated_credentials(Keyword.get(opts, :credentials))

  defp authenticated_credentials(credentials) do
    if FakeInjection.credentials_bypassed?(:robinhood) do
      :ok
    else
      # The real path's own rules (`Auth.validate_credentials/1`): a blank key is
      # `:missing_credentials` and a private key that is not the base64 32-byte seed is
      # `:invalid_private_key`. Any map with both keys used to pass here.
      Auth.validate_credentials(credentials)
    end
  end

  defp with_injection(symbol \\ nil, fun) do
    case FakeInjection.next_outcome(:robinhood, symbol) do
      {:override, outcome} -> outcome
      :none -> fun.()
    end
  end

  # --- Declared but not yet implemented -----------------------------------
  #
  # Core 0.1.16 widened the facade to the surface the venues actually publish. These answer
  # `{:error, :not_supported}` and are declared `:unsupported` in `capabilities/0`, so a
  # consumer routing on the declaration is told the truth.
  #
  # **`:unsupported` here is a statement about this package, not about the venue.** That
  # distinction is the one Phase 1 had to correct after a package spent a year asserting a
  # venue had no streaming API when it had fifteen services. Where the venue genuinely does
  # not offer something, the comment beside it says so.

  @impl true
  def get_positions(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_funding(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_contract_stats(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_rates(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_balances(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_rewards(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_history(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def stake(_asset, _amount, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def unstake(_asset, _amount, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def quote_conversion(_from, _to, _amount, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def commit_conversion(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_conversion(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def convert(_from, _to, _amount, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_trade_volume(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def list_portfolios(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_deposit_address(_asset, _network, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def list_approved_addresses(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def estimate_withdrawal_fee(_asset, _network, _amount, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def withdraw(_asset, _network, _amount, _address, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_option_chain(_underlying, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_option_expirations(_underlying, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_option_greeks(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def list_watchlists(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def create_watchlist(_name, _symbols, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def update_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def delete_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_financials(_symbol, _kind, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_corporate_events(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_filings(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_news(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_screener(_name, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def create_account(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def rename_account(_id, _name, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_roles(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  # Symbol lists are checked and upper-cased by `Feed.canonical_symbols/1`, the same function
  # the real facade uses, so a lower-case subscription and a malformed list get the same
  # answer here as against the venue.
end
