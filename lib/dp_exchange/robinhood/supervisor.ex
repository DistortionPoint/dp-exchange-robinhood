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

  alias DpExchange.Core.DefaultRateLimiter
  alias DpExchange.Robinhood.Feed

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    children = [
      {DefaultRateLimiter, name: limiter_name(opts), limits: limits()},
      {Feed, Keyword.put(opts, :name, feed_name(opts))}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "The limiter this venue meters against."
  @spec limiter_name(keyword()) :: atom()
  def limiter_name(opts), do: Keyword.get(opts, :limiter, DpExchange.Robinhood.RateLimiter)

  @doc "This venue's feed process."
  @spec feed_name(keyword()) :: atom()
  def feed_name(opts), do: Keyword.get(opts, :feed, Feed)

  defp limits do
    caps = DpExchange.Robinhood.capabilities()

    %{robinhood: to_limit(caps.public_ceiling), default: to_limit(caps.public_ceiling)}
  end

  # No published burst depth on this venue, so the per-interval limit is used — the
  # conventional GCRA choice, and labelled as ours rather than the venue's.
  defp to_limit(%{limit: limit, per_ms: per_ms} = ceiling),
    do: %{limit: limit, per_ms: per_ms, burst: Map.get(ceiling, :burst, limit)}
end
