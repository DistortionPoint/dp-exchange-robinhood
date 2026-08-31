defmodule DpExchange.Robinhood.Fake do
  @moduledoc """
  An in-process Robinhood, for a consumer's tier-1 tests and for the conformance suite.

  **It is not a mock.** A real implementation of `DpExchange.Core.Venue` answering from
  memory, running the *same* conformance suite as the real adapter.

  ## What it models that is specific to this venue

  - **Credentials are required for market data**, because the real venue signs every call
    and has no anonymous endpoint. Without them: `{:refused, :missing_credentials}`.
  - **Coverage is `:internal_poll`, not `:stream`** — the one place a consumer can see that
    this venue has no socket, and it shows up as *what is arriving*, never as *how*.
  - **No candles, no order book, no volume.** The venue serves none, so neither does this.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.{Types, Venue}

  @symbols ~w(BTC-USD ETH-USD DOGE-USD)

  @price %{"BTC-USD" => "77845.79", "ETH-USD" => "2951.40", "DOGE-USD" => "0.1234"}

  # Fixed, not `utc_now/0`: a fake that stamps the current clock cannot be used to test
  # anything about freshness, and is itself the substitution this family refuses.
  @at ~U[2026-08-28 12:00:00Z]

  @impl true
  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def start_link(_opts), do: :ignore

  @impl true
  def provider_name, do: DpExchange.Robinhood.provider_name()
  @impl true
  def runtime_id, do: DpExchange.Robinhood.runtime_id()
  @impl true
  def asset_classes, do: DpExchange.Robinhood.asset_classes()
  @impl true
  def capabilities, do: DpExchange.Robinhood.capabilities()

  @impl true
  def get_price(symbol, opts \\ []) do
    with :ok <- authenticated(opts) do
      case Map.fetch(@price, symbol) do
        {:ok, price} ->
          ask = price |> Decimal.new() |> Decimal.add(Decimal.new("0.01"))

          {:ok,
           %Types.Quote{
             symbol: symbol,
             # The ask, as the real adapter uses when the venue sends no separate price.
             price: ask,
             bid: Decimal.new(price),
             ask: ask,
             volume: nil,
             timestamp: @at,
             provider: :robinhood
           }}

        :error ->
          {:refused, :not_listed}
      end
    end
  end

  @impl true
  def get_symbols(opts \\ []) do
    with :ok <- authenticated(opts), do: {:ok, @symbols}
  end

  @impl true
  def get_historical_prices(_symbol, _timeframe, _range, _opts), do: Venue.not_supported()
  @impl true
  def get_order_book(_symbol, _opts), do: Venue.not_supported()
  @impl true
  def get_market_overview(_opts), do: Venue.not_supported()
  @impl true
  def list_instruments(_opts), do: Venue.not_supported()
  @impl true
  def get_balances(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_accounts(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_fees(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_transfers(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def place_order(_credentials, _request, _opts), do: Venue.not_supported()
  # Both refused, matching the real venue. A fake that answered where the real one
  # refuses lets a consumer's suite go green against behaviour that cannot happen.
  @impl true
  def preview_order(_credentials, _request, _opts \\ []), do: Venue.not_supported()

  @impl true
  def replace_order(_credentials, _id, _request, _opts \\ []), do: Venue.not_supported()

  @impl true
  def cancel_order(_credentials, _id, _opts), do: Venue.not_supported()
  @impl true
  def get_order(_credentials, _id, _opts), do: Venue.not_supported()
  @impl true
  def get_orders(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_trade_history(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def test_connection(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_rate_limit_status(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def quantization(_symbol), do: Venue.not_supported()

  @impl true
  def market_status(_opts), do: {:ok, :open}

  @impl true
  def subscribe(symbols, opts \\ []) do
    target = Keyword.get(opts, :to, self())

    for symbol <- symbols, symbol in @symbols do
      case get_price(symbol, credentials: %{api_key: "fake", private_key: "fake"}) do
        {:ok, quote_struct} -> send(target, {:dp_exchange, :robinhood, quote_struct})
        _refused -> :ok
      end
    end

    Process.put(__MODULE__, MapSet.new(Enum.filter(symbols, &(&1 in @symbols))))
    :ok
  end

  @impl true
  def unsubscribe(symbols, _opts \\ []) do
    Process.put(__MODULE__, MapSet.difference(subscribed(), MapSet.new(symbols)))
    :ok
  end

  @impl true
  def update_symbols(symbols, _opts \\ []) do
    Process.put(__MODULE__, MapSet.new(Enum.filter(symbols, &(&1 in @symbols))))
    :ok
  end

  # `:internal_poll`, not `:stream`. The real venue has no socket, and a fake claiming one
  # would let a consumer build on a route that does not exist.
  @impl true
  def coverage(_opts \\ []), do: Map.new(subscribed(), &{&1, :internal_poll})

  @impl true
  def subscribe_notices(_opts \\ []), do: :ok

  defp subscribed, do: Process.get(__MODULE__, MapSet.new())

  defp authenticated(opts) do
    case Keyword.get(opts, :credentials) do
      %{api_key: _key, private_key: _private} -> :ok
      _absent -> {:refused, :missing_credentials}
    end
  end
end
