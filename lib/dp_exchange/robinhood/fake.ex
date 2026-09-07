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
  - **`subscribe/2` takes no `:to`.** The real venue's `c:DpExchange.Core.Venue.subscribe/2`
    has no notion of a per-call recipient — data reaches whoever the feed was supervised
    with, fixed at boot
    — so this fake ignores it too and always delivers to the calling process, the same way
    a caller of the real facade receives from whichever process it supervised the feed
    under. `subscribe_notices/2` is the one call on this venue that legitimately takes
    `:to` — `DpExchange.Robinhood.Feed`'s own per-call notice registry — and this fake
    honours it there, correctly.

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

  alias DpExchange.Core.{Capabilities, FakeInjection, Instrument, Types, Venue}

  @symbols ~w(BTC-USD ETH-USD DOGE-USD)

  @price %{"BTC-USD" => "77845.79", "ETH-USD" => "2951.40", "DOGE-USD" => "0.1234"}

  # Fixed, not `utc_now/0`: a fake that stamps the current clock cannot be used to test
  # anything about freshness, and is itself the substitution this family refuses.
  @at ~U[2026-08-28 12:00:00Z]

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
      with :ok <- authenticated(opts) do
        case Map.fetch(@price, symbol) do
          {:ok, price} ->
            {:ok,
             %Types.TopOfBook{
               symbol: symbol,
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
            {:refused, :not_listed}
        end
      end
    end)
  end

  @impl true
  def get_symbols(opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(opts), do: {:ok, @symbols}
    end)
  end

  @impl true
  def get_historical_prices(_symbol, _timeframe, _range, _opts), do: Venue.not_supported()
  @impl true
  def get_order_book(_symbol, _opts), do: Venue.not_supported()

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
    Instrument.new(symbol: symbol, base: base, quote: quote_asset, instrument: :spot)
  end

  @impl true
  def get_balances(credentials, opts) do
    with_injection(fn ->
      with {:ok, _account} <- fake_account(opts),
           :ok <- authenticated_credentials(credentials) do
        # Total above available: the difference is a balance sitting in an open order, which
        # is the case a consumer reading only one of them gets wrong. `hold` stays nil, as in
        # the package — the venue publishes no such figure.
        {:ok,
         [
           %Types.Balance{
             currency: "BTC",
             balance: Decimal.new("1.5"),
             available_balance: Decimal.new("1.0"),
             hold: nil,
             timestamp: DateTime.utc_now(),
             provider: :robinhood
           }
         ]}
      end
    end)
  end

  @impl true
  def get_accounts(credentials, _opts) do
    with_injection(fn ->
      with :ok <- authenticated_credentials(credentials) do
        {:ok, [%{"account_number" => "RH-1", "status" => "active", "buying_power" => "1000.00"}]}
      end
    end)
  end

  @impl true
  def get_fees(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_transfers(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def place_order(credentials, request, opts) do
    with_injection(fn ->
      with {:ok, _account} <- fake_account(opts),
           :ok <- authenticated_credentials(credentials) do
        # `open`, not `filled`: an accepted order is not an executed one, and a fake that
        # filled every order would let a consumer ship code that never handles a resting one.
        {:ok,
         %Types.Order{
           id: "rh-order-1",
           symbol: Map.get(request, :symbol),
           side: Map.get(request, :side),
           order_type: Map.get(request, :order_type),
           time_in_force: nil,
           quantity: Map.get(request, :quantity),
           filled_quantity: Decimal.new("0"),
           average_price: nil,
           status: :open,
           fee: nil,
           fee_currency: nil,
           created_at: DateTime.utc_now(),
           provider: :robinhood
         }}
      end
    end)
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
  def cancel_order(credentials, id, _opts) do
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
      with :ok <- authenticated_credentials(credentials) do
        {:ok,
         %Types.Order{
           id: id,
           symbol: nil,
           side: nil,
           order_type: nil,
           quantity: nil,
           status: :cancelled,
           provider: :robinhood
         }}
      end
    end)
  end

  @impl true
  def get_order(credentials, id, opts) do
    with_injection(fn ->
      with {:ok, _account} <- fake_account(opts),
           :ok <- authenticated_credentials(credentials) do
        {:ok,
         %Types.Order{
           id: id,
           symbol: "BTC-USD",
           side: :buy,
           order_type: :limit,
           time_in_force: nil,
           quantity: Decimal.new("0.5"),
           filled_quantity: Decimal.new("0.25"),
           average_price: Decimal.new("60000"),
           status: :partially_filled,
           fee: nil,
           fee_currency: nil,
           created_at: nil,
           provider: :robinhood
         }}
      end
    end)
  end

  @impl true
  def get_orders(credentials, opts) do
    with_injection(fn ->
      with {:ok, _account} <- fake_account(opts),
           :ok <- authenticated_credentials(credentials),
           do: {:ok, []}
    end)
  end

  # v2 takes the account number where v1 took none. A fake that answered without it would
  # let a v1 habit pass here and fail against the venue.
  defp fake_account(opts) do
    case Keyword.get(opts, :account_number) do
      account when is_binary(account) -> {:ok, account}
      _missing -> {:error, {:account_number_required, :robinhood}}
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
      with :ok <- authenticated(opts) do
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

  @impl true
  def market_status(_opts) do
    with_injection(fn -> {:ok, :open} end)
  end

  @impl true
  def subscribe(symbols, _opts \\ []) do
    # Always the caller — never `opts[:to]`. The real `c:subscribe/2` has no notion of a
    # per-call recipient at all: delivery goes to whichever process this venue's feed was
    # supervised with, fixed at boot, and a `:to` passed to the real facade's `subscribe/2`
    # is silently ignored (only `subscribe_notices/2`'s own registry reads it). A fake that
    # honoured it here would let a consumer redirect delivery in a way the real venue
    # cannot, which is exactly the "differently capable" defect this fake exists to avoid.
    caller = self()

    for symbol <- symbols, symbol in @symbols do
      case get_top_of_book(symbol, credentials: %{api_key: "fake", private_key: "fake"}) do
        {:ok, book} -> send(caller, {:dp_exchange, :robinhood, book})
        _refused -> :ok
      end
    end

    Process.put(__MODULE__, MapSet.new(Enum.filter(symbols, &(&1 in @symbols))))
    :ok
  end

  @impl true
  def unsubscribe(symbols, _opts \\ []) do
    Process.put(__MODULE__, MapSet.difference(subscribed(), MapSet.new(symbols)))
    :ok
  end

  @impl true
  def update_symbols(symbols, _opts \\ []) do
    Process.put(__MODULE__, MapSet.new(Enum.filter(symbols, &(&1 in @symbols))))
    :ok
  end

  # `:internal_poll`, not `:stream`. The real venue has no socket, and a fake claiming one
  # would let a consumer build on a route that does not exist.
  @impl true
  def coverage(_opts \\ []), do: Map.new(subscribed(), &{&1, :internal_poll})

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
  Registers `opts[:to]` for this venue's own notices. Unlike `subscribe/2`, `:to` is
  genuine here — see this module's moduledoc.

  Routed through `with_injection/2`, unlike `subscribe/2`, `unsubscribe/2` and
  `update_symbols/2`: this call carries no symbol list, so there is no "one symbol in the
  batch" case for whole-call injection to fail at. That is what makes
  `{:error, :feed_not_started}` — the real facade's answer when its feed is not running —
  reachable here at all: `FakeInjection.fail_always(:robinhood, {:error, :feed_not_started})`
  or `queue_failures/2,3` produces it, exactly as they produce any other queued outcome.
  With nothing queued, this fake has no feed of its own to be down, so it answers `:ok`.
  """
  @impl true
  def subscribe_notices(_opts \\ []) do
    with_injection(fn -> :ok end)
  end

  defp subscribed, do: Process.get(__MODULE__, MapSet.new())

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
      case credentials do
        %{api_key: _key, private_key: _private} -> :ok
        _absent -> {:error, {:missing_credentials, :robinhood}}
      end
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
end
