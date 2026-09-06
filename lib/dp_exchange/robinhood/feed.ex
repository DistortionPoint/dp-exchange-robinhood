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

  ## A silent outage says so, not only to the log

  This is the venue `Core.PollingFeed`'s "delivered NOTHING" warning was written about:
  DpCryptoManagement's issue #21 is a wrong credential (ciphertext where a key belonged)
  producing a fetch failure on every symbol, every cycle, for a whole deployment, with the
  only trace a `Logger.warning` a human had to go grepping for. `dp_exchange_core` 0.1.50
  gives `PollingFeed.start_link/1` an `:on_notice` option for exactly this, and it is wired
  here the same way `on_refusal` already is: forwarded into this process, then fanned out to
  every registered notice subscriber (see below), so a coverage outage reaches more than a
  log line nothing downstream reacts to. It fires once on the transition into
  delivering-nothing (`severity: :warning`) and once on the transition back out
  (`severity: :info`) — never per tick and never per sweep while the outage continues, so
  an 86-symbol feed retrying every symbol every cycle does not turn one outage into a
  notice storm.

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

  ## A monitoring pid does not have to be the data subscriber

  `start_link/1`'s `:subscriber` is the single fixed pid that receives quotes, refusals
  and (until this section) notices — set once, at supervision-tree boot, because this
  venue's `subscribe/2` takes no `to:` of its own; there is no per-call registry for
  market data here, family-wide or otherwise. Notices are different on purpose:
  `subscribe_notices/2` — and `DpExchange.Robinhood.subscribe_notices/1` above it — adds a
  genuinely independent pid to `notice_subscribers`, so a monitoring process that never
  wants a `Core.Types.TopOfBook` can still learn this feed went dark, without displacing
  whoever is already registered to receive the quotes.

  **This module previously claimed that registry did not exist**, on the reasoning that
  `Core.PollingFeed` itself has no notion of more than one recipient — `sink`,
  `on_refusal` and `on_notice` are each exactly one injected function, by design (see
  `Core.PollingFeed`'s own moduledoc). That is still true and is not being fought here:
  the fan-out lives in THIS module, one layer up, exactly the way `dp_exchange_schwab`'s
  own `Feed` already fans its Streamer and fallback-poll notices out to more than one
  registrant. `PollingFeed` still owns fetching, scheduling and its own "delivering
  nothing" latch; this module owns nothing more than "who gets told," which is the part a
  single injected function structurally cannot express. Turning this module into a
  `GenServer` in its own right — where it used to simply *be* the `PollingFeed` process,
  registered under this module's name — is the smallest change that gives it somewhere to
  keep that set.
  """

  use GenServer

  alias DpExchange.Core.{Notice, PollingFeed}
  alias DpExchange.Robinhood.Rest

  # Matches the platform's collection cadence. Faster buys nothing on a venue whose quotes
  # are REST snapshots, and every symbol here costs one signed request.
  @interval_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Which symbols are actually arriving. Observed, never intended."
  @spec coverage(GenServer.server()) :: %{String.t() => :internal_poll}
  def coverage(feed), do: GenServer.call(feed, :coverage)

  @doc """
  `coverage/1`, split by kind — see `DpExchange.Robinhood.coverage_by_kind/1` for why
  the family wants this at all when Robinhood has nothing to split.

  Traceable to the actual struct, not assumed from the declared kind list: this feed's
  `fetch` calls only `Rest.get_top_of_book/3`, wired in `init/1` below, and that
  function returns exclusively `DpExchange.Core.Types.TopOfBook.t()` — never
  `DpExchange.Core.Types.Quote.t()` (see this module's own moduledoc on why not). Every
  symbol `coverage/1` reports therefore arrived through that one fetcher, so wrapping its
  map under `:top_of_book` reports what was actually produced, not a guess.
  """
  @spec coverage_by_kind(GenServer.server()) :: %{top_of_book: %{String.t() => :internal_poll}}
  def coverage_by_kind(feed), do: %{top_of_book: coverage(feed)}

  @doc "Replaces the polled set."
  @spec update_symbols(GenServer.server(), [String.t()]) :: :ok
  def update_symbols(feed, symbols), do: GenServer.call(feed, {:update_symbols, symbols})

  @doc """
  Registers `opts[:to]` (default: the caller) to receive this feed's own `Core.Notice`
  traffic — currently the coverage-outage pair described in this module's moduledoc.

  Additive, never a replacement: the fixed `:subscriber` given to `start_link/1` keeps
  receiving notices too, exactly as it did before this registry existed. A dead pid or an
  unregistered name is skipped at delivery time rather than raised on — see `fan_out/2`.
  """
  @spec subscribe_notices(GenServer.server(), keyword()) :: :ok
  def subscribe_notices(feed, opts \\ []),
    do: GenServer.call(feed, {:subscribe_notices, Keyword.get(opts, :to, self())})

  # --- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    credentials = Keyword.get(opts, :credentials, %{})
    subscriber = Keyword.get(opts, :subscriber, self())
    parent = self()

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

    poller =
      PollingFeed.start_link(
        label: "robinhood",
        symbols: Keyword.get(opts, :symbols, []),
        interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
        start_delay_ms: Keyword.get(opts, :start_delay_ms),
        sink: fn book -> send(parent, {:dp_exchange, :robinhood, book}) end,
        on_refusal: fn symbol, reason ->
          send(parent, {:dp_exchange, :robinhood, {:refused, symbol, reason}})
        end,
        on_notice: fn notice -> send(parent, {:dp_exchange, :robinhood, notice}) end,
        fetch: fn symbol -> Rest.get_top_of_book(symbol, credentials, request_opts) end
      )

    case poller do
      {:ok, pid} ->
        {:ok,
         %{poller: pid, subscriber: subscriber, notice_subscribers: MapSet.new([subscriber])}}

      # `PollingFeed` refuses to start without a fetcher, which cannot happen here — `fetch`
      # is always supplied above — but a feed that ran forever delivering nothing is
      # indistinguishable from a quiet venue, so the refusal is surfaced rather than
      # swallowed.
      {:error, :no_fetcher} ->
        {:stop, {:feed_misconfigured, :no_fetcher}}

      other ->
        {:stop, other}
    end
  end

  @impl true
  def handle_call(:coverage, _from, state) do
    {:reply, PollingFeed.coverage(state.poller), state}
  end

  def handle_call({:update_symbols, symbols}, _from, state) do
    {:reply, PollingFeed.update_symbols(state.poller, symbols), state}
  end

  def handle_call({:subscribe_notices, subscriber}, _from, state) do
    {:reply, :ok, %{state | notice_subscribers: MapSet.put(state.notice_subscribers, subscriber)}}
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :unknown_call}, state}

  @impl true
  def handle_info({:dp_exchange, :robinhood, %Notice{}} = message, state) do
    fan_out(state.notice_subscribers, message)
    {:noreply, state}
  end

  def handle_info({:dp_exchange, :robinhood, _payload} = message, state) do
    fan_out([state.subscriber], message)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # A dead subscriber stops delivery rather than crashing it. A subscriber may be a raw
  # pid or a registered name — `subscribe_notices/2`'s `to:` accepts either, matching
  # ordinary OTP practice — and `send/2` to an unregistered atom RAISES, which would take
  # this whole process down on every notice rather than merely skipping one recipient.
  # Same defect, same fix, as `dp_exchange_schwab` and `dp_exchange_coinbase`'s own
  # `Feed.fan_out/2` (DpCryptoManagement issue #15): resolve first, uniformly, then send
  # only to what resolved to a live pid.
  defp fan_out(subscribers, message) do
    Enum.each(subscribers, fn subscriber ->
      case resolve_subscriber(subscriber) do
        pid when is_pid(pid) -> send(pid, message)
        nil -> :ok
      end
    end)
  end

  defp resolve_subscriber(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid
  end

  defp resolve_subscriber(name) when is_atom(name), do: Process.whereis(name)
end
