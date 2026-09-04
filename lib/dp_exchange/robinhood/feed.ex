defmodule DpExchange.Robinhood.Feed do
  @moduledoc """
  This venue's feed — **a REST poll**, and nothing outside this module needs to know that.

  ## Why a venue with no socket still has a feed

  Robinhood Crypto exposes no streaming API. Under the shape this replaces, that fact
  travelled upward: the collection layer kept a poll set and decided which venues were
  exempt from it, and an operations page described Robinhood's pairs **in terms of a socket
  it does not have and has never claimed** — sending a reader hunting a streaming fault
  that cannot exist.

  Behind a feed, the poll is an implementation detail. This module delivers the same
  `Core.Types.TopOfBook` to the same subscriber as a WebSocket venue, so no consumer
  branches on transport, and `coverage/1` can report what the venue actually reports about
  itself: these symbols are arriving.

  **Not `Core.Types.Quote`.** This venue has no last-trade endpoint at all —
  `best_bid_ask` carries only bid and ask — and DpCryptoManagement's issue #21 is what
  happens when this polled `Core.Types.Quote.price` from the ask to paper over that: a
  fabricated trade price masquerading as a real one. See `DpExchange.Robinhood`'s
  moduledoc on `get_price/2`. Bid and ask are both genuine, so that is what this polls and
  delivers.

  ## Per symbol, because there is no bulk endpoint

  `best_bid_ask` carries no 24-hour statistics and the venue publishes no bulk-stats
  endpoint, so `Core.PollingFeed` runs each symbol on its own schedule — spread across the
  interval rather than swept in a burst. With 86 pairs, a burst would put 86 signed
  requests into one instant of a budget this venue has already proven sensitive to.

  ## `acquire`, not `check`

  A moduledoc worth carrying from the adapter this replaces. When rate limiting was first
  switched on for this venue — it had never been enabled at all — Robinhood went from
  **87 of 87 symbols delivering to 8 of 87 in a single cycle**. Not the venue throttling:
  our own limiter refusing calls the venue was perfectly happy to serve, because `check/3`
  answers "is there capacity right now" and a poll that finds none simply skips the symbol.

  `acquire/3` waits for capacity instead. A slower cycle rather than a missing price.

  **Documenting that design was not the same as wiring it.** `:rate_limit_blocking` —
  the option `Core.HttpClient.check_rate_limits/1` actually reads to choose `acquire/3`
  over `check/3` — was missing from this module's own forwarded-options allowlist, so no
  caller could ever turn it on: every request fell through to `check/3` regardless, and
  the failure this section describes reproduced exactly, live (DpCryptoManagement's issue
  #16). Forwarded now, and defaulted to `true` here specifically — not in `Rest`'s own
  allowlist, which a direct one-off `get_price/2` call also goes through and where
  fail-fast may be exactly what a caller wants. A poll is not a one-off call: this
  module's whole reason to exist is the venue's rate limit, so `acquire` is the only
  correct default for it.
  """

  alias DpExchange.Core.PollingFeed
  alias DpExchange.Robinhood.Rest

  # Matches the platform's collection cadence. Faster buys nothing on a venue whose quotes
  # are REST snapshots, and every symbol here costs one signed request.
  @interval_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    credentials = Keyword.get(opts, :credentials, %{})
    subscriber = Keyword.get(opts, :subscriber, self())

    request_opts =
      opts
      |> Keyword.take([
        :limiter,
        :plug,
        :req_adapter,
        :base_url,
        :retry_attempts,
        :rate_limit_blocking
      ])
      |> Keyword.put_new(:rate_limit_blocking, true)

    PollingFeed.start_link(
      name: Keyword.get(opts, :name),
      label: "robinhood",
      symbols: Keyword.get(opts, :symbols, []),
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      start_delay_ms: Keyword.get(opts, :start_delay_ms),
      sink: fn book -> send(subscriber, {:dp_exchange, :robinhood, book}) end,
      on_refusal: fn symbol, reason ->
        send(subscriber, {:dp_exchange, :robinhood, {:refused, symbol, reason}})
      end,
      fetch: fn symbol -> Rest.get_top_of_book(symbol, credentials, request_opts) end
    )
    |> case do
      # `PollingFeed` refuses to start without a fetcher, which cannot happen here — but
      # a feed that ran forever delivering nothing is indistinguishable from a quiet
      # venue, so the refusal is surfaced rather than swallowed.
      {:error, :no_fetcher} -> {:error, {:feed_misconfigured, :no_fetcher}}
      other -> other
    end
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Which symbols are actually arriving. Observed, never intended."
  @spec coverage(pid() | atom()) :: %{String.t() => :internal_poll}
  def coverage(feed), do: PollingFeed.coverage(feed)

  @doc "Replaces the polled set."
  @spec update_symbols(pid() | atom(), [String.t()]) :: :ok
  def update_symbols(feed, symbols), do: PollingFeed.update_symbols(feed, symbols)
end
