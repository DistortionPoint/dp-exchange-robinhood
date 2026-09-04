defmodule DpExchange.Robinhood.Fake do
  @moduledoc """
  An in-process Robinhood, for a consumer's tier-1 tests and for the conformance suite.

  **It is not a mock.** A real implementation of `DpExchange.Core.Venue` answering from
  memory, running the *same* conformance suite as the real adapter.

  ## What it models that is specific to this venue

  - **Credentials are required for market data**, because the real venue signs every call
    and has no anonymous endpoint. Without them: `{:refused, :missing_credentials}`.
  - **Coverage is `:internal_poll`, not `:stream`** — the one place a consumer can see that
    this venue has no socket, and it shows up as *what is arriving*, never as *how*.
  - **No candles, no order book, no volume.** The venue serves none, so neither does this.

  ## Failure injection and anonymous mode

  Every function below that has a real success path (not an unconditional
  `Venue.not_supported()`) checks `DpExchange.Core.FakeInjection.next_outcome/1` or `/2`
  first — a queued or always-set outcome from `FakeInjection.queue_failures/2,3` or
  `fail_always/2,3` short-circuits the fake's normal logic and is returned as-is.
  `authenticated/1` also checks `FakeInjection.credentials_bypassed?/1` before its normal
  `{:refused, :missing_credentials}` path. Neither changes anything for a test that never
  calls `FakeInjection` — see that module for the full contract.

  `subscribe/2`, `unsubscribe/2` and `update_symbols/2` are NOT wired: each takes a list
  of symbols in one call, and "this one symbol in the batch fails, the rest succeed" is a
  case whole-call injection cannot express — see `FakeInjection`'s own moduledoc.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.{FakeInjection, Types, Venue}

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

  @impl true
  def get_price(symbol, opts \\ []) do
    with_injection(symbol, fn ->
      with :ok <- authenticated(opts) do
        case Map.fetch(@price, symbol) do
          {:ok, price} ->
            {:ok,
             %Types.Quote{
               symbol: symbol,
               # A traded price, and only that. This used to be the ask, with a comment
               # citing "what the real adapter uses when the venue sends no separate price" —
               # a fallback removed in Phase 1 because an ask is a resting order and a price
               # is an execution. A fake that reproduces a defect makes the defect untestable.
               price: Decimal.new(price),
               volume: nil,
               timestamp: @at,
               provider: :robinhood
             }}

          :error ->
            {:refused, :not_listed}
        end
      end
    end)
  end

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
               venue_time: @at,
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
  def list_instruments(_opts), do: Venue.not_supported()
  @impl true
  def get_balances(_credentials, opts) do
    with_injection(fn ->
      with {:ok, _account} <- fake_account(opts) do
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
  def get_accounts(_credentials, _opts) do
    with_injection(fn ->
      {:ok, [%{"account_number" => "RH-1", "status" => "active", "buying_power" => "1000.00"}]}
    end)
  end

  @impl true
  def get_fees(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_transfers(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def place_order(_credentials, request, opts) do
    with_injection(fn ->
      with {:ok, _account} <- fake_account(opts) do
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
  def cancel_order(_credentials, id, _opts) do
    with_injection(fn ->
      # `:open`, not `:cancelled` — the venue acknowledges the request and reports no
      # outcome, and a fake that said cancelled would let a consumer stop watching an order
      # that is still live.
      {:ok,
       %Types.Order{
         id: id,
         symbol: nil,
         side: nil,
         order_type: nil,
         quantity: nil,
         status: :open,
         provider: :robinhood
       }}
    end)
  end

  @impl true
  def get_order(_credentials, id, opts) do
    with_injection(fn ->
      with {:ok, _account} <- fake_account(opts) do
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
  def get_orders(_credentials, opts) do
    with_injection(fn ->
      with {:ok, _account} <- fake_account(opts), do: {:ok, []}
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
  @impl true
  def quantization(symbol) do
    with_injection(symbol, fn ->
      {:ok,
       %{
         price_increment: Decimal.new("0.01"),
         quantity_increment: Decimal.new("0.00000001"),
         min_quantity: nil,
         max_quantity: Decimal.new("1000"),
         min_quote_size: Decimal.new("1.00"),
         status: "tradable"
       }}
    end)
  end

  @impl true
  def market_status(_opts) do
    with_injection(fn -> {:ok, :open} end)
  end

  @impl true
  def subscribe(symbols, opts \\ []) do
    target = Keyword.get(opts, :to, self())

    for symbol <- symbols, symbol in @symbols do
      case get_price(symbol, credentials: %{api_key: "fake", private_key: "fake"}) do
        {:ok, quote_struct} -> send(target, {:dp_exchange, :robinhood, quote_struct})
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

  @impl true
  def subscribe_notices(_opts \\ []), do: :ok

  defp subscribed, do: Process.get(__MODULE__, MapSet.new())

  defp authenticated(opts) do
    if FakeInjection.credentials_bypassed?(:robinhood) do
      :ok
    else
      case Keyword.get(opts, :credentials) do
        %{api_key: _key, private_key: _private} -> :ok
        _absent -> {:refused, :missing_credentials}
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
