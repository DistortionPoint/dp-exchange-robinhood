defmodule DpExchange.Robinhood.BalanceAttributionTest do
  @moduledoc """
  A balance the venue did not attribute to an asset is refused, not returned.

  `Core.Types.Balance`'s `new/1` refuses a `nil` in `:currency`. No venue decoder in this
  family calls `new/1` — every one builds the struct literally — so that check never ran,
  and `currency` came straight out of the venue's JSON by key. A renamed or absent
  `asset_code` produced `%Balance{currency: nil}`: an amount attributable to no asset,
  returned inside `{:ok, balances}`. A consumer cannot size, book or reconcile against it,
  and nothing in the value says so.

  `:balance` is deliberately a different matter — `Core.Types.Balance` now states that it
  may honestly be `nil` while `:currency` may not — so the second test here pins the
  distinction rather than letting a later tightening quietly swallow it.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Robinhood.Rest

  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{api_key: "rh-key", private_key: Base.encode64(:crypto.strong_rand_bytes(32))}

  defp opts(body) do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end

    [account_number: "RH-1", retry_attempts: 0, plug: plug]
  end

  test "a holdings row with no asset code refuses the whole reply" do
    body = %{"results" => [%{"total_quantity" => "1.5"}]}

    assert {:error, :unexpected_response_shape} = Rest.get_balances(@credentials, opts(body))
  end

  test "one unattributable row refuses even when the others are fine" do
    # Dropping it silently would be worse than refusing: a balance list with an entry
    # missing reads as "you hold none of that asset", which is a different and more
    # dangerous claim than "this response could not be read".
    body = %{
      "results" => [
        %{"asset_code" => "BTC", "total_quantity" => "1.5"},
        %{"total_quantity" => "2.0"}
      ]
    }

    assert {:error, :unexpected_response_shape} = Rest.get_balances(@credentials, opts(body))
  end

  test "an unstated quantity is NOT refused — an unknown total is still a balance" do
    # The other half of the rule, and the reason this is not simply "guard every enforced
    # key". `decimal/1` returns `nil` for an absent, empty, unparseable or NaN/Infinity
    # value, and `Core.Types.Balance` permits that in `:balance`. What it does not permit is
    # not knowing which asset the row is about.
    body = %{"results" => [%{"asset_code" => "BTC", "total_quantity" => "NaN"}]}

    assert {:ok, [balance]} = Rest.get_balances(@credentials, opts(body))
    assert balance.currency == "BTC"
    assert balance.balance == nil
  end

  test "an ordinary holdings row still decodes" do
    body = %{
      "results" => [
        %{
          "asset_code" => "BTC",
          "total_quantity" => "1.5",
          "quantity_available_for_trading" => "1.0"
        }
      ]
    }

    assert {:ok, [balance]} = Rest.get_balances(@credentials, opts(body))
    assert balance.currency == "BTC"
    assert Decimal.equal?(balance.balance, Decimal.new("1.5"))
    assert Decimal.equal?(balance.available_balance, Decimal.new("1.0"))
    assert balance.provider == :robinhood
  end
end
