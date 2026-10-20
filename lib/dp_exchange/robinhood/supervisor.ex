defmodule DpExchange.Robinhood.Supervisor do
  @moduledoc """
  This venue's process tree — internal.

  A limiter and a feed, exactly as every other venue in the family, even though the feed
  behind them is a poll rather than a socket. That sameness is the point: a consumer's
  supervision tree looks identical whichever venue it holds.

  ## The limiter here has an incident behind it

  Configured from the ceilings `capabilities/0` declares, like every venue. What is
  specific to this one is that its feed calls `acquire/3` rather than `check/3` — when
  limiting was first enabled, `check/3` took this venue from 87 of 87 symbols delivering to
  8 of 87 in one cycle, because a poll that finds no capacity simply skips the symbol.
  """

  use Supervisor

  alias DpExchange.Core.{Config, DefaultRateLimiter}
  alias DpExchange.Robinhood.{Credentials, Feed, Ledger}

  @doc """
  The child spec for supervising this tree directly, with `opts[:credentials]` wrapped.

  `use Supervisor` generates a `child_spec/1` that stores the raw options as the start
  argument, and OTP prints that argument (`Start Call:`) in the report it logs whenever the
  child terminates. A consumer supervising this module directly, rather than through
  `DpExchange.Robinhood`, would have put the raw api key and private key into their logs.
  Wrapped here, before the supervisor captures the MFA, exactly as the facade and `Feed` do.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts = Credentials.wrap_opt(opts)

    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Starts this venue's tree: its ledger, its rate limiter, then its feed (`rest_for_one`, so a
  crashed feed restarts alone, resuming its wanted symbols and subscribers from the ledger).
  Registered as `opts[:name]`, default
  `DpExchange.Robinhood.Supervisor`; the remaining `opts` go to `DpExchange.Robinhood.Feed`,
  whose name is `opts[:feed]` and whose limiter is `opts[:limiter]`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    # An OTP supervisor keeps its init argument in its own state, which a crash report of
    # the supervisor prints. `child_spec/1` wraps `:credentials` already; wrapping again here
    # (idempotent) covers a consumer who calls `start_link/1` directly with a raw map.
    opts = Credentials.wrap_opt(opts)

    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    # The feed is handed the limiter by name: its own `:name` is the feed's, and a limiter name
    # derived from that would not be the one started below.
    feed_opts =
      opts
      |> Keyword.put(:name, feed_name(opts))
      |> Keyword.put(:limiter, limiter_name(opts))
      |> Keyword.put(:ledger, ledger_name(opts))

    # `:rest_for_one`, ledger first: a crashed feed restarts alone and resumes what it was
    # asked to do from the ledger (see `Ledger`); a crashed limiter restarts the feed behind
    # it, which resumes the same way.
    children = [
      {Ledger, name: ledger_name(opts)},
      {DefaultRateLimiter, name: limiter_name(opts), limits: limits()},
      {Feed, feed_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  This tree's ledger: `opts[:ledger]`, else one derived from the tree's `opts[:name]`
  (`<name>.Ledger`), else `DpExchange.Robinhood.Ledger` for the default tree.
  """
  @spec ledger_name(keyword()) :: atom()
  def ledger_name(opts), do: Config.opt(opts, :ledger, derived_name(opts, "Ledger", Ledger))

  @doc """
  The limiter this venue meters against: `opts[:limiter]`, else one derived from the tree's
  `opts[:name]` (`<name>.RateLimiter`), else `DpExchange.Robinhood.RateLimiter` for the default
  tree. A second tree started with only a distinct `name:` therefore owns its own limiter.
  """
  @spec limiter_name(keyword()) :: atom()
  def limiter_name(opts) do
    Config.opt(opts, :limiter, derived_name(opts, "RateLimiter", default_limiter()))
  end

  defp default_limiter, do: DpExchange.Robinhood.RateLimiter

  @doc """
  This venue's feed process: `opts[:feed]`, else one derived from the tree's `opts[:name]`
  (`<name>.Feed`), else `DpExchange.Robinhood.Feed` for the default tree.
  """
  @spec feed_name(keyword()) :: atom()
  def feed_name(opts), do: Config.opt(opts, :feed, derived_name(opts, "Feed", Feed))

  # The default tree name (or none, or one that is not an atom and so cannot be extended) keeps
  # the fixed default, so a consumer running one tree is unaffected.
  defp derived_name(opts, suffix, default) do
    case Config.opt(opts, :name, __MODULE__) do
      name when is_atom(name) and name != __MODULE__ -> Module.concat(name, suffix)
      _default_or_unnameable -> default
    end
  end

  defp limits do
    caps = DpExchange.Robinhood.capabilities()

    %{robinhood: to_limit(caps.public_ceiling), default: to_limit(caps.public_ceiling)}
  end

  # The vendor documents a burst depth (300, against a sustained 100 a minute), and
  # `capabilities/0` carries it as `:burst`, so that is what the limiter is given. Only a
  # ceiling that states none falls back to the per-interval limit, the conventional GCRA
  # choice, which is ours rather than the venue's. The figures are the vendor's documented
  # ones, never probed (see `measured_against`).
  defp to_limit(%{limit: limit, per_ms: per_ms} = ceiling),
    do: %{limit: limit, per_ms: per_ms, burst: Map.get(ceiling, :burst, limit)}
end
