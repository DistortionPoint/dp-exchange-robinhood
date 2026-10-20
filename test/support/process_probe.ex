defmodule DpExchange.Robinhood.Test.ProcessProbe do
  @moduledoc false
  # The seam for Core conformance group 51: starts this venue's whole tree with the canary
  # credentials and NO network, and hands back every long-lived process that may hold them, so
  # the group can render each with `:sys.get_status/2`.
  #
  # No poll fires: the feed's first poll is 10 minutes away and `symbols` is non-empty so the
  # poller (and its fetch closure, which captures the credentials) really exists.

  alias DpExchange.Robinhood.Supervisor, as: RobinhoodSupervisor

  @doc """
  Starts the tree under a unique name and answers `{:ok, pids}`: the supervisor, the ledger,
  the limiter, the feed and the feed's poller. The caller stops them.
  """
  @spec start(map()) :: {:ok, [pid()]} | {:error, term()}
  def start(credentials) do
    name = :"rh_probe_#{System.unique_integer([:positive])}"

    opts = [
      name: name,
      credentials: credentials,
      symbols: ["BTC-USD"],
      start_delay_ms: 600_000,
      interval_ms: 600_000
    ]

    with {:ok, sup} <- RobinhoodSupervisor.start_link(opts) do
      feed = Process.whereis(RobinhoodSupervisor.feed_name(name: name))
      poller = :sys.get_state(feed).poller
      ledger = Process.whereis(RobinhoodSupervisor.ledger_name(name: name))
      limiter = Process.whereis(RobinhoodSupervisor.limiter_name(name: name))

      {:ok, [sup, ledger, limiter, feed, poller]}
    end
  end
end
