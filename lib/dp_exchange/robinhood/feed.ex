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
  `Core.Types.Quote` to the same subscriber as a WebSocket venue, so no consumer branches
  on transport, and `coverage/1` can report what the venue actually reports about itself:
  these symbols are arriving.

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
    request_opts = Keyword.take(opts, [:limiter, :plug, :req_adapter, :base_url, :retry_attempts])

    PollingFeed.start_link(
      name: Keyword.get(opts, :name),
      label: "robinhood",
      symbols: Keyword.get(opts, :symbols, []),
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      start_delay_ms: Keyword.get(opts, :start_delay_ms),
      sink: fn quote_struct -> send(subscriber, {:dp_exchange, :robinhood, quote_struct}) end,
      on_refusal: fn symbol, reason ->
        send(subscriber, {:dp_exchange, :robinhood, {:refused, symbol, reason}})
      end,
      fetch: fn symbol -> Rest.get_price(symbol, credentials, request_opts) end
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
