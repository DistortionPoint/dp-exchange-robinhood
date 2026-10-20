defmodule DpExchange.Robinhood.Ledger do
  @moduledoc """
  What a tree's feed was asked to do, kept outside the feed so a restarted feed can resume it.
  Internal.

  ## The defect this closes

  `DpExchange.Robinhood.Supervisor` restarts a crashed `Feed` from the options the tree was
  started with. Everything asked of the feed afterwards (`subscribe/2`, `update_symbols/2`,
  `unsubscribe/2`, `subscribe_notices/1`, and every pid that registered for them) lived only
  in the crashed process. The restarted feed polled the boot symbols for the boot subscriber
  and told nobody: a consumer saw coverage fall and never learned why or that its own
  registration was gone.

  ## What is kept, and what is not

  The ledger holds the feed's **durable intent**: the wanted symbols, the symbols added on
  behalf of registered subscribers, and the data and notice subscribers (pids or registered
  names). It is written with a full snapshot (`record/2`) after every change the feed
  **accepted**; a refused call changes nothing and writes nothing.

  It holds **no credentials**: those stay in the tree's start arguments, already wrapped by
  `DpExchange.Robinhood.Credentials`. It holds no observed state either (what was refused,
  what is covered): that is re-learned by polling.

  ## Where it sits

  Started by the supervisor before the limiter and the feed, under `:rest_for_one`: a crashed
  feed restarts alone and reads the ledger back in `handle_continue/2`, so a slow read never
  blocks the supervisor; a crashed limiter restarts the feed too (which resumes from the
  ledger); a crashed ledger restarts everything after it, and the feed then starts from the
  tree's options exactly as it did before this process existed. A feed started on its own,
  without `:ledger`, keeps nothing.
  """

  use GenServer

  @typedoc "The feed's durable intent."
  @type intent :: %{
          symbols: [String.t()],
          added: [String.t()],
          data_subscribers: [pid() | atom()],
          notice_subscribers: [pid() | atom()]
        }

  @doc "Starts the ledger, registered as `opts[:name]`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, nil, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Replaces the stored intent with `intent`. A cast: the feed never waits on it, and a ledger
  that is not running (or a `nil` name, a feed started on its own) drops it.
  """
  @spec record(GenServer.server() | nil, intent()) :: :ok
  def record(nil, _intent), do: :ok
  def record(ledger, intent), do: GenServer.cast(ledger, {:record, intent})

  @doc """
  The stored intent, `{:ok, intent}`, or `:none` when nothing was recorded, the ledger is not
  running or it did not answer. A restarted feed that gets `:none` carries on from its options.
  """
  @spec fetch(GenServer.server() | nil) :: {:ok, intent()} | :none
  def fetch(nil), do: :none

  def fetch(ledger) do
    GenServer.call(ledger, :fetch, 5_000)
  catch
    :exit, _reason -> :none
  end

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call(:fetch, _from, nil), do: {:reply, :none, nil}
  def handle_call(:fetch, _from, intent), do: {:reply, {:ok, intent}, intent}

  @impl true
  def handle_cast({:record, intent}, _previous), do: {:noreply, intent}
  def handle_cast(_other, intent), do: {:noreply, intent}
end
