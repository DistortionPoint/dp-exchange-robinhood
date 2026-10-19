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

  ## One request per cycle, not one per symbol

  This runs `Core.PollingFeed` in its bulk `:fetch_all` mode: every tick sends ONE signed
  request carrying every symbol in scope, via `Rest.get_top_of_book_bulk/3`, rather than one
  signed request per symbol. At the ~86-pair catalogue this package inherited, that is the
  difference between roughly 86 requests a cycle and 1. A universe larger than
  `Rest.max_bulk_symbols/0` (100, our own conservative cap; the vendor states none) is sent
  as several requests of at most that many, so the signed URL stays bounded at 1,000+
  symbols; results are merged as one request's would be.

  **Correction, 2026-09-06:** an earlier version of this note said the venue "publishes no
  bulk-stats endpoint" and left it there. That is not quite what the vendor's own OpenAPI
  document says. `best_bid_ask` genuinely carries no 24-hour statistics — that part holds —
  but its `symbol` query parameter is documented as repeatable: `?symbol=BTC-USD&symbol=
  ETH-USD` returns a `results` array covering every symbol asked for in ONE signed request.
  This module ran per-symbol for a time after that correction, recorded as
  `docs/design/ideas/bulk-best-bid-ask-fetch.md`, because two things were true:
  `Core.PollingFeed`'s own moduledoc names Robinhood as the intended user of its
  `:fetch_all` mode for exactly this shape, but the vendor's document never says what a
  batched call does when one symbol in it is unlisted or malformed — drop that row and 200
  the rest, or 400 the whole request — and `PollingFeed`'s `fetch_all` path had no
  `on_refusal`-equivalent, so a `{:refused, _}` from a bulk fetcher would crash this feed's
  process instead of recording one refused symbol. `dp_exchange_core` gained that handling
  (`fetch_all_and_publish/1`'s `{:refused, refusals}` clause), which closed the second
  condition, but the first — what the venue actually does on a partial-bad batch — is
  still not stated anywhere this package can read.

  **So this does not guess.** `fetch_all/6` below sends the bulk request and reads
  whatever comes back:

  - A `results` array with every row filled: published, same as before, at 1/86th the
    request cost.
  - A `results` array SHORTER than what was asked for: also published, as-is. A missing
    row is silence — the venue not answering for that symbol on THIS request — not a
    venue statement that the symbol does not exist, and `PollingFeed` already treats a
    symbol absent from a bulk response as uncovered-and-retried, never as refused (see its
    own `publish_and_record/2`). Turning silence into a refusal is the exact defect
    DpCryptoManagement issue #25 fixed on the single-symbol path (the comment on
    `Rest.result_for/2`), and this path must not reintroduce it on the bulk one.
  - The WHOLE request refused (400/401/403/404) — the shape a single bad symbol could
    plausibly produce, and the one this module used to have no safe answer for.
    `fetch_all/6` splits the batch and asks again until it reaches the symbol the venue
    objects to (see "A refused batch is bisected, and a refused symbol is remembered"
    below). It reports every refusal it finds by CALLING the same `on_refusal` function
    `PollingFeed` itself would have called, directly, rather than by returning
    `{:refused, refusals}`, because the return channel cannot carry both the refusal and the
    other symbols' events in one outcome. So the bad symbol is reported (once per cycle it
    stays in scope, as the venue's own per-symbol refusal already behaves when a consumer
    never drops it) AND every other symbol that answers publishes in the SAME cycle. From
    the next cycle the refused symbol is asked for on its own, and the rest are back to one
    request without waiting for a consumer to drop it.
  - The whole request merely erroring (a 5xx, a network failure) is left alone: retried
    next tick the ordinary way, at the ordinary one-request cost. Falling back per symbol
    here would not identify anything — an outage affects every symbol on either path
    alike — and would spend 86 requests to learn nothing a plain retry does not already
    cover.

  No single bad symbol can make this feed deliver nothing indefinitely: the worst case is
  one degraded cycle before the offending symbol is out of scope, never a permanent
  whole-batch failure.

  ## A refused batch is bisected, and a refused symbol is remembered

  The fallback above used to be one request per symbol, sequentially, inside `PollingFeed`'s
  fetch. That fetch is killed at `:fetch_timeout_ms`, which is 30s at this feed's 30s
  interval. This venue's documented limit is 100 requests a minute per account (bursts of
  300), so 300 symbols could not finish in time on the limiter alone, and fewer could not
  either once ordinary latency and retries were added. A killed fetch publishes nothing. The
  next cycle sent the same bulk request, was refused again, and fell back again, so one bad
  symbol past that size meant every symbol delivered nothing, every cycle: the failure the
  fallback existed to prevent.
  It also ran on a 401, where every per-symbol request is refused alike, spending one
  request per symbol per cycle to learn nothing.

  Now:

  - **A refused batch is split in half and each half asked again**, down to single
    symbols. One bad symbol among 300 is found in about 17 requests, not 300. A cycle
    stops splitting at `@bisect_budget_ms` (20s), well inside the fetch timeout (which is
    raised to the budget plus 10s when `:bisect_budget_ms` is configured past what
    `PollingFeed` derives from the interval, so a larger budget is never killed). What it
    has not resolved by then is silence, retried next cycle, never reported as refused.
    Each request after the first is sent with `:timeout` capped to the budget left, which
    also bounds a limiter wait, so no single request overruns the deadline.
  - **A symbol the venue refused is remembered** (`state.refused`) until it delivers again
    or leaves scope. The next cycle's bulk request leaves it out, so the others are back to
    ONE request without waiting for a consumer to drop it. The remembered symbols are
    asked for in a request of their own, and bisected again if more than one, so one that
    starts answering rejoins at once, and one still refused is reported again, once per
    cycle, as before.
  - **A 401 or 403 is not split.** An unauthenticated request is refused for every symbol
    alike. It is returned as the cycle's error, and `PollingFeed`'s "delivering nothing"
    notice says so, with no per-symbol refusals attributed to symbols that did nothing wrong.
    The remembered-refused symbols are not asked for in that cycle either.

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

  `start_link/1`'s `:subscriber` is a pid that receives quotes, refusals and notices from
  boot, and it stays one of the data subscribers. It is no longer the only one:
  `add_symbols/3` (behind `DpExchange.Robinhood.subscribe/2`) registers `to:` (default the
  caller) as a data subscriber too, as `Core.Venue.subscribe/2` promises ("events arrive as
  messages to the subscribing process, or to a pid given in `opts`"). This used to ignore
  `to:` and deliver only to the boot subscriber. Data goes out through `Core.Fanout`, so a
  stalled consumer is bounded by `:max_queue_len` and a dead one is dropped on `:DOWN`.
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

  The restart is bounded. A poller that died on every start was restarted at once, forever,
  one `:link_down` per turn, and no supervisor's intensity limited it because `Feed` itself
  never died. More than five crashes within a minute stop `Feed` with
  `{:poller_crash_loop, reason}`, handing the loop to the supervisor.
  """

  use GenServer

  alias DpExchange.Core.{Config, Fanout, Notice, PollingFeed}
  alias DpExchange.Robinhood.{Credentials, Rest}

  # Matches the platform's collection cadence — an internal/operational choice, not
  # derived from any Robinhood-published rate limit. Faster buys nothing on a venue whose
  # quotes are REST snapshots, and every symbol here costs one signed request.
  #
  # NOT chosen against `Capabilities.public_ceiling`/`authenticated_ceiling` (the
  # vendor's documented 100 requests a minute per account, bursts of 300 — documented, not
  # probed; see `robinhood.ex`'s own `measured_against`). Noted for a reader doing the
  # arithmetic: the poll is ONE bulk request per tick (see the moduledoc), so this cadence
  # costs 2 requests a minute against that ceiling when nothing is refused. That headroom
  # is a coincidence of the two numbers, not a derivation of one from the other.
  @interval_ms 30_000

  # How long one cycle may spend bisecting a refused batch. Well inside `PollingFeed`'s
  # fetch timeout (its 30s floor), so a bisection is never killed part-way and its
  # findings lost. See the moduledoc's "A refused batch is bisected".
  @bisect_budget_ms 20_000

  # Poller restarts tolerated within one window before the crash is handed to the
  # supervisor. See `handle_info({:EXIT, ...})`.
  @max_poller_restarts 5
  @poller_crash_window_ms 60_000

  # Every call INTO this Feed carries this explicitly, reads included, rather than taking
  # `GenServer.call/2`'s implicit five seconds.
  #
  # The asymmetry it replaces is what turned a bounded delay into a dead caller in
  # dp-exchange-core issue #28: writes named a generous timeout while reads — `coverage/1`,
  # the call a consumer's health check actually makes — silently took the 5s default. Any
  # moment this process was busy for longer than that (and `Core.PollingFeed`'s fetch
  # timeout floors at 30 seconds) turned a read into an EXIT, which killed the consumer's
  # own process when it read from inside its own `handle_call/3`.
  #
  # The blocking is fixed at its source — `Core.PollingFeed` no longer waits on its fetch —
  # so this is the second line of defence rather than the fix: a read that has to queue
  # behind something should WAIT for it, never die of it.
  @call_timeout 15_000

  @doc """
  Starts the feed, registered as `opts[:name]` (default: this module).

  Refuses to start, as `{:error, {:invalid_option, key}}`, when `:symbols` is not a list of
  non-blank strings, `:subscriber` is neither a pid nor a registered name, or
  `:bisect_budget_ms` is not a positive integer. A `:max_queue_len` that is not a positive
  integer is not an `{:error, _}` return: it raises `ArgumentError` from `init/1`
  (`Core.Fanout.max_queue_len!/2`), so a back-pressure bound you believe you set is never
  silently replaced by the default.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    # Wrapped (idempotently) so a raw `:credentials` map never sits in a start argument a
    # crash report could print, whichever way the feed was started.
    opts = Credentials.wrap_opt(opts)

    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The child spec for supervising this feed directly, with `opts[:credentials]` wrapped.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  # `Credentials.wrap_opt/1` for the same reason the venue module's own `child_spec/1` does
  # it (dp-exchange-core issue #29): whatever supervises this child stores these args and
  # OTP prints them on any termination. Reached here on the documented path already wrapped
  # — this covers a consumer that supervises the feed directly.
  def child_spec(opts) do
    opts = DpExchange.Robinhood.Credentials.wrap_opt(opts)

    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Which symbols are actually arriving. Observed, never intended."
  @spec coverage(GenServer.server()) :: %{String.t() => :internal_poll}
  def coverage(feed), do: GenServer.call(feed, :coverage, @call_timeout)

  @doc """
  `coverage/1`, split by kind — see `DpExchange.Robinhood.coverage_by_kind/1` for why
  the family wants this at all when Robinhood has nothing to split.

  Traceable to the actual struct, not assumed from the declared kind list: this feed's
  fetcher calls only `Rest.get_top_of_book_bulk/3`, wired in `start_poller/1` below, and
  that function returns exclusively `DpExchange.Core.Types.TopOfBook.t()` — never
  `DpExchange.Core.Types.Quote.t()` (see this module's own moduledoc on why not). Every
  symbol `coverage/1` reports therefore arrived through that one fetcher, so wrapping its
  map under `:top_of_book` reports what was actually produced, not a guess.
  """
  @spec coverage_by_kind(GenServer.server()) :: %{top_of_book: %{String.t() => :internal_poll}}
  def coverage_by_kind(feed), do: %{top_of_book: coverage(feed)}

  @doc """
  Replaces the polled set. Symbols are upper-cased and de-duplicated here, as at boot; a
  list that is not made of non-blank strings is refused as `{:error, {:invalid_symbols,
  value}}` and the set is left as it was. It used to raise inside the feed process for a
  non-list, which restarted the feed from its boot-time opts.
  """
  @spec update_symbols(GenServer.server(), term()) :: :ok | {:error, {:invalid_symbols, term()}}
  def update_symbols(feed, symbols),
    do: GenServer.call(feed, {:update_symbols, symbols}, @call_timeout)

  @doc """
  The canonical spelling of a symbol list: upper-cased and de-duplicated.

  `{:error, {:invalid_symbols, value}}` for anything that is not a proper list of non-blank
  strings (whitespace-only is blank). Shared by the facade, `Fake` and this feed's own
  calls, so all three refuse the same values.

  **Symbols are upper-cased on the way in.** Canonical symbols are upper case, and `Feed`
  drops a payload whose symbol it does not want. So a caller who subscribed `btc-usd` got
  nothing at all, because the venue delivers `BTC-USD`. Until 2026-09-27 that same caller
  was delivered to, because nothing compared the two. Measured 2026-09-28:
  `update_symbols(["btc-usd"])`, then a `BTC-USD` quote, and `coverage/1` was `%{}`. Case is
  the one difference normalised here. Anything else that is not canonical is the caller's
  to fix.
  """
  @spec canonical_symbols(term()) :: {:ok, [String.t()]} | {:error, {:invalid_symbols, term()}}
  def canonical_symbols(symbols) do
    case boot_symbols(symbols) do
      {:ok, _checked} = ok -> ok
      :error -> {:error, {:invalid_symbols, symbols}}
    end
  end

  @doc """
  A subscriber this feed can send to: a pid, or a registered name (an atom other than
  `nil`, `true` and `false`).

  `{:error, {:invalid_subscriber, value}}` otherwise. `true` and `false` are atoms but not
  names anyone registers, so they are refused rather than silently never delivered to.
  """
  @spec valid_subscriber(term()) ::
          {:ok, pid() | atom()} | {:error, {:invalid_subscriber, term()}}
  def valid_subscriber(pid) when is_pid(pid), do: {:ok, pid}

  def valid_subscriber(name) when is_atom(name) and name not in [nil, true, false],
    do: {:ok, name}

  def valid_subscriber(other), do: {:error, {:invalid_subscriber, other}}

  @doc """
  Adds `symbols` to the polled set, inside this process, and registers `subscriber` (when
  given) to receive this feed's market data.

  `subscriber` is a pid or a registered name; the facade passes `opts[:to]`, default the
  caller. It is added to the boot `:subscriber`, never replacing it. Registering a pid
  monitors it, and its death removes it. A subscriber that is not a pid or a name is
  `{:error, {:invalid_subscriber, value}}` and nothing is changed.

  **Not `update_symbols(coverage ++ symbols)`.** `DpExchange.Robinhood.subscribe/2` used to
  do exactly that, and `coverage/1` is what has been observed arriving, not what was asked
  for. A symbol subscribed a moment ago, one the venue is refusing, or one whose last poll
  failed is absent from it. So a second `subscribe/2` silently dropped every wanted symbol
  that had not yet delivered. It was also a read then a write from the caller's process,
  so two callers subscribing at once could each overwrite the other. Both are gone when the
  set is changed here, against `state.symbols`, in one call.
  """
  @spec add_symbols(GenServer.server(), term(), term()) ::
          :ok | {:error, {:invalid_symbols, term()} | {:invalid_subscriber, term()}}
  def add_symbols(feed, symbols, subscriber \\ nil),
    do: GenServer.call(feed, {:add_symbols, symbols, subscriber}, @call_timeout)

  @doc """
  Removes `symbols` from the polled set, inside this process. See `add_symbols/2`.

  Upper-cased like every other entry point, so `"btc-usd"` removes `"BTC-USD"`.
  """
  @spec remove_symbols(GenServer.server(), term()) ::
          :ok | {:error, {:invalid_symbols, term()}}
  def remove_symbols(feed, symbols),
    do: GenServer.call(feed, {:remove_symbols, symbols}, @call_timeout)

  @doc "What has been asked for, which is not what `coverage/1` reports."
  @spec wanted(GenServer.server()) :: [String.t()]
  def wanted(feed), do: GenServer.call(feed, :wanted, @call_timeout)

  @doc """
  Registers `opts[:to]` (default: the caller) to receive this feed's own `Core.Notice`
  traffic — currently the coverage-outage pair described in this module's moduledoc.

  Additive, never a replacement: the fixed `:subscriber` given to `start_link/1` keeps
  receiving notices too, exactly as it did before this registry existed. A dead pid or an
  unregistered name is skipped at delivery time rather than raised on — see `fan_out/2`.

  `:to` must be a pid or a registered name (an atom other than `nil`, `true` and `false`).
  Anything else, a string or a `{:via, _, _}` tuple or a boolean, is refused as `{:error,
  {:invalid_subscriber, value}}`: it used to be stored, and `Core.Fanout.resolve/1` has no
  clause for it, so the feed crashed on its next notice. (This was `{:invalid_field, :to}`,
  and `true`/`false` were accepted, before the family converged on `:invalid_subscriber`.)
  """
  # `@call_timeout`, not `GenServer.call/2`'s five-second default.
  #
  # This was the one public call in this module left on the default, and it is the worst one
  # to leave short. `@call_timeout` is the authors' own statement of how long this feed may
  # legitimately take to answer, and every sibling call — `subscribe/3`, `unsubscribe/2`,
  # `update_symbols/2`, `coverage/1` — is allowed it on the same mailbox. A consumer
  # registers for notices at start-up, which is precisely when that mailbox is deepest: the
  # transport is coming up, symbols are being resolved, and this handler itself may replay a
  # notice to the newly-registered subscriber.
  #
  # A `GenServer.call/3` timeout exits in the CALLER, not in the feed. So the channel a host
  # uses to *hear that something is wrong* was the one call that could kill the host's
  # calling process for asking during exactly the conditions it exists to report.
  @spec subscribe_notices(GenServer.server(), keyword()) ::
          :ok | {:error, {:invalid_subscriber, term()}}
  def subscribe_notices(feed, opts \\ []),
    do: GenServer.call(feed, {:subscribe_notices, Config.opt(opts, :to, self())}, @call_timeout)

  # --- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    # `environment: :sandbox` has no sandbox to go to; see `Rest.check_environment/1`. The
    # feed refuses to start rather than poll production under a name that says it is a test.
    case Rest.check_environment(opts) do
      :ok -> init_options(opts)
      {:error, {:unsupported_option, :environment}} -> {:stop, {:invalid_option, :environment}}
    end
  end

  defp init_options(opts) do
    symbols = boot_symbols(Config.opt(opts, :symbols, []))
    subscriber? = subscriber?(Config.opt(opts, :subscriber, nil))

    budget? = valid_budget?(Config.opt(opts, :bisect_budget_ms, @bisect_budget_ms))

    case {symbols, subscriber?, budget?} do
      {{:ok, symbols}, true, true} -> init_feed(opts, symbols)
      {:error, _subscriber?, _budget?} -> {:stop, {:invalid_option, :symbols}}
      {{:ok, _symbols}, false, _budget?} -> {:stop, {:invalid_option, :subscriber}}
      {{:ok, _symbols}, true, false} -> {:stop, {:invalid_option, :bisect_budget_ms}}
    end
  end

  # A budget that is not a positive integer made every cycle's deadline arithmetic raise in the
  # fetch task, so the feed delivered nothing, cycle after cycle, with only a fetch failure to
  # show for it. Refused at start instead.
  defp valid_budget?(budget), do: is_integer(budget) and budget > 0

  # A pid, a registered name, or none. Anything else has no `Core.Fanout.resolve/1` clause and
  # would crash this feed on its first delivery.
  defp subscriber?(nil), do: true
  defp subscriber?(subscriber), do: match?({:ok, _name_or_pid}, valid_subscriber(subscriber))

  # **Upper-cased at boot, as `DpExchange.Robinhood.subscribe/2` does at call time.** The
  # book comes back under the canonical (upper-case) symbol and `handle_info/2` drops a book
  # whose symbol is not in `state.symbols`, so a feed started with `symbols: ["btc-usd"]`
  # polled the venue every cycle and delivered nothing, with no notice: the facade
  # normalised the later calls and not this one. A list that is not a list of non-blank
  # strings stops the feed rather than polling a symbol the venue refuses whole.
  defp boot_symbols(symbols) when is_list(symbols) do
    if proper_list?(symbols) and Enum.all?(symbols, &(is_binary(&1) and String.trim(&1) != "")),
      do: {:ok, symbols |> Enum.map(&String.upcase/1) |> Enum.uniq()},
      else: :error
  end

  defp boot_symbols(_not_a_list), do: :error

  # An improper list (`[a | b]`) is a list to `is_list/1` and raises in `Enum`.
  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_improper), do: false

  defp init_feed(opts, symbols) do
    # `PollingFeed.start_link/1` below runs inside this callback, which links the
    # poller to `Feed` — see the moduledoc's "A crashed poller used to be Feed's crash
    # too" section. Without this flag an abnormal poller exit is an untrappable EXIT
    # along that link and takes `Feed` down with it; `handle_info({:EXIT, pid, reason},
    # state)` below is what this flag makes reachable at all.
    Process.flag(:trap_exit, true)

    # **No default, and never `self()`.** Inside `init/1` `self()` is this Feed, so a feed
    # started without `:subscriber` delivered each polled book to itself, where `deliver/2`
    # sent it to itself again, forever: a busy loop that delivered nothing to anyone (found
    # 2026-10-10). Without one, data goes to nobody and notices only to `subscribe_notices/2`.
    subscriber = Config.opt(opts, :subscriber, nil)

    state = %{
      poller: nil,
      # Monotonic ms of recent poller crashes, newest first — bounds the restart loop.
      poller_crashes: [],
      subscriber: subscriber,
      notice_subscribers: if(subscriber, do: MapSet.new([subscriber]), else: MapSet.new()),
      # Data subscribers registered by `add_symbols/3` (the facade's `subscribe/2`), beside
      # the boot `:subscriber`, which is not in this set. Pids are monitored (`monitors`
      # below, shared with `notice_subscribers`) and pruned on `:DOWN`.
      data_subscribers: MapSet.new(),
      # Symbols added by `add_symbols/3` for a registered data subscriber, and still wanted.
      # When the last such subscriber dies (and there is no boot `:subscriber`) these are
      # released, so the poller stops requesting books that nobody can receive.
      added: MapSet.new(),
      # Which poll cycle is next (rotates the chunk that goes first) and whether the last
      # cycle left symbols unrequested for want of budget (the latch behind the one
      # `:degraded` notice per crossing). See `report_budget/2`.
      cycle: 0,
      budget_exhausted: false,
      # Latches: a `:link_down` is open until the next good poll closes it with a `:link_up`;
      # `:credentials_rejected` is open until the next good poll. See `{:poll_result, _}`.
      link_down: false,
      credentials_rejected: false,
      # Monitor references for pid entries in `notice_subscribers`, so a dead one is dropped
      # rather than walked on every notice for the life of this feed — see the `:DOWN`
      # clause below and `Core.Fanout.watch/2`.
      #
      # `state.subscriber` above is deliberately absent from this, and the distinction is
      # the point: it is CONFIGURATION, not a subscription. It arrives in `start_link/1`'s
      # opts, no call can change it, and `notice_subscribers` is the only set here that
      # grows. Pruning it when its holder dies would leave a feed that can never deliver
      # again with no call able to repair it — and it cannot leak either, being one pid
      # rather than a set that accumulates.
      monitors: %{},
      # Back-pressure, per `Core.Venue`'s `subscribe/2` doc and implemented by
      # `Core.Fanout`. This venue polls rather than streams, so the rate is its own
      # `interval_ms` and not a venue firehose — but a consumer stalled for long enough
      # still grows an unbounded mailbox, and a bound that only exists on the venues where
      # it is most obviously needed is a contract guarantee with holes in it.
      dropping: MapSet.new(),
      max_queue_len: Fanout.max_queue_len!(opts, :robinhood),
      # Tracked here, not only inside `PollingFeed`'s own state, so a crash-restart has
      # something to rebuild the poller FROM: the opts this process started with are
      # static and never carry an `update_symbols/2` call made after boot.
      symbols: symbols,
      # The same set as a `MapSet`, for the per-book membership test in `handle_info/2`
      # (one book per symbol per cycle: a list scan there is O(n^2) over the universe).
      # Kept in step with `symbols` by `replace_symbols/2` and nowhere else.
      symbol_set: MapSet.new(symbols),
      # Symbols the venue has refused and that have not delivered since. Added on a
      # `{:refused, symbol, _}`, removed when that symbol's book arrives or it leaves scope.
      # The fetch reads it so the bulk request leaves them out.
      refused: MapSet.new(),
      # Wrapped immediately, before it reaches `state` — see `Credentials`'s moduledoc.
      # `start_poller/1`'s `fetch` closure and `Rest.get_top_of_book/3`/`Auth.headers/5`
      # keep working unchanged: a struct is a map.
      credentials: opts |> Keyword.get(:credentials, %{}) |> Credentials.wrap(),
      interval_ms: Config.opt(opts, :interval_ms, @interval_ms),
      # How long one cycle may spend bisecting; see `@bisect_budget_ms`.
      bisect_budget_ms: Config.opt(opts, :bisect_budget_ms, @bisect_budget_ms),
      start_delay_ms: Keyword.get(opts, :start_delay_ms),
      request_opts:
        opts
        |> Keyword.take([
          :plug,
          :adapter,
          :req_adapter,
          :base_url,
          :retry_attempts,
          :retry_delay,
          :timeout,
          :log_requests,
          :weight,
          :max_retry_after_s,
          :max_body_bytes
        ])
        # `Config.opt/3`, not `put_new/3`: a forwarded `rate_limit_blocking: nil` is a
        # PRESENT key, which `put_new/3` keeps, and `HttpClient` reads `nil` as `false` — the
        # `check/3` path this default exists to keep the poll off. An explicit `false` is
        # still honoured.
        |> Keyword.put(:rate_limit_blocking, Config.opt(opts, :rate_limit_blocking, true))
        # **Always named, never left to `Core.HttpClient`'s own default.** The supervisor
        # starts this venue's limiter under `Supervisor.limiter_name/1` and hands the feed
        # only the consumer's opts, so a consumer who never passed `:limiter` (the normal
        # case) reached here with no limiter at all. `HttpClient` then asked
        # `DefaultRateLimiter`'s own default-named process, which this package never starts:
        # every poll failed `:rate_limiter_unavailable` and the feed delivered nothing. The
        # facade's REST calls already default it (`with_limiter/1`); the poll must too.
        |> Keyword.put(:limiter, DpExchange.Robinhood.Supervisor.limiter_name(opts))
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
    budget_ms = state.bisect_budget_ms

    # Named so it can be handed to `PollingFeed` for its own per-symbol refusal channel
    # AND reused inside `fetch_all/6`'s bisection below — one function, one
    # meaning ("the venue just said so"), used from both places rather than reimplemented.
    on_refusal = fn symbol, reason ->
      send(parent, {:dp_exchange, :robinhood, {:refused, symbol, reason}})
    end

    PollingFeed.start_link(
      label: "robinhood",
      # `provider:` so `Core.PollingFeed`'s notices name this venue the same way this
      # module's own do. Without it the poll named itself by its string `label`, and a
      # consumer matching `notice.provider == :robinhood` saw the `:link_down` notices this
      # file builds and silently missed every `:coverage_change` the poll raised — which is
      # the one that says the feed is delivering nothing, the thing most worth hearing.
      # `label` still names the feed inside `message` and `details.label`.
      provider: :robinhood,
      symbols: state.symbols,
      interval_ms: state.interval_ms,
      start_delay_ms: state.start_delay_ms,
      fetch_timeout_ms: fetch_timeout_ms(state.interval_ms, budget_ms),
      sink: fn book -> send(parent, {:dp_exchange, :robinhood, book}) end,
      on_refusal: on_refusal,
      on_notice: fn notice -> send(parent, {:dp_exchange, :robinhood, notice}) end,
      fetch_all: fn symbols ->
        fetch_all(symbols, credentials, request_opts, on_refusal, parent, budget_ms)
      end
    )
  end

  # **The fetch is allowed the whole bisection budget, and a margin.** `PollingFeed` kills a
  # fetch at `:fetch_timeout_ms`, which it derives from the interval alone (clamped to
  # 30..60s). A `:bisect_budget_ms` past that derived bound let the kill land inside a
  # bisection, losing every finding it had made: the failure `@bisect_budget_ms` is documented
  # to prevent, reachable by configuring it. The default (20s budget, 30s floor) is the
  # derivation `PollingFeed` already made, so a default feed is unchanged.
  @fetch_margin_ms 10_000
  @min_fetch_timeout_ms 30_000
  @max_fetch_timeout_ms 60_000

  defp fetch_timeout_ms(interval_ms, budget_ms) do
    derived = interval_ms |> max(@min_fetch_timeout_ms) |> min(@max_fetch_timeout_ms)
    max(derived, budget_ms + @fetch_margin_ms)
  end

  # The `:fetch_all` this feed hands to `PollingFeed` — see the moduledoc's "This does not
  # guess" and "A refused batch is bisected, and a refused symbol is remembered" sections.
  # Symbols the venue has already refused are asked for separately, so the rest go back to
  # one request. A refusal is reported by CALLING `on_refusal`, not through the return
  # value: `PollingFeed`'s `fetch_all` contract carries one outcome per call, and a cycle
  # that found a bad symbol also has every other symbol's events to publish.
  defp fetch_all(symbols, credentials, request_opts, on_refusal, parent, budget_ms) do
    {refused, cycle} = cycle_plan(parent)
    {suspect, active} = Enum.split_with(symbols, &MapSet.member?(refused, &1))

    ctx = %{
      credentials: credentials,
      request_opts: request_opts,
      on_refusal: on_refusal,
      deadline: System.monotonic_time(:millisecond) + budget_ms
    }

    # Only the cycle's first request runs on the caller's own timeout.
    active_outcomes = resolve(active, ctx, false, cycle)

    # A credential the venue rejected is rejected for the remembered symbols too, so asking
    # for them as well would spend a request to learn what the first one already said.
    outcomes =
      if auth_failure?(active_outcomes),
        do: active_outcomes,
        else: active_outcomes ++ resolve(suspect, ctx, true, cycle)

    report_budget(parent, outcomes)

    events = for({:events, events} <- outcomes, do: events) |> List.flatten()
    report_result(parent, outcomes, events)

    case events do
      [] -> no_events(outcomes)
      events -> {:ok, events}
    end
  end

  # Tells the feed whether the cycle was a good one, for the `:link_up` and
  # `:credentials_rejected` latches. A cycle that was refused for credentials is not good
  # even when another chunk delivered.
  defp report_result(parent, outcomes, events) do
    result =
      cond do
        auth_failure?(outcomes) -> :credentials_rejected
        events != [] -> :ok
        true -> :silent
      end

    send(parent, {:poll_result, result})
  end

  defp auth_failure?(outcomes) do
    Enum.any?(outcomes, fn
      {:error, {:venue_error, status}} when status in [401, 403] -> true
      {:error, {:venue_error, status, _detail}} when status in [401, 403] -> true
      _other -> false
    end)
  end

  # Every outcome can be `{:events, []}`: a 200 with an empty `results`, which is silence,
  # not a refusal. That reached `elem(nil, 1)` and crashed the poll. No outcomes at all (no
  # symbols asked for) lands on `{nil, nil, false}` below and is `{:ok, []}`.
  defp no_events(outcomes) do
    error = Enum.find(outcomes, &match?({:error, _reason}, &1))
    refused = Enum.find(outcomes, &match?({:refused, _reason}, &1))
    skipped? = Enum.any?(outcomes, &match?({:skipped, _symbols}, &1))

    case {error, refused, skipped?} do
      {{:error, reason}, _refused, _skipped} -> {:error, reason}
      {nil, {:refused, reason}, _skipped} -> {:error, reason}
      {nil, nil, true} -> {:error, :bisect_budget_exhausted}
      {nil, nil, false} -> {:ok, []}
    end
  end

  # **Symbols the cycle's budget left unrequested are reported, not swallowed.** A cycle that
  # delivered some chunks used to hide the ones it ran out of budget for: an `{:error, _}` is
  # dropped whenever any other outcome carried events. Each cycle tells this feed how many
  # symbols it skipped (0 when none) and the feed latches it: one `:degraded` notice on the
  # first cycle that skips, one on the first that does not after. Coverage needs nothing
  # here: it is windowed, so a symbol that got no fresh book stops being reported covered.
  defp report_budget(parent, outcomes) do
    skipped = Enum.sum(for {:skipped, symbols} <- outcomes, do: length(symbols))

    send(parent, {:poll_budget, skipped})
  end

  # One bulk request for `symbols`; on a refusal, split in half and ask again, down to
  # single symbols — see the moduledoc's "A refused batch is bisected, and a refused symbol
  # is remembered". Returns a list of `{:events, _}`, `{:error, _}` and `{:refused, _}`.
  #
  # **Every request after the cycle's first is capped to the budget that is left.** Core's
  # `:timeout` bounds the limiter wait as well as the HTTP request, so a limiter wait inside
  # a bisection can no longer carry the cycle past its deadline into `PollingFeed`'s fetch
  # kill, which would lose the findings so far. A request that cannot start inside the
  # budget ends as `{:error, _}` (silence, retried next cycle), and once the budget is spent
  # no further request is sent.
  defp resolve(symbols, ctx, capped?), do: resolve(symbols, ctx, capped?, 0)

  defp resolve([], _ctx, _capped?, _cycle), do: []

  # More symbols than `Rest.max_bulk_symbols/0` go out as several requests of at most that
  # many, so the signed URL stays bounded at any universe size. Only the cycle's first
  # request may run uncapped. A rejected key (401/403) ends the cycle's requests, as it does
  # a bisection: every chunk would be refused alike. Halves made by bisection are already
  # within one chunk, so a refusal is still located inside its own chunk.
  #
  # **Which chunk goes first rotates with the cycle** (`plan_chunks/2`), so a universe too
  # slow for the budget starves a different chunk each cycle, not always the tail.
  defp resolve(symbols, ctx, capped?, cycle) do
    symbols
    |> plan_chunks(cycle)
    |> Enum.with_index()
    |> Enum.reduce_while([], fn {chunk, index}, acc ->
      outcomes = resolve_chunk(chunk, ctx, capped? or index > 0)
      # Prepended and flattened once at the end: `acc ++ outcomes` copied the whole
      # accumulator for every chunk of a large universe.
      acc = [outcomes | acc]
      if auth_failure?(outcomes), do: {:halt, acc}, else: {:cont, acc}
    end)
    |> Enum.reverse()
    |> Enum.concat()
  end

  # One chunk (the common case, and every bisected half) is left in the caller's order. More
  # than one are made from a sorted list, so the same set chunks the same way each cycle, and
  # are rotated left by `cycle` chunks: cycle 0 starts at chunk 0, cycle 1 at chunk 1, and so
  # on round again.
  defp plan_chunks(symbols, cycle) do
    cap = Rest.max_bulk_symbols()

    if length(symbols) <= cap do
      [symbols]
    else
      chunks = symbols |> Enum.sort() |> Enum.chunk_every(cap)
      {head, tail} = Enum.split(chunks, rem(cycle, length(chunks)))
      tail ++ head
    end
  end

  defp resolve_chunk(symbols, ctx, capped?) do
    remaining = ctx.deadline - System.monotonic_time(:millisecond)

    if capped? and remaining <= 0 do
      [{:skipped, symbols}]
    else
      request_opts =
        if capped?, do: cap_timeout(ctx.request_opts, remaining), else: ctx.request_opts

      case Rest.get_top_of_book_bulk(symbols, ctx.credentials, request_opts) do
        {:ok, events} -> [{:events, events}]
        {:error, reason} -> [{:error, reason}]
        {:refused, reason} -> refused(symbols, reason, ctx)
      end
    end
  end

  defp cap_timeout(request_opts, remaining) do
    Keyword.update(request_opts, :timeout, remaining, fn
      current when is_integer(current) and current > 0 -> min(current, remaining)
      _unset -> remaining
    end)
  end

  # 401 is the request being unauthenticated and 403 the key lacking permission. Every
  # symbol would be refused the same way, so splitting identifies nothing, spends about 2N
  # requests, and marks each symbol it reaches as individually refused when none is at fault.
  defp refused(_symbols, {:venue_error, status} = reason, _ctx) when status in [401, 403],
    do: [{:error, reason}]

  defp refused(_symbols, {:venue_error, status, _detail} = reason, _ctx)
       when status in [401, 403],
       do: [{:error, reason}]

  defp refused([symbol], reason, ctx) do
    ctx.on_refusal.(symbol, reason)
    [{:refused, reason}]
  end

  defp refused(symbols, reason, ctx) do
    if System.monotonic_time(:millisecond) >= ctx.deadline do
      # Out of budget. Left unresolved, as silence retried next cycle, not reported as
      # refused, because nothing here established which of these the venue objected to.
      [{:error, reason}, {:skipped, symbols}]
    else
      {left, right} = Enum.split(symbols, div(length(symbols), 2))
      left_outcomes = resolve(left, ctx, true)

      # A key the venue rejected on the left half is rejected for the right half too.
      if auth_failure?(left_outcomes),
        do: left_outcomes,
        else: left_outcomes ++ resolve(right, ctx, true)
    end
  end

  # The set `Feed` holds of symbols the venue has refused and that have not delivered since,
  # and this cycle's number (which starts the chunk rotation; each call is the next cycle).
  # Read at the start of each cycle. A feed that does not answer is treated as holding no
  # refused symbols and as cycle 0: every symbol goes into the bulk request, as before.
  defp cycle_plan(parent) do
    GenServer.call(parent, :cycle_plan, 5_000)
  catch
    :exit, _reason -> {MapSet.new(), 0}
  end

  @impl true
  def handle_call(:cycle_plan, _from, state),
    do: {:reply, {state.refused, state.cycle}, %{state | cycle: state.cycle + 1}}

  def handle_call(:coverage, _from, state) do
    {coverage, state} = poller_coverage(state)
    {:reply, coverage, state}
  end

  def handle_call({:update_symbols, symbols}, _from, state),
    do: change_symbols(%{state | added: MapSet.new()}, symbols, & &1)

  def handle_call({:add_symbols, symbols, subscriber}, _from, state) do
    with {:ok, checked} <- canonical_symbols(symbols),
         {:ok, registered} <- register_data_subscriber(state, subscriber) do
      replace_symbols(
        track_added(registered, subscriber, checked),
        Enum.uniq(state.symbols ++ checked)
      )
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:remove_symbols, symbols}, _from, state),
    do: change_symbols(state, symbols, fn drop -> without(state.symbols, drop) end)

  def handle_call(:wanted, _from, state), do: {:reply, state.symbols, state}

  def handle_call({:subscribe_notices, subscriber}, _from, state) do
    case valid_subscriber(subscriber) do
      {:ok, subscriber} ->
        state = %{
          state
          | notice_subscribers: MapSet.put(state.notice_subscribers, subscriber),
            monitors: Fanout.watch(subscriber, state.monitors)
        }

        {:reply, :ok, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :unknown_call}, state}

  # This feed defines no casts. `use GenServer`'s default `handle_cast/2` raises on one, so a
  # stray `GenServer.cast(Feed, _)` from any process crashed the feed and, with it, every
  # `update_symbols/2` and `subscribe_notices/1` made since boot (the restart is from the
  # static opts). Ignored, as `handle_info/2` ignores a message it does not know.
  @impl true
  def handle_cast(_other, state), do: {:noreply, state}

  # The caller's list is checked and upper-cased first (`boot_symbols/1`), then `build` makes
  # the new set from it. A bad list leaves the set as it was.
  defp change_symbols(state, symbols, build) do
    case canonical_symbols(symbols) do
      {:ok, checked} -> replace_symbols(state, build.(checked))
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp without(symbols, drop) do
    dropped = MapSet.new(drop)
    Enum.reject(symbols, &MapSet.member?(dropped, &1))
  end

  # No subscriber given: nothing to register. The boot `:subscriber` already receives, and
  # registering it again would only put the one configuration pid under a monitor.
  defp register_data_subscriber(state, nil), do: {:ok, state}

  defp register_data_subscriber(%{subscriber: subscriber} = state, subscriber), do: {:ok, state}

  defp register_data_subscriber(state, subscriber) do
    with {:ok, subscriber} <- valid_subscriber(subscriber) do
      {:ok,
       %{
         state
         | data_subscribers: MapSet.put(state.data_subscribers, subscriber),
           monitors: Fanout.watch(subscriber, state.monitors)
       }}
    end
  end

  # Only symbols asked for on behalf of a registered (non-boot) data subscriber are released
  # when the last of them dies; the boot `:subscriber` is configuration and never dies out.
  defp track_added(state, nil, _symbols), do: state

  defp track_added(%{subscriber: subscriber} = state, subscriber, _symbols), do: state

  defp track_added(state, _registered, symbols),
    do: %{state | added: MapSet.union(state.added, MapSet.new(symbols))}

  # The last registered data subscriber died and there is no boot subscriber: what was added
  # for them is released, so the poller stops requesting books nobody can receive.
  defp release_orphaned(%{subscriber: nil, data_subscribers: registered} = state) do
    if MapSet.size(registered) == 0 and MapSet.size(state.added) > 0 do
      released = Enum.reject(state.symbols, &MapSet.member?(state.added, &1))
      # `released` holds none of `added`, so the intersection in `replace_symbols/2` empties it.
      {:reply, _result, state} = replace_symbols(state, released)
      state
    else
      state
    end
  end

  defp release_orphaned(state), do: state

  defp replace_symbols(state, symbols) do
    symbol_set = MapSet.new(symbols)

    state = %{
      state
      | symbols: symbols,
        symbol_set: symbol_set,
        added: MapSet.intersection(state.added, symbol_set),
        refused: MapSet.intersection(state.refused, symbol_set)
    }

    # `PollingFeed.update_symbols/2` is a cast: it cannot exit when the poller has just died
    # (a cast to a dead pid is dropped), and nothing is lost by that, because the restart
    # triggered by the pending `EXIT` is built from `state.symbols`, set above.
    result = PollingFeed.update_symbols(state.poller, symbols)
    {:reply, result, close_idle_link(state)}
  end

  # **An outage with nothing to deliver is over.** `link_down` is closed by the first good
  # poll, but `PollingFeed` does not poll an empty set at all, so a poller that crashed (or a
  # read that went unanswered) while no symbol was wanted left the `:link_down` open until some
  # symbol was added: a consumer waiting for a recovery that had nothing to wait for. With no
  # symbols a live, idle poller is the recovery, and is announced once.
  defp close_idle_link(%{link_down: true, symbols: []} = state) do
    notice =
      Notice.new(:link_up, :robinhood,
        severity: :info,
        message: "poll is idle: no symbols are wanted, so there is nothing to deliver",
        details: %{reason: :poll_idle, symbols: []}
      )

    fan_out(state.notice_subscribers, {:dp_exchange, :robinhood, notice})
    %{state | link_down: false}
  end

  defp close_idle_link(state), do: state

  # A notice subscriber that died. Dropped, and its monitor forgotten.
  #
  # Without this, nothing ever removed one: `Core.Fanout.resolve/1` skips a dead subscriber
  # at send time, so no NOTICES accumulated for it — but the pid stayed for the life of this
  # feed, and every notice walked it. Measured in Core 0.3.3 on the streaming venues, where
  # the same set is on the data path: 0.095 us per fan-out against a clean set, 22.8 us
  # against one carrying a thousand dead pids.
  #
  # `state.subscriber` is untouched here on purpose — see `init/1`. It is configuration
  # rather than a subscription, and removing it would leave a feed nothing could repair.
  # Only pids arrive here; a registered-name subscriber is never monitored, because a name
  # outlives the process holding it (`Core.Fanout.watch/2`).
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{
      state
      | notice_subscribers: MapSet.delete(state.notice_subscribers, pid),
        data_subscribers: MapSet.delete(state.data_subscribers, pid),
        dropping: MapSet.delete(state.dropping, pid),
        monitors: Fanout.forget(pid, state.monitors)
    }

    {:noreply, release_orphaned(state)}
  end

  # A cycle's count of symbols its budget left unrequested. The notice goes out on the
  # crossing into exhaustion and on the crossing out, never once per cycle.
  def handle_info({:poll_budget, skipped}, %{budget_exhausted: false} = state)
      when is_integer(skipped) and skipped > 0 do
    notice =
      Notice.new(:degraded, :robinhood,
        severity: :warning,
        message:
          "#{skipped} symbols were not requested this poll cycle: its request budget " <>
            "(bisect_budget_ms) ran out. They are requested in later cycles, the chunk " <>
            "that goes first rotating each cycle; until then they are not in coverage/1",
        details: %{skipped: skipped, bisect_budget_ms: state.bisect_budget_ms}
      )

    fan_out(state.notice_subscribers, {:dp_exchange, :robinhood, notice})
    {:noreply, %{state | budget_exhausted: true}}
  end

  def handle_info({:poll_budget, 0}, %{budget_exhausted: true} = state) do
    notice =
      Notice.new(:degraded, :robinhood,
        severity: :info,
        message: "poll cycle budget is sufficient again: every symbol was requested",
        details: %{skipped: 0, bisect_budget_ms: state.bisect_budget_ms}
      )

    fan_out(state.notice_subscribers, {:dp_exchange, :robinhood, notice})
    {:noreply, %{state | budget_exhausted: false}}
  end

  def handle_info({:poll_budget, _skipped}, state), do: {:noreply, state}

  # One poll cycle's outcome, from `fetch_all/6`.
  #
  # `:ok` is a cycle that delivered at least one book and was not refused for credentials:
  # it closes an open `:link_down` with ONE `:link_up` (latched; `Core.Notice` describes the
  # two as a pair, and a consumer waiting for recovery otherwise waits forever) and clears
  # the `:credentials_rejected` latch. `:credentials_rejected` is a 401/403 on the poll: one
  # notice per rejection streak, not one per cycle. Coverage is unaffected either way.
  def handle_info({:poll_result, :ok}, state) do
    if state.link_down do
      notice =
        Notice.new(:link_up, :robinhood,
          severity: :info,
          message: "poll is answering again",
          details: %{reason: :poll_recovered, symbols: Enum.sort(state.symbols)}
        )

      fan_out(state.notice_subscribers, {:dp_exchange, :robinhood, notice})
    end

    {:noreply, %{state | link_down: false, credentials_rejected: false}}
  end

  def handle_info({:poll_result, :credentials_rejected}, state)
      when state.credentials_rejected == false do
    notice =
      Notice.new(:credentials_rejected, :robinhood,
        message: "the venue rejected this feed's credentials (HTTP 401/403) on a poll",
        details: %{reason: :poll_rejected, symbols: Enum.sort(state.symbols)}
      )

    fan_out(state.notice_subscribers, {:dp_exchange, :robinhood, notice})
    {:noreply, %{state | credentials_rejected: true}}
  end

  def handle_info({:poll_result, _other}, state), do: {:noreply, state}

  def handle_info({:dp_exchange, :robinhood, %Notice{}} = message, state) do
    fan_out(state.notice_subscribers, message)
    {:noreply, state}
  end

  # **A symbol no longer in `state.symbols` delivers nothing.** A poll already in flight when
  # `update_symbols/2` removed it still answered, and its book reached the subscriber after
  # the unsubscribe returned. A late refusal put the removed symbol back into `refused`,
  # where nothing would ever take it out. Found 2026-10-10.
  def handle_info({:dp_exchange, :robinhood, {:refused, symbol, _reason}} = message, state) do
    if MapSet.member?(state.symbol_set, symbol),
      do: {:noreply, deliver(%{state | refused: MapSet.put(state.refused, symbol)}, message)},
      else: {:noreply, state}
  end

  def handle_info({:dp_exchange, :robinhood, %{symbol: symbol}} = message, state) do
    if MapSet.member?(state.symbol_set, symbol),
      do: {:noreply, deliver(%{state | refused: MapSet.delete(state.refused, symbol)}, message)},
      else: {:noreply, state}
  end

  # There is no clause for "any other payload". The three producers (the poller's sink, which
  # only ever hands over a `TopOfBook`; `on_refusal`; `on_notice`) are all matched above, so a
  # forwarding clause here was reachable only by a foreign process sending a malformed
  # message, and would have handed that to every subscriber. It falls to the catch-all below
  # and is ignored.

  # The other half of `init/1`'s `Process.flag(:trap_exit, true)` — see the moduledoc's
  # "A crashed poller used to be Feed's crash too" section. Matching on `state.poller` is
  # what tells a real crash apart from an `EXIT` this feed cannot attribute to anything
  # it started; a stale `EXIT` for an already-replaced poller falls through to the
  # catch-all below and is correctly ignored.
  def handle_info({:EXIT, pid, reason}, %{poller: pid} = state) do
    notify_poller_crashed(state, reason)
    state = %{state | link_down: true}
    now = System.monotonic_time(:millisecond)
    crashes = [now | Enum.filter(state.poller_crashes, &(&1 > now - @poller_crash_window_ms))]

    # Restarted straight away, a poller that dies on every start looped here forever, one
    # `:link_down` per turn, and no supervisor's intensity bounded it because `Feed` itself
    # never died. Past the limit the crash is handed to the supervisor, whose intensity is
    # the bound OTP already provides.
    if length(crashes) > @max_poller_restarts do
      {:stop, {:poller_crash_loop, reason}, state}
    else
      restart_poller(state, crashes)
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # **The poller does not outlive this feed.** It is linked, and a link carries only an
  # abnormal exit: stopped with `:normal` (`GenServer.stop/1`, a supervisor's `:normal`
  # restart request in a test) this feed left its poller running, polling the venue on a
  # timer for a feed nobody could reach. `Process.exit/2` with `:shutdown` ends it whatever
  # the reason this feed stopped for; a dead pid makes it a no-op.
  @impl true
  def terminate(_reason, %{poller: poller}) when is_pid(poller) do
    Process.exit(poller, :shutdown)
    :ok
  end

  # No fallback clause: `terminate/2` only runs for a feed whose `init/1` succeeded, and that
  # always left `state.poller` a pid (`init_feed/2` stops before returning a state otherwise;
  # a failed restart stops with the previous, still-pid, state).

  defp restart_poller(state, crashes) do
    case start_poller(state) do
      {:ok, new_poller} ->
        {:noreply, close_idle_link(%{state | poller: new_poller, poller_crashes: crashes})}

      # As unreachable in practice as `init/1`'s own `{:error, other}` branch — `fetch`
      # is always supplied — but this feed has no lesser fallback the way a socket-based
      # venue's `ensure_route/1` falls back to a poll: a poll IS this venue's only
      # route. Stopping hands the failure to `DpExchange.Robinhood.Supervisor`, the same
      # outcome `init/1` reaches for the identical error.
      {:error, other} ->
        {:stop, other, state}
    end
  end

  # `coverage/1` is a READ, and a read must never be able to kill the thing it reads.
  #
  # dp-exchange-core issue #28. This was a bare `PollingFeed.coverage(state.poller)` — a
  # `GenServer.call/2` carrying the default five-second timeout, into a process that (before
  # the matching fix in `Core.PollingFeed`) blocked for the whole of its `:fetch_timeout_ms`
  # while a fetch was in flight. That floor is 30 seconds against a 5-second call, so a
  # coverage call landing during an ordinary poll was not unlucky, it was a guaranteed
  # timeout: the exit propagated out of this `handle_call/3` and killed `Feed`. It restarted
  # from the STATIC opts the supervisor holds, which never carry a consumer's later
  # `subscribe/3` calls, so coverage went 61 pairs to 0 and stayed there — with the process
  # alive, idle and passing every liveness probe. Asking whether the venue was healthy is
  # what made it unhealthy.
  #
  # `Core.PollingFeed` no longer blocks on its fetch, which removes that cause. This catch
  # stays regardless, and it is not belt-and-braces: a poller that is mid-restart, wedged by
  # something else, or simply gone is a condition this `Feed` has to survive, and no fix
  # inside `PollingFeed` can promise it is always answerable.
  #
  # `%{}` is the honest fallback and the contract permits no other — `c:DpExchange.Core.
  # Venue.coverage/1` returns a map, so `{:error, :busy}` is not sayable here, and an absent
  # symbol already means `:not_covered`. Replying with a REMEMBERED coverage instead would
  # assert arrivals nobody confirmed, which is the "nearby substitute where an error belongs"
  # failure this family keeps paying for. The notice carries what `%{}` cannot: **"we could
  # not ask" is not "nothing arrived"**, and only the notice tells a consumer which one it
  # is looking at.
  #
  # Returns `{coverage, state}`: the state carries the `:link_down` latch that the next good
  # poll closes with a `:link_up` (see `handle_info({:poll_result, _}, _)`).
  defp poller_coverage(state) do
    {PollingFeed.coverage(state.poller), state}
  catch
    :exit, reason ->
      # **One `:link_down` per outage, not one per read.** A health check reads coverage every
      # few seconds; against a wedged poller each read re-sent the notice to every subscriber,
      # while the one `:link_up` that closes it is latched. An outage already open (from a
      # crash, or an earlier unanswered read) is not announced again.
      unless state.link_down, do: notify_poller_unresponsive(state, reason)
      {%{}, %{state | link_down: true}}
  end

  # The counterpart to `notify_poller_crashed/2`: that one reports a poller that died, this
  # one a poller that is alive and did not answer. Both would otherwise be the same silent
  # gap in `coverage/1` with nothing explaining it.
  defp notify_poller_unresponsive(state, reason) do
    notice =
      Notice.new(:link_down, :robinhood,
        severity: :warning,
        message:
          "poll did not answer a coverage read (#{inspect(reason)}) — reporting no " <>
            "coverage for this read only; the feed is still running",
        details: %{reason: :poll_unresponsive}
      )

    fan_out(state.notice_subscribers, {:dp_exchange, :robinhood, notice})
  end

  # Reports a crashed poller the same way a socket-based venue reports a crashed shard
  # or connection — without this, it is exactly the "silent half-dead feed" this
  # family's incidents are about: `Feed` recovers on its own, but a consumer watching
  # only `coverage/1` would see a gap with no notice explaining it.
  defp notify_poller_crashed(state, reason) do
    notice =
      Notice.new(:link_down, :robinhood,
        severity: :warning,
        message: "poll crashed (#{inspect(reason)}) — restarting now",
        details: %{reason: :poll_crashed}
      )

    fan_out(state.notice_subscribers, {:dp_exchange, :robinhood, notice})
  end

  # The venue's data stream, bounded — see `Core.Fanout`. Only a subscriber under its
  # mailbox bound is sent to; one past it is skipped and reported once, in a `:degraded`
  # notice, and reported again when it catches up.
  #
  # Notices keep going through `fan_out/2` unbounded, and must: the notice saying a
  # subscriber is being dropped cannot be the first casualty of that same subscriber being
  # dropped.
  defp deliver(state, message) do
    {_sent, dropping, transitions} =
      Fanout.deliver(data_recipients(state), message, state.dropping,
        max_queue_len: state.max_queue_len
      )

    Enum.each(transitions, fn transition ->
      fan_out(
        state.notice_subscribers,
        {:dp_exchange, :robinhood, Fanout.notice_for(transition, :robinhood, state.max_queue_len)}
      )
    end)

    %{state | dropping: dropping}
  end

  # The boot `:subscriber` (when there is one) and every registered data subscriber. A
  # subscriber in both is sent to once.
  defp data_recipients(%{subscriber: nil, data_subscribers: registered}),
    do: MapSet.to_list(registered)

  defp data_recipients(%{subscriber: subscriber, data_subscribers: registered}),
    do: [subscriber | MapSet.to_list(MapSet.delete(registered, subscriber))]

  # The UNBOUNDED path — notices only. See `deliver/2` above for why the data stream does
  # not come through here and why notices deliberately still do.
  #
  # A dead subscriber stops delivery rather than crashing it. A subscriber may be a raw
  # pid or a registered name — `subscribe_notices/2`'s `to:` accepts either, matching
  # ordinary OTP practice — and `send/2` to an unregistered atom RAISES, which would take
  # this whole process down on every notice rather than merely skipping one recipient.
  # Same defect, same fix, as `dp_exchange_schwab` and `dp_exchange_coinbase`'s own
  # `Feed.fan_out/2` (DpCryptoManagement issue #15): resolve first, uniformly, then send
  # only to what resolved to a live pid.
  defp fan_out(subscribers, message) do
    Enum.each(subscribers, fn subscriber ->
      case Fanout.resolve(subscriber) do
        pid when is_pid(pid) -> send(pid, message)
        nil -> :ok
      end
    end)
  end
end
