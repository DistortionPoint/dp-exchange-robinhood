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
  package, and it delivers the same `Core.Types.TopOfBook` to the same subscriber as a
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

  Every Robinhood Crypto call is signed with an Ed25519 key, including the book. There is
  no anonymous endpoint, so `get_top_of_book/2` takes credentials:

      {:ok, book} = DpExchange.Robinhood.get_top_of_book("BTC-USD", credentials: %{
        api_key: "…", private_key: "…"
      })

  You hold the credentials. A direct call signs one request with them and keeps nothing; the
  supervised poll is the exception, because it signs every cycle: it keeps the credentials
  you started it with, wrapped so a crash report does not print them.

  ## `get_price/2` is `:unsupported` — this venue has no last-trade data at all

  `best_bid_ask` is the only quote-adjacent endpoint this venue serves, and it carries only
  a bid and an ask, never a trade price. This
  package used to fill `Core.Types.Quote.price` from the ask when the venue sent none —
  `Quote`'s own moduledoc now names this incident directly as the reason `Quote` carries no
  bid or ask at all. Removing that fallback was correct and left `get_price/2` with no
  honest number to return, ever: DpCryptoManagement's issue #21. There is no separate
  last-trade endpoint to fall back to either — confirmed against the vendor's complete
  nine-operation surface, see `docs/reference/robinhood/negative-claims.md`. `bid` and
  `ask` are still real and live, through `get_top_of_book/2` and the poll above.

  ## No candles, no order book, no volume

  The venue publishes none of them. `get_historical_prices/4`, `get_order_book/2` and
  volume are `:unsupported` — the venue's shape, not a gap here. Route that work elsewhere
  rather than discovering an empty series.

  ## Supervision

      children = [
        {DpExchange.Robinhood,
         credentials: my_credentials(), symbols: ["BTC-USD"], subscriber: self()}
      ]

  `subscriber:` is where polled books and refusals are delivered, for the life of the tree.
  There is no default: a feed started without one delivers data to nobody.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.{Capabilities, Config, Venue}
  alias DpExchange.Robinhood.{Feed, Rest, SymbolFormat}

  # The venue serves none of these. That is a claim about Robinhood, not about how far this
  # package got — and the two are worth telling apart, so the account and trading endpoints
  # below are listed separately.
  @venue_does_not_serve [
    # No last-trade data exists on this venue at any endpoint — confirmed against the
    # vendor's complete nine-operation surface (`docs/reference/robinhood/negative-claims.md`:
    # "No public trade tape"). `best_bid_ask` carries only bid/ask, never a `price` field.
    # `Core.Types.Quote`'s own moduledoc names the trap directly: this package used to fill
    # `price` from the ask when the venue sent none, "which is exactly what one of them
    # did" — DpCryptoManagement's issue #21, after that fallback was correctly removed and
    # left `get_price/2` with no honest number to return, ever. `estimated_price` is not a
    # substitute either; its own doc says so ("Not a quote and not a fill"), and it needs a
    # side and quantity picked for it, which is fabrication with extra steps. Bid and ask
    # are still real and live, via `get_top_of_book/2` and the `:top_of_book` stream below.
    {:get_price, 2},
    # Robinhood's v2 order surface is four endpoints and none takes a list.
    {:place_orders, 3},
    # **A crypto brokerage with no funding API.** The vendor's crypto trading documentation
    # publishes nine endpoints and none of them is a payment method, a transfer, an
    # allowlist, a network list or a transaction ledger — money reaches the account through
    # the Robinhood application, which needs a person. Checked against all five of the
    # vendor's documentation pages on 2026-09-01.
    {:get_transactions, 2},
    {:list_payment_methods, 2},
    {:get_payment_method, 3},
    {:add_payment_method, 2},
    {:transfer_internal, 4},
    {:request_approved_address, 4},
    {:remove_approved_address, 3},
    {:list_networks, 2},
    {:list_fee_promos, 1},
    {:get_fx_rate, 3},
    {:get_notional_balances, 3},
    {:list_custody_fees, 2},
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
    # **No one-step convert and no account volume report.** `convert/4` is the form where
    # the venue executes without holding a rate; this venue publishes neither that nor the
    # two-step quote/commit pair. `get_trade_volume/2` likewise — the venue reports fills,
    # and summing them here would be this package's arithmetic rather than the venue's
    # ledger, which is the number its fee tiers actually come from.
    {:convert, 4},
    {:get_trade_volume, 2},
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
    # **None of the three exists on this venue — read from its v2 reference, 2026-09-01.**
    # The crypto order surface is four calls: list, place, get, and cancel-one. There is no
    # preview, no amend, no bulk cancel, and no position-closing endpoint. Absence here is
    # measured, not assumed: the enumeration is in `docs/reference/robinhood/`.
    {:preview_replace, 4},
    {:cancel_all_orders, 2},
    {:close_position, 3},
    {:get_historical_prices, 4},
    # **No public tape on this venue.** The v2 crypto surface is best bid/ask, estimated
    # price, accounts, holdings, orders and trading pairs — read from its reference,
    # 2026-09-01. There is no trades endpoint, and `get_trade_history/2` answers a
    # different question: the credential's own fills, not everyone's executions.
    {:get_trades, 2},
    # **This venue runs no auctions and publishes no footprints.** A crypto book trades
    # continuously — there is no opening or closing auction to have an imbalance in — and
    # the venue publishes no volume-at-price split. Not "unimplemented": there is nothing
    # to implement.
    {:get_auction_imbalance, 2},
    {:get_volume_profile, 3},
    {:get_order_book, 2},
    # **Four absences that read like a backlog and are not.** Each was declared "not
    # ported" until 2026-09-01, which told a host the wrong thing — that implementing it
    # here would change the answer. None of the nine documented operations is a fee
    # schedule, a transfer ledger, a fills feed, or a rate-limit report. The venue's
    # limits are published as prose in its documentation, not served as an endpoint;
    # fee tiers reach a caller on the v2 order it places, not from a schedule; and fills
    # are visible only through the orders the credential itself placed.
    {:get_fees, 2},
    {:get_transfers, 2},
    {:get_trade_history, 2},
    {:get_rate_limit_status, 2},
    {:get_market_overview, 1}
  ]

  # Not ported yet. **The venue serves these**; this package does not implement them.
  #
  # Four callbacks that used to sit here have moved into `@venue_does_not_serve` above.
  # They were mislabelled, and the mislabel pointed the wrong way: "not ported" tells a
  # host the answer might change with work here, when the venue has no such endpoint and
  # the answer will not change at all. `get_fees/2`, `get_transfers/2`,
  # `get_trade_history/2` and `get_rate_limit_status/2` are absences of the venue —
  # Robinhood Crypto's documented surface is nine operations and none of them is a fee
  # schedule, a transfer ledger, a fills feed or a limit report.
  #
  # `list_instruments/1` used to sit here too, on the reasoning that `trading_pairs`
  # carries the instrument metadata and this package read only the symbols. That reasoning
  # stopped being true once DpCryptoManagement's issue #25 was investigated: `get_symbols/1`
  # already walks every page of that same endpoint, and the rows it discards
  # (`asset_code`, `quote_code`, `status`) are exactly what `Rest.list_instruments/2` now
  # maps to a `Core.Instrument` — no new request, no new endpoint, no parsing a symbol
  # string back apart.
  @not_ported [
    # Any signed endpoint answers it; nothing here calls one for the purpose.
    {:test_connection, 2}
  ]

  @unsupported @venue_does_not_serve ++ @not_ported

  # --- lifecycle ---------------------------------------------------------

  @doc """
  Child spec for supervising this venue's tree.

  Wraps `opts[:credentials]` so a crash report does not print them, and declares
  `type: :supervisor`. See `c:DpExchange.Core.Venue.child_spec/1`.
  """
  @impl true
  def child_spec(opts) do
    # Credentials are wrapped HERE, and not in `start_link/1` or `init/1` — that
    # distinction IS the fix. A supervisor stores the `{module, :start_link, [opts]}` MFA
    # it was handed, and OTP writes that argument list through `inspect/1` into the
    # `Start Call:` line of the report it logs on ANY child termination. Wrapping any later
    # does nothing: the raw list has already been captured by the supervisor above.
    # dp-exchange-core issue #29 — live API keys, in cleartext, in ordinary application
    # logs, produced by any crash at all.
    opts = DpExchange.Robinhood.Credentials.wrap_opt(opts)

    # `type: :supervisor`: `start_link/1` starts an OTP `Supervisor`, and without this key
    # OTP defaults `:type` to `:worker`, which also defaults `:shutdown` to `5_000`ms
    # instead of `:infinity`. A consumer terminating this child would then give the whole
    # nested tree — feed, rate limiter, and everything under them — only five seconds to
    # shut down gracefully before `:kill`, instead of letting it unwind on its own terms.
    # Found by a cross-package audit comparing `child_spec/1` across all five venues;
    # `dp_exchange_schwab` was the only one that already declared this.
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Starts the supervision tree: the rate limiter and the polling feed.

  Delegates to `DpExchange.Robinhood.Supervisor.start_link/1`. See
  `c:DpExchange.Core.Venue.start_link/1`.
  """
  @impl true
  def start_link(opts), do: DpExchange.Robinhood.Supervisor.start_link(opts)

  # --- declaration -------------------------------------------------------

  @doc """
  The venue's display name, `"Robinhood"`. See `c:DpExchange.Core.Venue.provider_name/0`.
  """
  @impl true
  def provider_name, do: "Robinhood"

  @doc """
  The venue's runtime identifier, `:robinhood`. See `c:DpExchange.Core.Venue.runtime_id/0`.
  """
  @impl true
  def runtime_id, do: :robinhood

  @doc """
  The asset classes this venue serves: `[:crypto]`. See
  `c:DpExchange.Core.Venue.asset_classes/0`.
  """
  @impl true
  def asset_classes, do: [:crypto]

  @doc """
  What this venue serves, with the maturity of each endpoint and the evidence behind each
  figure (`measured_at` and `measured_against`).

  Endpoints the venue does not serve are `:unsupported`; every other callback is
  `:experimental`. See `c:DpExchange.Core.Venue.capabilities/0`.
  """
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

      # **The four types `Rest.order_config/2` actually builds**, from `AddOrderV2`'s own
      # `market_order_config`, `limit_order_config`, `stop_loss_order_config` and
      # `stop_limit_order_config`. This defaulted to `[]` until 2026-09-07 — "this venue
      # accepts no order type at all" — while `{:place_order, 3}` was declared
      # `:experimental` and the comment directly below named three of the four config
      # objects. `Capabilities.new/1` validates the *contents* of this list but never that
      # a venue with an active `place_order/3` declared anything, so an empty list passes
      # every check; a cross-package audit found `dp_exchange_coinbase` defaulting the same
      # field the same way for the same reason.
      #
      # `:stop`, not `:stop_loss`: `:stop` is the shared vocabulary's atom, and
      # `Rest.order_config/2` now accepts it alongside the venue's own spelling. Declaring
      # `:stop` while only `:stop_loss` was accepted would have turned an under-declaration
      # into an over-declaration — the caller would be refused by the very atom this list
      # told it to send.
      supported_order_types: [:market, :limit, :stop, :stop_limit],

      # Real vendor values (`AddOrderV2`'s `limit_order_config`, `.stop_loss_order_config`
      # and `.stop_limit_order_config`, enum `["gtc", "gfd", "gfw", "gfm"]`), not the empty
      # list this used to default to. All four are declared now: `:gtc`, `:day` (the venue's
      # `gfd`, "good for day"), and `:gfw`/`:gfm`, which Core 0.1.45 added a vocabulary for.
      # For one release the last two were deliberately left undeclared rather than mapped to
      # a nearest-match atom — a declaration this package could not actually honour would be
      # the same untrue claim as the empty list, pointing the other way.
      # `market_order_config` accepts none of these, so a market order never carries a
      # `time_in_force` regardless of this declaration.
      supported_time_in_force: [:gtc, :day, :gfw, :gfm],

      # `:top_of_book`, and it arrives by poll — never `:quotes`, because this venue has no
      # last-trade data to poll for (see `get_price/2`'s entry in `@venue_does_not_serve`).
      # What a consumer receives is identical to a streaming venue's; `coverage/1` reports
      # `:internal_poll` so the difference is visible as what is arriving rather than as how.
      streamable: [:top_of_book],

      # Every call on this venue is signed, quotes included, so the one streamed kind
      # needs a credential too. `Capabilities.new/1` enforces `authenticated_streamable`
      # as a *subset* of `streamable` (which of the streamed kinds need one), not a
      # superset — left at the default `[]` this read as "no credential is needed to
      # stream `:top_of_book`", which is the opposite of what this venue does. Found by a
      # cross-package audit; `dp_exchange_webull` carried the identical `[]` for the
      # identical reason.
      authenticated_streamable: [:top_of_book],

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
      # **Read from the vendor's OpenAPI document, "Rate Limiting" section** (committed at
      # `docs/reference/robinhood/openapi`, fetched 2026-09-29): "Requests per minute per
      # user account: 100" and "in bursts: 300", as a token bucket. This said `limit: 10,
      # per_ms: 1_000` (600 a minute, six times the documented sustained rate) under a note
      # that the vendor publishes no figures; it does, and the limiter built from this
      # ceiling let a burst of traffic through that the venue would have answered with 429.
      # The vendor adds that the values "fluctuate" and are applied "per endpoint", so these
      # are the stated figures and not a measurement. Scope is the account, not the key.
      public_ceiling: %{limit: 100, per_ms: 60_000, burst: 300, scope: :account},
      authenticated_ceiling: %{limit: 100, per_ms: 60_000, burst: 300, scope: :account},
      measured_at: ~D[2026-09-29],
      measured_against:
        "endpoint set, Ed25519 signing scheme and the absence of candle, order-book and " <>
          "volume endpoints read from the venue's Crypto Trading API documentation; order " <>
          "types, time-in-force values, the v2 response shapes and the rate-limit figures " <>
          "(100 requests a minute per account, bursts of 300; the vendor says they " <>
          "fluctuate and differ per endpoint) read from the vendor's " <>
          "OpenAPI document committed at docs/reference/robinhood/openapi (fetched " <>
          "2026-09-29) and never exercised against the live venue; the " <>
          "86-symbol USD-only catalogue is INHERITED from the prior adapter's 2026-08-05 " <>
          "walk and NOT re-measured here, since every endpoint requires credentials this " <>
          "repo does not hold; ceilings are the DOCUMENTED figures and NOT probed — " <>
          "settling whether the live venue enforces them needs a credentialed consumer " <>
          "deliberately ramping request rate against one read endpoint and recording the " <>
          "first 429, by hand"
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

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, because it publishes no
  last-trade data. Use `get_top_of_book/2` for bid and ask. See
  `c:DpExchange.Core.Venue.get_price/2`.
  """
  @impl true
  def get_price(_symbol, _opts \\ []), do: Venue.not_supported()

  @doc """
  Best bid and ask for one symbol, from the signed `best_bid_ask` endpoint.

  Credentials are required (`opts[:credentials]`, `%{api_key:, private_key:}`): this venue
  has no anonymous endpoint. See `DpExchange.Robinhood.Rest.get_top_of_book/3` and
  `c:DpExchange.Core.Venue.get_top_of_book/2`.
  """
  @impl true
  def get_top_of_book(symbol, opts \\ []),
    do:
      with_market_checked(
        opts,
        :get_top_of_book,
        &Rest.get_top_of_book(symbol, credentials(&1), &1)
      )

  @doc """
  Every tradable symbol, walking all pages of the signed `trading_pairs` endpoint.

  Credentials are required (`opts[:credentials]`). See
  `DpExchange.Robinhood.Rest.get_symbols/2` and `c:DpExchange.Core.Venue.get_symbols/1`.
  """
  @impl true
  def get_symbols(opts \\ []),
    do: with_market_checked(opts, :get_symbols, &Rest.get_symbols(credentials(&1), &1))

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_historical_prices/4`.
  """
  @impl true
  def get_historical_prices(_symbol, _timeframe, _range, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_order_book/2`.
  """
  @impl true
  def get_order_book(_symbol, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_trades/2`.
  """
  @impl true
  def get_trades(_symbol, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_auction_imbalance/2`.
  """
  @impl true
  def get_auction_imbalance(_symbol, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_volume_profile/3`.
  """
  @impl true
  def get_volume_profile(_symbol, _timeframe, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_market_overview/1`.
  """
  @impl true
  def get_market_overview(_opts), do: Venue.not_supported()

  @doc """
  Every tradable pair as a `Core.Instrument` — base, quote, instrument type and status.

  See `DpExchange.Robinhood.Rest.list_instruments/2`: it walks the same paginated
  `trading_pairs` endpoint `get_symbols/1` already calls, reading `asset_code` and
  `quote_code` off the same rows for base and quote rather than parsing them back out of
  the canonical symbol string. Every row is `:spot`.
  """
  @impl true
  def list_instruments(opts),
    do:
      with_market_checked(
        opts,
        :list_instruments,
        &Rest.list_instruments(credentials(&1), &1)
      )

  # --- account and trading -----------------------------------------------

  @doc """
  Crypto holdings for one account, plus the account's cash.

  See `DpExchange.Robinhood.Rest.get_balances/2`. `opts[:account_number]` is **required by
  v2** where v1 took none, and `hold` is `nil` because the venue publishes no such figure —
  subtracting would produce a number it never stated. **The account's cash is appended as
  one more `Balance`**, read from `buying_power` (dp-exchange-core issue #35) — see
  `Rest.get_balances/2`'s own doc for the shape and the ways that second read can refuse.
  """
  @impl true
  def get_balances(credentials, opts),
    do: with_checked(opts, :get_balances, &Rest.get_balances(credentials, &1))

  @doc """
  The crypto trading account — and the account number every other v2 call takes.

  See `DpExchange.Robinhood.Rest.get_accounts/2`.
  """
  @impl true
  def get_accounts(credentials, opts),
    do: with_checked(opts, :get_accounts, &Rest.get_accounts(credentials, &1))

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_fees/2`.
  """
  @impl true
  def get_fees(_credentials, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_transfers/2`.
  """
  @impl true
  def get_transfers(_credentials, _opts), do: Venue.not_supported()

  @doc """
  Places an order. **This moves funds.**

  See `DpExchange.Robinhood.Rest.place_order/3`. `opts[:account_number]` is required;
  `client_order_id` is generated when the caller does not supply one **and is an idempotency
  key**, so a retry of a request whose response was never seen should pass the same one. A
  key you supply must be a canonical UUID (the vendor's `format: uuid`), otherwise
  `{:error, {:invalid_client_order_id, value}}` before anything is signed.

  `order_type` and `time_in_force` are required (a market order takes no `time_in_force`; a
  supplied one is `{:unexpected_field, :time_in_force}`), an unread key is
  `{:unsupported_order_field, key}`, and a write that may have reached the venue without
  being confirmed is `{:error, {:order_unconfirmed, client_order_id, reason}}`. The full
  list of refusals, in order, is on `DpExchange.Robinhood.Rest.place_order/3`.
  """
  @impl true
  def place_order(credentials, request, opts \\ []),
    do: with_checked(opts, :place_order, &Rest.place_order(credentials, request, &1))

  @doc """
  **Not supported.** Robinhood places one order per request.

  Its v2 order surface is four endpoints and none of them takes a list. A caller placing
  several calls `place_order/3` several times, and each carries its own `client_order_id`.
  """
  @impl true
  def place_orders(_credentials, _requests, _opts), do: Venue.not_supported()

  @doc """
  An execution estimate for a given size.

  Venue-specific: the second of this venue's two prices, and the only one that accounts for
  size — `get_price/2` is `:unsupported`, so there is no third.
  See `DpExchange.Robinhood.Rest.get_estimated_price/5` — **the endpoint moved from
  `marketdata` to `trading` between v1 and v2.** `side` is `bid`, `ask` or `both`; a
  `quantity` that is not a positive finite number is refused as `{:error, {:invalid_field,
  :quantity}}`, and the numeric fields of each result row are returned as `Decimal`.
  """
  @spec get_estimated_price(
          String.t(),
          atom() | String.t(),
          Decimal.t() | number() | String.t() | [Decimal.t() | number() | String.t()],
          map(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_estimated_price(symbol, side, quantity, credentials, opts \\ []),
    do:
      with_checked(
        opts,
        :get_estimated_price,
        &Rest.get_estimated_price(symbol, side, quantity, credentials, &1)
      )

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

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.preview_replace/4`.
  """
  @impl true
  def preview_replace(_credentials, _id, _changes, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.close_position/3`.
  """
  @impl true
  def close_position(_credentials, _symbol, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.cancel_all_orders/2`.
  """
  @impl true
  def cancel_all_orders(_credentials, _opts \\ []), do: Venue.not_supported()

  @doc """
  Cancels an order. **A POST, not a DELETE**, and it takes no account number.

  See `DpExchange.Robinhood.Rest.cancel_order/3` — the response is the venue's own
  `V2CryptoOrder`, decoded the same way `get_order/3`'s is, so the returned `Order`
  reflects the venue's real state (`:open` if the cancel is still in flight, `:cancelled`
  once it lands, or a fill if one won the race) rather than an assumed outcome.
  """
  @impl true
  def cancel_order(credentials, id, opts \\ []),
    do: with_checked(opts, :cancel_order, &Rest.cancel_order(credentials, id, &1))

  @doc """
  One order. `opts[:account_number]` is required by v2.

  See `DpExchange.Robinhood.Rest.get_order/3`.
  """
  @impl true
  def get_order(credentials, id, opts \\ []),
    do: with_checked(opts, :get_order, &Rest.get_order(credentials, id, &1))

  @doc """
  Orders on one account. `opts[:account_number]` is required by v2.

  See `DpExchange.Robinhood.Rest.get_orders/2` for what `opts[:limit]` and `opts[:cursor]`
  do — without `opts[:limit]`, every page is walked and bounded; with it, exactly one page
  is fetched, because the venue's endpoint has no `limit` parameter of its own to send.
  """
  @impl true
  def get_orders(credentials, opts \\ []),
    do: with_checked(opts, :get_orders, &Rest.get_orders(credentials, &1))

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_trade_history/2`.
  """
  @impl true
  def get_trade_history(_credentials, _opts), do: Venue.not_supported()

  # **A crypto brokerage with no funding API.** Robinhood's crypto trading documentation
  # publishes nine endpoints and none of them is a payment method, a transfer, an allowlist
  # or a network list — money reaches the account through the Robinhood application, which
  # needs a person. Checked against the vendor's own five documentation pages on 2026-09-01.

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_transactions/2`.
  """
  @impl true
  def get_transactions(_credentials, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.list_payment_methods/2`.
  """
  @impl true
  def list_payment_methods(_credentials, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_payment_method/3`.
  """
  @impl true
  def get_payment_method(_credentials, _id, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.add_payment_method/2`.
  """
  @impl true
  def add_payment_method(_details, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.transfer_internal/4`.
  """
  @impl true
  def transfer_internal(_asset, _amount, _opts, _request_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.request_approved_address/4`.
  """
  @impl true
  def request_approved_address(_asset, _network, _address, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.remove_approved_address/3`.
  """
  @impl true
  def remove_approved_address(_network, _address, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.list_networks/2`.
  """
  @impl true
  def list_networks(_asset, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.list_fee_promos/1`.
  """
  @impl true
  def list_fee_promos(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_fx_rate/3`.
  """
  @impl true
  def get_fx_rate(_pair, _at, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_notional_balances/3`.
  """
  @impl true
  def get_notional_balances(_credentials, _currency, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.list_custody_fees/2`.
  """
  @impl true
  def list_custody_fees(_credentials, _opts), do: Venue.not_supported()

  # --- streaming, which here is a poll ------------------------------------

  @doc """
  Adds `symbols` to the polled set and registers `opts[:to]` (default: the caller) to
  receive the books.

  Served by a REST poll inside this package, not a socket. Symbols are upper-cased and
  validated first: `{:error, {:invalid_symbols, value}}`, then
  `{:error, {:invalid_subscriber, value}}`; `{:error, :feed_not_started}` when no feed is
  running. See `c:DpExchange.Core.Venue.subscribe/2`.
  """
  @impl true
  # Added and removed against what was asked for, inside `Feed`. This used to rebuild the
  # set from `coverage/1`, which is only what has been observed arriving, so a second
  # subscribe dropped every symbol that had not delivered yet. See `Feed.add_symbols/2`.
  #
  # **A malformed symbol list is refused here, before it reaches `Feed`.** A non-list made
  # `state.symbols ++ symbols` raise inside the feed process, which crashed it: the feed
  # restarted from its boot-time opts, so every later subscription and every notice
  # registration was lost to one bad argument. A non-binary or blank element would have been
  # polled as a symbol, and a bulk request carrying it is refused whole.
  #
  # **`opts[:to]` is honoured** (default: the calling process). The market data this feed
  # polls reaches every pid that called `subscribe/2`, and the `:subscriber` the feed was
  # started with. This used to ignore `to:` and deliver only to that boot-time subscriber,
  # against `c:DpExchange.Core.Venue.subscribe/2`'s "events arrive as messages to the
  # subscribing process, or to a pid given in `opts`". Arguments are checked, symbols then
  # subscriber, before the feed is looked at, so a bad argument answers the same whether or
  # not a feed is running: `{:error, {:invalid_symbols, value}}` or `{:error,
  # {:invalid_subscriber, value}}`. `subscribe([])` registers the subscriber and polls nothing.
  def subscribe(symbols, opts \\ []) do
    with {:ok, symbols} <- Feed.canonical_symbols(symbols),
         :ok <- Rest.validate_market_opts(opts, :subscribe),
         {:ok, to} <- Feed.valid_subscriber(Config.opt(opts, :to, self())) do
      feed_call(
        fn -> Feed.add_symbols(feed(opts), symbols, to) end,
        {:error, :feed_not_started}
      )
    end
  end

  @doc """
  Removes `symbols` from the polled set.

  `:ok` when no feed is running, since there is nothing to stop; a malformed list is
  `{:error, {:invalid_symbols, value}}`. See `c:DpExchange.Core.Venue.unsubscribe/2`.
  """
  @impl true
  def unsubscribe(symbols, opts \\ []) do
    with {:ok, symbols} <- Feed.canonical_symbols(symbols),
         :ok <- Rest.validate_opts(opts, :unsubscribe) do
      feed_call(fn -> Feed.remove_symbols(feed(opts), symbols) end, :ok)
    end
  end

  @doc """
  Replaces the polled set with `symbols` (`subscribe/2` adds; this replaces).

  `{:error, :feed_not_started}` when no feed is running; a malformed list is
  `{:error, {:invalid_symbols, value}}`. See `c:DpExchange.Core.Venue.update_symbols/2`.
  """
  @impl true
  def update_symbols(symbols, opts \\ []) do
    with {:ok, symbols} <- Feed.canonical_symbols(symbols),
         :ok <- Rest.validate_market_opts(opts, :update_symbols) do
      feed_call(
        fn -> Feed.update_symbols(feed(opts), symbols) end,
        {:error, :feed_not_started}
      )
    end
  end

  @doc """
  Per-symbol routes observed arriving, `:internal_poll` on this venue, never `:stream`.

  `%{}` when the feed is not running or does not answer. See
  `c:DpExchange.Core.Venue.coverage/1`.
  """
  @impl true
  def coverage(opts \\ []) do
    check_opts!(opts)
    feed = feed(opts)
    if alive?(feed), do: feed_read(fn -> Feed.coverage(feed) end, %{}), else: %{}
  end

  @doc """
  What has been asked for, which is not what `coverage/1` reports.

  `coverage/1` is what is observed arriving. This is the polled set as `subscribe/2`,
  `unsubscribe/2` and `update_symbols/2` left it, the same split `dp_exchange_schwab`'s
  `wanted/1` offers. An empty list when the feed is not running.
  """
  @spec wanted(keyword()) :: [Venue.symbol()]
  @impl true
  def wanted(opts \\ []) do
    check_opts!(opts)
    feed = feed(opts)
    if alive?(feed), do: feed_read(fn -> Feed.wanted(feed) end, []), else: []
  end

  @doc """
  `coverage/1`, split by kind — an optional callback in Core, implemented here so consumer
  tooling can call the same function on every venue that offers it, even though this one
  has nothing to split.

  ## Why this exists even where it cannot find anything

  `coverage/1` reports what is observed arriving, truthfully, but it collapses every
  kind of payload into one boolean. On a venue streaming more than one kind behind a
  single subscription, that hid a dark channel behind a healthy one for days — Coinbase
  delivered order-book frames for hundreds of symbols while its last-trade channel sat
  dark for all but a handful, and `coverage/1` alone reported all of them healthy
  because it counts any payload, regardless of kind. See
  `DpExchange.Core.Venue`'s moduledoc on `c:DpExchange.Core.Venue.coverage_by_kind/1`
  for the incident in full.

  Robinhood cannot reproduce that discrepancy, and this implementation does not pretend
  otherwise. `capabilities().streamable` names exactly one kind, `:top_of_book`, and
  this venue's feed delivers it by poll: `Feed`'s fetcher is
  `Rest.get_top_of_book_bulk/3`, which returns exclusively `Core.Types.TopOfBook.t()` —
  never `Core.Types.Quote.t()`, because this venue has no last-trade endpoint at all
  (see `get_price/2` above). A single-key map is therefore the honestly derived shape
  for a venue with exactly one delivery path, not a shortcut taken because there was
  only one declared kind to wrap. Uniformity across the family is the point of
  implementing this callback here — not detecting something that structurally cannot
  happen on this venue.
  """
  @impl true
  @spec coverage_by_kind(keyword()) ::
          %{Capabilities.data_kind() => %{Venue.symbol() => Venue.route()}}
  def coverage_by_kind(opts \\ []) do
    check_opts!(opts)
    feed = feed(opts)

    # No feed (or one that does not answer) is `%{}`, as on every other venue: nothing is
    # observed, so no kind is reported. A running feed reports `%{top_of_book: coverage}`.
    if alive?(feed), do: feed_read(fn -> Feed.coverage_by_kind(feed) end, %{}), else: %{}
  end

  @doc """
  Registers `opts[:to]` (default: the caller) for this venue's own notices — what the
  feed is doing and what is going wrong with it, distinct from `subscribe/2`'s market
  data.

  Backed by a real registry in `DpExchange.Robinhood.Feed`, not the single fixed
  `:subscriber` given to the feed's `start_link/1` at supervision-tree boot. That fixed
  pid keeps receiving notices exactly as before — this adds a second, independent
  recipient rather than replacing it, so a monitoring process distinct from the
  data-consuming one can subscribe without stealing delivery from it.

  `{:error, :feed_not_started}` when this venue's feed is not running, matching
  `subscribe/2` and `update_symbols/2` rather than silently discarding the registration.
  A `:to` that is neither a pid nor a registered name (`true` and `false` are not names) is
  `{:error, {:invalid_subscriber, to}}`, checked before the feed is looked at.
  """
  @impl true
  @spec subscribe_notices(keyword()) :: :ok | {:error, term()}
  def subscribe_notices(opts \\ []) do
    with :ok <- Rest.validate_opts(opts, :subscribe_notices),
         {:ok, to} <- Feed.valid_subscriber(Config.opt(opts, :to, self())) do
      feed = feed(opts)
      feed_call(fn -> Feed.subscribe_notices(feed, to: to) end, {:error, :feed_not_started})
    end
  end

  # --- health ------------------------------------------------------------

  @doc """
  Not implemented by this package: answers `{:error, :not_supported}`. Any signed endpoint
  would do, but nothing here calls one for the purpose.
  See `c:DpExchange.Core.Venue.test_connection/2`.
  """
  @impl true
  def test_connection(_credentials, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_rate_limit_status/2`.
  """
  @impl true
  def get_rate_limit_status(_credentials, _opts), do: Venue.not_supported()

  @doc """
  Always `:open`. This venue's ONLY asset class trades continuously.

  ## Why this is answered locally, not fetched

  `asset_classes/0` is `[:crypto]` — the only asset class this package ever serves on
  this venue — and crypto has no exchange-mandated trading session for `market_status/1`
  to report on: there is no open, no close, no pre- or post-market, because there is no
  market bell to ring in the first place. `:open` is therefore not this package's guess
  at the venue's calendar, the substitution the family's own "fail closed" rule forbids —
  it is the true and complete answer for the one asset class in scope, independent of
  whatever the venue's API can or cannot tell this package.

  **Checked, not assumed.** Robinhood publishes no market-status or trading-hours
  endpoint at all — `docs/reference/robinhood/endpoint-inventory.md` records that every
  one of the vendor's 9 documented operations is implemented here, and none of them is a
  status or calendar call. There is nothing to call even if this answer needed one.

  ## What would make this answer wrong

  Two things, neither observable from this package today:

    * **This package ever serves a second asset class on this venue.** The day
      `asset_classes/0` stops being exactly `[:crypto]`, this unconditional `:open` stops
      being a complete answer and must be revisited — see `dp_exchange_webull`, whose
      identical literal was wrong for four of its five asset classes.
    * **A genuine trading suspension** — the closest real-world analogue to a "closed"
      market on a venue with no session calendar. Robinhood's crypto trading API
      publishes no status feed this package could observe one on, so a live suspension
      would surface here as failed order calls or a stalled poll, not as `market_status/1`
      answering `:closed` — this callback cannot and does not claim to detect that. That
      is a different question from the one this callback answers (`test_connection/2` and
      `get_rate_limit_status/2` are the reachability ones), and conflating the two would
      be inventing a capability this package does not have.

  ## Exempt from `AdapterContract`'s credential gate, and why that is not special pleading

  `dp_exchange_core`'s assertion 17 skips this callback's credential check only when a
  venue's `asset_classes/0` is exactly `[:crypto]` — grounded in this callback's own
  contract doc ("crypto venues answer `:open`"), not carved out per venue. See
  `DpExchange.Core.Venue`'s `market_status/1` callback doc and `AdapterContract`'s "17.
  credential gate" comment for the argument, including why `dp_exchange_schwab` (not
  crypto-only) stays gated on the identical callback.
  """
  @impl true
  def market_status(opts) do
    with :ok <- Rest.validate_opts(opts, :market_status), do: {:ok, :open}
  end

  @doc """
  Rounds a price and quantity to what the venue will actually accept.

  See `DpExchange.Robinhood.Rest.quantization/3` — in particular why `min_quantity` is
  `nil` rather than a guess: the venue's own schema for this endpoint names no per-unit
  minimum, despite a different page's prose naming one that does not exist on it.
  """
  @impl true
  def quantization(symbol, opts \\ []),
    do: with_checked(opts, :quantization, &Rest.quantization(symbol, credentials(&1), &1))

  @doc """
  The quote codes this package's symbol normaliser recognises.

  This is a parsing vocabulary, not a listing claim: it is wider than
  `capabilities().supported_quotes`, which is `["USD"]` because that is all the catalogue
  has ever been seen to contain.
  """
  @spec quotes() :: [String.t()]
  def quotes, do: SymbolFormat.quotes()

  # --- internals ---------------------------------------------------------

  defp feed(opts), do: Config.opt(opts, :feed, DpExchange.Robinhood.Supervisor.feed_name(opts))

  # `Process.alive?/1` raises for a pid on another node. Whether a remote feed is up is not
  # something this facade can read without a call, so it is reported as not running: the
  # read-side answers are the empty ones.
  defp alive?(pid) when is_pid(pid) and node(pid) == node(), do: Process.alive?(pid)
  defp alive?(pid) when is_pid(pid), do: false
  # A registered name, `{:global, _}` or `{:via, _, _}`: anything `GenServer.whereis/1` reads.
  defp alive?(server), do: is_pid(GenServer.whereis(server))

  # **A streaming call answers; it does not exit in the caller's process.** Every
  # streaming callback's spec is a value (`:ok | {:error, term()}`, or a map). A bare
  # `GenServer.call/3` into `Feed` exits the caller instead: with `:noproc` when no `Feed` is
  # running, and with `:timeout` when one is too busy to answer within its call budget.
  # This facade checked `alive?/1` first, which covered a `Feed` never started. Three
  # sibling venues did not, and exited `:noproc` there (measured 2026-09-27). But the check
  # still raced a `Feed` that died between it and the call, and did nothing for a busy
  # one, so the exit is caught at the call itself. A reply that arrives after a timeout is
  # dropped by OTP's call aliases, so it cannot reach the caller's mailbox later.
  #
  # **`{:error, :feed_timeout}` means "no answer", not "not applied".** The request is still
  # in the feed's mailbox and is applied when the feed reaches it. That is safe here because
  # every call that comes through this function is idempotent (add, remove and replace of a
  # symbol set, applied in mailbox order), so a caller who retries after a timeout converges
  # on the same final set; read `wanted/1` to see what the feed actually holds.
  defp feed_call(call, not_running) do
    call.()
  catch
    :exit, {:noproc, _call} -> not_running
    :exit, {:timeout, _call} -> {:error, :feed_timeout}
    :exit, {reason, _call} -> {:error, {:feed_exited, reason}}
  end

  # `coverage/1` and `coverage_by_kind/1` return a map, with no room for an error. Any
  # failure is the empty answer, which says "not observed" and never claims delivery nobody
  # confirmed.
  defp feed_read(call, empty) do
    call.()
  catch
    :exit, _reason -> empty
  end

  # An absent map reaches `Auth` and is refused there rather than producing an unsigned
  # request — this venue has no anonymous endpoint to fall back to.
  defp credentials(opts), do: Keyword.get(opts, :credentials, %{})

  # `Keyword.put/3`, not `put_new/3`: `limiter_name/1` already returns the caller's own
  # `:limiter` when it is set, and `put_new/3` keeps a PRESENT `limiter: nil` — which this
  # family forwards by convention — so the call reached `Core.HttpClient` carrying `nil`, was
  # resolved there to Core's global default limiter, which this package never starts, and
  # failed closed against a venue limiter that was running the whole time.
  defp with_limiter(opts) do
    Keyword.put(opts, :limiter, DpExchange.Robinhood.Supervisor.limiter_name(opts))
  end

  # The reads with no error channel (`coverage/1`, `coverage_by_kind/1`, `wanted/1`) cannot
  # answer `{:error, _}`, and an empty map or list would read as "nothing covered", a plausible
  # substitute for an error. They raise instead, with the value bounded.
  # An unknown key raises too: it would otherwise be a different question answered quietly.
  defp check_opts!(opts) do
    case Rest.validate_opts(opts, :coverage) do
      :ok ->
        :ok

      {:error, {:invalid_options, shown}} ->
        raise ArgumentError, "options must be a keyword list, got: #{inspect(shown)}"

      {:error, {:unknown_option, key}} ->
        raise ArgumentError, "unknown option #{inspect(key)}"
    end
  end

  # Options that are not a keyword list, or carry a key this call does not read, are refused
  # (`Rest.validate_opts/2`) before any `Keyword` function reads them or anything is signed
  # (they raised in the caller's process, on calls that move funds among them), and `fun`
  # receives the options with this venue's limiter put in. The limiter is added AFTER the
  # check, so it is never mistaken for the caller's own key.
  defp with_checked(opts, function, fun) do
    with :ok <- Rest.validate_opts(opts, function), do: fun.(with_limiter(opts))
  end

  # As `with_checked/3`, and the contract's market-data options this venue cannot honour
  # (`:limit`, `:depth`, `:since`, `:include_partial`) are refused too, see
  # `Rest.validate_market_opts/2`.
  defp with_market_checked(opts, function, fun) do
    with :ok <- Rest.validate_market_opts(opts, function), do: fun.(with_limiter(opts))
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

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_positions/1`.
  """
  @impl true
  def get_positions(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_funding/2`.
  """
  @impl true
  def get_funding(_symbol, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_contract_stats/2`.
  """
  @impl true
  def get_contract_stats(_symbol, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_staking_rates/1`.
  """
  @impl true
  def get_staking_rates(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_staking_balances/1`.
  """
  @impl true
  def get_staking_balances(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_staking_rewards/1`.
  """
  @impl true
  def get_staking_rewards(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_staking_history/1`.
  """
  @impl true
  def get_staking_history(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.stake/3`.
  """
  @impl true
  def stake(_asset, _amount, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.unstake/3`.
  """
  @impl true
  def unstake(_asset, _amount, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.quote_conversion/4`.
  """
  @impl true
  def quote_conversion(_from, _to, _amount, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.commit_conversion/2`.
  """
  @impl true
  def commit_conversion(_id, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_conversion/2`.
  """
  @impl true
  def get_conversion(_id, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.convert/4`.
  """
  @impl true
  def convert(_from, _to, _amount, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_trade_volume/2`.
  """
  @impl true
  def get_trade_volume(_credentials, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.list_portfolios/1`.
  """
  @impl true
  def list_portfolios(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_deposit_address/3`.
  """
  @impl true
  def get_deposit_address(_asset, _network, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.list_approved_addresses/1`.
  """
  @impl true
  def list_approved_addresses(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.estimate_withdrawal_fee/4`.
  """
  @impl true
  def estimate_withdrawal_fee(_asset, _network, _amount, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.withdraw/5`.
  """
  @impl true
  def withdraw(_asset, _network, _amount, _address, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_option_chain/2`.
  """
  @impl true
  def get_option_chain(_underlying, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_option_expirations/2`.
  """
  @impl true
  def get_option_expirations(_underlying, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_option_greeks/2`.
  """
  @impl true
  def get_option_greeks(_symbol, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.list_watchlists/1`.
  """
  @impl true
  def list_watchlists(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_watchlist/2`.
  """
  @impl true
  def get_watchlist(_id, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.create_watchlist/3`.
  """
  @impl true
  def create_watchlist(_name, _symbols, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.update_watchlist/2`.
  """
  @impl true
  def update_watchlist(_id, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.delete_watchlist/2`.
  """
  @impl true
  def delete_watchlist(_id, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_financials/3`.
  """
  @impl true
  def get_financials(_symbol, _kind, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_corporate_events/1`.
  """
  @impl true
  def get_corporate_events(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_filings/2`.
  """
  @impl true
  def get_filings(_symbol, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_news/1`.
  """
  @impl true
  def get_news(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_screener/2`.
  """
  @impl true
  def get_screener(_name, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.create_account/1`.
  """
  @impl true
  def create_account(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.rename_account/3`.
  """
  @impl true
  def rename_account(_id, _name, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`.
  See `c:DpExchange.Core.Venue.get_roles/1`.
  """
  @impl true
  def get_roles(_opts), do: Venue.not_supported()
end
