defmodule DpExchange.Robinhood do
  @moduledoc """
  Robinhood Crypto, behind the DpExchange facade.

  > #### ⚠️ EXPERIMENTAL {: .warning}
  >
  > This package has not run in production. While it is `0.x` the API may change without a
  > major version — pin all three segments. **Maturity is declared per endpoint** through
  > `capabilities/0`; do not read this banner as your check.

  **This module is the entire public API of this package.**

  ## This venue has no streaming API, and you cannot tell

  Robinhood Crypto publishes no socket. `subscribe/2` is served by a REST poll inside this
  package, and it delivers the same `Core.Types.Quote` to the same subscriber as a
  WebSocket venue would.

  That is the sharpest test in the family of §6.0's claim that **both endpoints always
  exist** and a consumer never branches on transport. Before the facade, the absence
  travelled upward: the collection layer kept a poll set and decided which venues were
  exempt, and an operations page described these pairs in terms of a socket the venue does
  not have and has never claimed — sending readers hunting a streaming fault that cannot
  exist.

  `coverage/1` reports `:internal_poll` rather than `:stream`, which is the one place the
  difference is visible — and it is visible as *what is arriving*, never as *how*.

  ## Credentials are required for market data

  Every Robinhood Crypto call is signed with an Ed25519 key, including the quotes. There is
  no anonymous endpoint, so `get_price/2` takes credentials:

      {:ok, quote} = DpExchange.Robinhood.get_price("BTC-USD", credentials: %{
        api_key: "…", private_key: "…"
      })

  You hold the credentials; this package signs one request with them and keeps nothing.

  ## The price is the ask

  `best_bid_ask` returns the prices a taker would actually get. Where the venue sends no
  separate price, the **ask** is used — a real quoted number, and the one a buyer pays. It
  is not a mid and not a last trade, so **a series built from it sits a spread above a
  mid-based series** from another venue. `bid` and `ask` are both carried; what a price
  means is your decision, not this package's.

  ## No candles, no order book, no volume

  The venue publishes none of them. `get_historical_prices/4`, `get_order_book/2` and
  volume are `:unsupported` — the venue's shape, not a gap here. Route that work elsewhere
  rather than discovering an empty series.

  ## Supervision

      children = [{DpExchange.Robinhood, credentials: my_credentials(), symbols: ["BTC-USD"]}]
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.{Capabilities, Venue}
  alias DpExchange.Robinhood.{Feed, Rest, SymbolFormat}

  # The venue serves none of these. That is a claim about Robinhood, not about how far this
  # package got — and the two are worth telling apart, so the account and trading endpoints
  # below are listed separately.
  @venue_does_not_serve [
    # Core 0.1.16 widened the facade. **These are the venue's absence, not this package's
    # backlog**: Robinhood Crypto's entire documented surface is nine endpoints — quotes,
    # estimated price, accounts, holdings, trading pairs and four order operations. It
    # lists no options, runs no staking, has no perpetuals, exposes no conversion, no
    # deposit or withdrawal, no watchlists and no issuer data.
    #
    # Verified against `docs/reference/robinhood/endpoint-inventory.md`, which enumerates
    # both v1 and the parallel v2 from the vendor's own documentation.
    {:get_positions, 1},
    {:get_funding, 2},
    {:get_contract_stats, 2},
    {:get_staking_rates, 1},
    {:get_staking_balances, 1},
    {:get_staking_rewards, 1},
    {:get_staking_history, 1},
    {:stake, 3},
    {:unstake, 3},
    {:quote_conversion, 4},
    {:commit_conversion, 2},
    {:get_conversion, 2},
    {:list_portfolios, 1},
    {:get_deposit_address, 3},
    {:list_approved_addresses, 1},
    {:estimate_withdrawal_fee, 4},
    {:withdraw, 5},
    {:get_option_chain, 2},
    {:get_option_expirations, 2},
    {:get_option_greeks, 2},
    {:list_watchlists, 1},
    {:get_watchlist, 2},
    {:create_watchlist, 3},
    {:update_watchlist, 2},
    {:delete_watchlist, 2},
    {:get_financials, 3},
    {:get_corporate_events, 1},
    {:get_filings, 2},
    {:get_news, 1},
    {:get_screener, 2},
    {:create_account, 1},
    {:rename_account, 3},
    {:get_roles, 1},
    # Neither exists on this venue. `preview_order/3` has no endpoint at all;
    # `replace_order/4` means a caller cancels and re-places, which is NOT equivalent —
    # it opens a window in which no order is live.
    {:preview_order, 3},
    {:replace_order, 4},
    {:get_historical_prices, 4},
    {:get_order_book, 2},
    {:get_market_overview, 1}
  ]

  # Not ported yet. The venue serves these; this package does not implement them.
  @not_ported [
    {:list_instruments, 1},
    {:get_balances, 2},
    {:get_accounts, 2},
    {:get_fees, 2},
    {:get_transfers, 2},
    {:place_order, 3},
    {:cancel_order, 3},
    {:get_order, 3},
    {:get_orders, 2},
    {:get_trade_history, 2},
    {:get_rate_limit_status, 2},
    {:test_connection, 2},
    {:quantization, 1}
  ]

  @unsupported @venue_does_not_serve ++ @not_ported

  # --- lifecycle ---------------------------------------------------------

  @impl true
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def start_link(opts), do: DpExchange.Robinhood.Supervisor.start_link(opts)

  # --- declaration -------------------------------------------------------

  @impl true
  def provider_name, do: "Robinhood"

  @impl true
  def runtime_id, do: :robinhood

  @impl true
  def asset_classes, do: [:crypto]

  @impl true
  def capabilities do
    Capabilities.new(
      endpoints: endpoint_maturities(),

      # Measured by the prior adapter on 2026-08-05 by walking the paginated
      # `trading_pairs` endpoint: 86 symbols, every one quoted in USD — as seen by THAT
      # credential. Listings can differ by account tier.
      supported_quotes: ["USD"],
      supported_instrument_types: [:spot],
      supports_short_selling: false,

      # `:quotes`, and they arrive by poll. What a consumer receives is identical to a
      # streaming venue's; `coverage/1` reports `:internal_poll` so the difference is
      # visible as what is arriving rather than as how.
      streamable: [:quotes],

      # The venue publishes no candle endpoint at all, so there is no width to declare.
      # An empty list is the honest answer, and `get_historical_prices/4` is
      # `:unsupported` rather than returning an empty series.
      historical_timeframes: [],
      max_candles_per_request: nil,

      # The quote carries no volume and there is no candle endpoint to source one from.
      reports_trade_volume: false,
      catalog_size: :small,

      # Every call is signed, including the quotes.
      credential_benefit: :required,
      public_ceiling: %{limit: 10, per_ms: 1_000},
      authenticated_ceiling: %{limit: 10, per_ms: 1_000},
      measured_at: ~D[2026-08-28],
      measured_against:
        "endpoint set, Ed25519 signing scheme and the absence of candle, order-book and " <>
          "volume endpoints read from the venue's Crypto Trading API documentation; the " <>
          "86-symbol USD-only catalogue is INHERITED from the prior adapter's 2026-08-05 " <>
          "walk and NOT re-measured here, since every endpoint requires credentials this " <>
          "repo does not hold; ceilings NOT probed"
    )
  end

  defp endpoint_maturities do
    active =
      for {name, arity} <- Venue.behaviour_info(:callbacks),
          {name, arity} not in @unsupported,
          into: %{},
          do: {{name, arity}, :experimental}

    Enum.reduce(@unsupported, active, &Map.put(&2, &1, :unsupported))
  end

  @doc """
  Endpoints the **venue** does not serve, as distinct from ones this package has not
  ported.

  Both answer `{:error, :not_supported}`, and a caller acts the same way on either — but
  they mean different things to anyone deciding what to build next, so they are told apart
  here rather than flattened into one list.
  """
  @spec venue_does_not_serve() :: [{atom(), arity()}]
  def venue_does_not_serve, do: @venue_does_not_serve

  # --- market data -------------------------------------------------------

  @impl true
  def get_price(symbol, opts \\ []),
    do: Rest.get_price(symbol, credentials(opts), with_limiter(opts))

  @impl true
  def get_top_of_book(symbol, opts \\ []),
    do: Rest.get_top_of_book(symbol, credentials(opts), with_limiter(opts))

  @impl true
  def get_symbols(opts \\ []), do: Rest.get_symbols(credentials(opts), with_limiter(opts))

  @impl true
  def get_historical_prices(_symbol, _timeframe, _range, _opts), do: Venue.not_supported()

  @impl true
  def get_order_book(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_market_overview(_opts), do: Venue.not_supported()

  @impl true
  def list_instruments(_opts), do: Venue.not_supported()

  # --- account and trading -----------------------------------------------

  @impl true
  def get_balances(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_accounts(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_fees(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_transfers(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def place_order(_credentials, _request, _opts), do: Venue.not_supported()

  @doc """
  **Not supported.** This venue publishes no order-preview endpoint.

  Declared through `supports_order_preview: false`, so a consumer routes around it rather
  than discovering the refusal at call time.
  """
  @impl true
  def preview_order(_credentials, _request, _opts \\ []), do: Venue.not_supported()

  @doc """
  **Not supported.** This venue has no atomic replace; a caller cancels and re-places.

  That is not equivalent — it opens a window in which no order is live — which is why
  `supports_order_replace: false` is a claim about **risk** rather than convenience.
  """
  @impl true
  def replace_order(_credentials, _id, _request, _opts \\ []), do: Venue.not_supported()

  @impl true
  def cancel_order(_credentials, _id, _opts), do: Venue.not_supported()
  @impl true
  def get_order(_credentials, _id, _opts), do: Venue.not_supported()
  @impl true
  def get_orders(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_trade_history(_credentials, _opts), do: Venue.not_supported()

  # --- streaming, which here is a poll ------------------------------------

  @impl true
  def subscribe(symbols, opts \\ []) do
    feed = feed(opts)

    if alive?(feed) do
      current = feed |> Feed.coverage() |> Map.keys()
      Feed.update_symbols(feed, Enum.uniq(current ++ symbols))
    else
      {:error, :feed_not_started}
    end
  end

  @impl true
  def unsubscribe(symbols, opts \\ []) do
    feed = feed(opts)

    if alive?(feed) do
      remaining = feed |> Feed.coverage() |> Map.keys() |> Enum.reject(&(&1 in symbols))
      Feed.update_symbols(feed, remaining)
    else
      :ok
    end
  end

  @impl true
  def update_symbols(symbols, opts \\ []) do
    feed = feed(opts)
    if alive?(feed), do: Feed.update_symbols(feed, symbols), else: {:error, :feed_not_started}
  end

  @impl true
  def coverage(opts \\ []) do
    feed = feed(opts)
    if alive?(feed), do: Feed.coverage(feed), else: %{}
  end

  # NOT `:unsupported`, and not a socket either. This venue's feed reports refusals
  # through the same subscriber, so a caller registering here receives them.
  @impl true
  def subscribe_notices(_opts \\ []), do: :ok

  # --- health ------------------------------------------------------------

  @impl true
  def test_connection(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def get_rate_limit_status(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def market_status(_opts), do: {:ok, :open}

  @impl true
  def quantization(_symbol), do: Venue.not_supported()

  @doc "The quote currencies this venue settles in."
  @spec quotes() :: [String.t()]
  def quotes, do: SymbolFormat.quotes()

  # --- internals ---------------------------------------------------------

  defp feed(opts), do: Keyword.get(opts, :feed, DpExchange.Robinhood.Supervisor.feed_name(opts))

  defp alive?(name) when is_atom(name), do: is_pid(GenServer.whereis(name))
  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)

  # An absent map reaches `Auth` and is refused there rather than producing an unsigned
  # request — this venue has no anonymous endpoint to fall back to.
  defp credentials(opts), do: Keyword.get(opts, :credentials, %{})

  defp with_limiter(opts) do
    Keyword.put_new(opts, :limiter, DpExchange.Robinhood.Supervisor.limiter_name(opts))
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
  def get_positions(_opts), do: Venue.not_supported()

  @impl true
  def get_funding(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_contract_stats(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_staking_rates(_opts), do: Venue.not_supported()

  @impl true
  def get_staking_balances(_opts), do: Venue.not_supported()

  @impl true
  def get_staking_rewards(_opts), do: Venue.not_supported()

  @impl true
  def get_staking_history(_opts), do: Venue.not_supported()

  @impl true
  def stake(_asset, _amount, _opts), do: Venue.not_supported()

  @impl true
  def unstake(_asset, _amount, _opts), do: Venue.not_supported()

  @impl true
  def quote_conversion(_from, _to, _amount, _opts), do: Venue.not_supported()

  @impl true
  def commit_conversion(_id, _opts), do: Venue.not_supported()

  @impl true
  def get_conversion(_id, _opts), do: Venue.not_supported()

  @impl true
  def list_portfolios(_opts), do: Venue.not_supported()

  @impl true
  def get_deposit_address(_asset, _network, _opts), do: Venue.not_supported()

  @impl true
  def list_approved_addresses(_opts), do: Venue.not_supported()

  @impl true
  def estimate_withdrawal_fee(_asset, _network, _amount, _opts), do: Venue.not_supported()

  @impl true
  def withdraw(_asset, _network, _amount, _address, _opts), do: Venue.not_supported()

  @impl true
  def get_option_chain(_underlying, _opts), do: Venue.not_supported()

  @impl true
  def get_option_expirations(_underlying, _opts), do: Venue.not_supported()

  @impl true
  def get_option_greeks(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def list_watchlists(_opts), do: Venue.not_supported()

  @impl true
  def get_watchlist(_id, _opts), do: Venue.not_supported()

  @impl true
  def create_watchlist(_name, _symbols, _opts), do: Venue.not_supported()

  @impl true
  def update_watchlist(_id, _opts), do: Venue.not_supported()

  @impl true
  def delete_watchlist(_id, _opts), do: Venue.not_supported()

  @impl true
  def get_financials(_symbol, _kind, _opts), do: Venue.not_supported()

  @impl true
  def get_corporate_events(_opts), do: Venue.not_supported()

  @impl true
  def get_filings(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_news(_opts), do: Venue.not_supported()

  @impl true
  def get_screener(_name, _opts), do: Venue.not_supported()

  @impl true
  def create_account(_opts), do: Venue.not_supported()

  @impl true
  def rename_account(_id, _name, _opts), do: Venue.not_supported()

  @impl true
  def get_roles(_opts), do: Venue.not_supported()
end
