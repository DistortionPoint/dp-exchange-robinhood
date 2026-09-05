# DpExchangeRobinhood

> ## ⚠️ EXPERIMENTAL — read this before depending on it
>
> This package has **never run in production.** It is published early and openly so it
> can be used and reported on, not because it is finished.
>
> - **The API may change without a major version.** Pin three-part (`~> 0.1.0`).
> - **Verification is uneven, and the gaps are on the expensive side.** The conformance
>   suite passes against a fake, and against Robinhood's live public endpoints.
>   **Order placement and authenticated flows are thinly covered.** No test in this repo
>   spends money.
> - **Maturity is declared per endpoint.** Read `capabilities/0`, not this banner.
>
> [Report a divergence](https://github.com/DistortionPoint/dp-exchange-robinhood/issues).

Robinhood for the **DpExchange** family: market data, trading and streaming behind the
same facade every venue in the family exposes.

## Installation

```elixir
def deps do
  [
    {:dp_exchange_robinhood, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
# In your supervision tree. Nothing starts itself.
children = [{DpExchange.Robinhood, credentials: my_credentials()}]

# This venue publishes no last-trade data at all — get_price/2 is :unsupported. The book
# is the real market-data call here; see usage-rules.md for why.
{:ok, book} = DpExchange.Robinhood.get_top_of_book("BTCUSD", credentials: my_credentials())

:ok = DpExchange.Robinhood.subscribe(["BTCUSD"], to: self())
```

`DpExchange.Robinhood` is the **entire public API**. Everything else — transport, signing,
session handling, supervision — is internal, and the conformance suite asserts it.

See [`dp_exchange_core`](https://hex.pm/packages/dp_exchange_core) for the contract, and
this package's `usage-rules.md` for what is specific to Robinhood.

## License

MIT. See [LICENSE](https://github.com/DistortionPoint/dp-exchange-robinhood/blob/main/LICENSE).
