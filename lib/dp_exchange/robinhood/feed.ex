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

  ## Per symbol, for now — not because there is no bulk endpoint

  This runs `Core.PollingFeed` in its per-symbol `:fetch` mode, each symbol on its own
  schedule — spread across the interval rather than swept in a burst. With 86 pairs, a
  burst would put 86 signed requests into one instant of a budget this venue has already
  proven sensitive to.

  **Correction, 2026-09-06:** an earlier version of this note said the venue "publishes no
  bulk-stats endpoint" and left it there. That is not quite what the vendor's own OpenAPI
  document says. `best_bid_ask` genuinely carries no 24-hour statistics — that part holds —
  but its `symbol` query parameter is documented as repeatable: `?symbol=BTC-USD&symbol=
  ETH-USD` returns a `results` array covering every symbol asked for in ONE signed request.
  `Core.PollingFeed`'s own moduledoc names Robinhood as the intended user of its
  `:fetch_all` mode for exactly this shape. This module does not use it yet: the vendor's
  document does not say what a batched call does when one symbol in it is unlisted or
  malformed, and `PollingFeed`'s `fetch_all` path has no `on_refusal`-equivalent — a
  `{:refused, _}` returned from `:fetch_all` does not match either clause
  `fetch_all_and_publish/1` handles and would crash this feed's process instead of
  recording one refused symbol, which is a worse failure than today's per-symbol design for
  the one case (a delisted symbol mixed into a live batch) this venue's rate limit already
  makes likely. Adopting `:fetch_all` needs that answered against the live venue first —
  which is tier-2 work, done by hand, never on a schedule — or a `Core` change giving
  `:fetch_all` its own refusal path. Recorded as an idea, not implemented as a guess.

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
  allowlist, which a direct one-off `get_top_of_book/2` call also goes through and where
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

  ## A crashed poller used to be Feed's crash too — and now it is caught

  `PollingFeed.start_link/1` runs inside `init/1`, which links the poller to this
  process the way `start_link` always does. Before this fix, nothing here trapped exits,
  so an abnormal poller exit — this venue has no socket to crash instead, so the poller
  is the only linked child there is — sent an untrappable `EXIT` signal along that link
  and crashed `Feed` too, restarted by `DpExchange.Robinhood.Supervisor` from the
  *static* `opts` it was given at tree-start: any symbols added since boot via
  `update_symbols/2`, and every `subscribe_notices/1` registration, silently reverted.
  `Feed` traps exits now, restarts the poller with the symbol set it actually had —
  tracked in `state.symbols`, updated on every `update_symbols/2` call, precisely so a
  crash-restart has something truer to rebuild from than the opts this process started
  with — and reports a `:link_down` `Core.Notice` rather than leaving the crash silent.
  """

  use GenServer

  alias DpExchange.Core.{Notice, PollingFeed}
  alias DpExchange.Robinhood.{Credentials, Rest}

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
    # `PollingFeed.start_link/1` below runs inside this callback, which links the
    # poller to `Feed` — see the moduledoc's "A crashed poller used to be Feed's crash
    # too" section. Without this flag an abnormal poller exit is an untrappable EXIT
    # along that link and takes `Feed` down with it; `handle_info({:EXIT, pid, reason},
    # state)` below is what this flag makes reachable at all.
    Process.flag(:trap_exit, true)

    subscriber = Keyword.get(opts, :subscriber, self())

    state = %{
      poller: nil,
      subscriber: subscriber,
      notice_subscribers: MapSet.new([subscriber]),
      # Tracked here, not only inside `PollingFeed`'s own state, so a crash-restart has
      # something to rebuild the poller FROM: the opts this process started with are
      # static and never carry an `update_symbols/2` call made after boot.
      symbols: Keyword.get(opts, :symbols, []),
      # Wrapped immediately, before it reaches `state` — see `Credentials`'s moduledoc.
      # `start_poller/1`'s `fetch` closure and `Rest.get_top_of_book/3`/`Auth.headers/5`
      # keep working unchanged: a struct is a map.
      credentials: opts |> Keyword.get(:credentials, %{}) |> Credentials.wrap(),
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      start_delay_ms: Keyword.get(opts, :start_delay_ms),
      request_opts:
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
    }

    case start_poller(state) do
      {:ok, pid} ->
        {:ok, %{state | poller: pid}}

      # `PollingFeed` refuses to start without a fetcher, which cannot happen here — `fetch`
      # is always supplied above — but a feed that ran forever delivering nothing is
      # indistinguishable from a quiet venue, so the refusal is surfaced rather than
      # swallowed.
      {:error, :no_fetcher} ->
        {:stop, {:feed_misconfigured, :no_fetcher}}

      {:error, other} ->
        {:stop, other}
    end
  end

  # `state.credentials`/`state.request_opts`/`state.interval_ms`/`state.start_delay_ms`
  # never change after `init/1`; only `state.symbols` does, via `update_symbols/2` — so
  # this is the one place a fresh `PollingFeed` gets built, called from `init/1` for the
  # first one and from the crash handler for every one after.
  defp start_poller(state) do
    parent = self()
    credentials = state.credentials
    request_opts = state.request_opts

    PollingFeed.start_link(
      label: "robinhood",
      symbols: state.symbols,
      interval_ms: state.interval_ms,
      start_delay_ms: state.start_delay_ms,
      sink: fn book -> send(parent, {:dp_exchange, :robinhood, book}) end,
      on_refusal: fn symbol, reason ->
        send(parent, {:dp_exchange, :robinhood, {:refused, symbol, reason}})
      end,
      on_notice: fn notice -> send(parent, {:dp_exchange, :robinhood, notice}) end,
      fetch: fn symbol -> Rest.get_top_of_book(symbol, credentials, request_opts) end
    )
  end

  @impl true
  def handle_call(:coverage, _from, state) do
    {:reply, PollingFeed.coverage(state.poller), state}
  end

  def handle_call({:update_symbols, symbols}, _from, state) do
    state = %{state | symbols: symbols}
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

  # The other half of `init/1`'s `Process.flag(:trap_exit, true)` — see the moduledoc's
  # "A crashed poller used to be Feed's crash too" section. Matching on `state.poller` is
  # what tells a real crash apart from an `EXIT` this feed cannot attribute to anything
  # it started; a stale `EXIT` for an already-replaced poller falls through to the
  # catch-all below and is correctly ignored.
  def handle_info({:EXIT, pid, reason}, %{poller: pid} = state) do
    notify_poller_crashed(state, reason)

    case start_poller(state) do
      {:ok, new_poller} ->
        {:noreply, %{state | poller: new_poller}}

      # As unreachable in practice as `init/1`'s own `{:error, other}` branch — `fetch`
      # is always supplied — but this feed has no lesser fallback the way a socket-based
      # venue's `ensure_route/1` falls back to a poll: a poll IS this venue's only
      # route. Stopping hands the failure to `DpExchange.Robinhood.Supervisor`, the same
      # outcome `init/1` reaches for the identical error.
      {:error, other} ->
        {:stop, other, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Reports a crashed poller the same way a socket-based venue reports a crashed shard
  # or connection — without this, it is exactly the "silent half-dead feed" this
  # family's incidents are about: `Feed` recovers on its own, but a consumer watching
  # only `coverage/1` would see a gap with no notice explaining it.
  defp notify_poller_crashed(state, reason) do
    notice =
      Notice.new(:link_down, :robinhood,
        severity: :warning,
        message: "poll crashed (#{inspect(reason)}) — restarting now",
        details: %{reason: inspect(reason)}
      )

    fan_out(state.notice_subscribers, {:dp_exchange, :robinhood, notice})
  end

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
