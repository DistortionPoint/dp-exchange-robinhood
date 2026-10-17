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

  # `get_balances/2` also calls `get_accounts/2` for the account's cash (dp-exchange-core
  # issue #35), through the same `opts[:plug]` — routed here by request path so the
  # holdings-shaped `body` never has to answer for the accounts call too.
  defp opts(body) do
    plug = fn conn ->
      response =
        if String.contains?(conn.request_path, "/holdings/") do
          body
        else
          %{
            "results" => [
              %{
                "account_number" => "RH-1",
                "buying_power" => "1000.00",
                "buying_power_currency" => "USD"
              }
            ]
          }
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
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
    # key". An absent, null or empty quantity states nothing, and `Core.Types.Balance`
    # permits that in `:balance`. What it does not permit is not knowing which asset the row
    # is about. (A quantity that WAS sent and cannot be read is a different matter, below.)
    for stated_nothing <- [nil, ""] do
      body = %{
        "results" => [
          %{
            "asset_code" => "BTC",
            "total_quantity" => stated_nothing,
            "quantity_available_for_trading" => stated_nothing
          },
          %{"asset_code" => "ETH"}
        ]
      }

      # Plus the account's cash (dp-exchange-core issue #35), appended after the holdings.
      assert {:ok, [btc, eth, cash]} = Rest.get_balances(@credentials, opts(body))
      assert btc.currency == "BTC"
      assert btc.balance == nil
      assert btc.available_balance == nil
      assert eth.balance == nil
      assert cash.currency == "USD"
    end
  end

  test "a quantity that was sent and cannot be read refuses the reply, it is not 'unknown'" do
    # `decimal/1` answers `nil` for NaN, Infinity, text and a boolean, and this used to carry
    # that `nil` into `Balance.balance`: "unknown" said about a value the venue did state. A
    # negative holding is no position any account has, and rode out as the number sent.
    for {key, field} <- [
          {"total_quantity", :balance},
          {"quantity_available_for_trading", :available_balance}
        ],
        bad <- ["NaN", "-Infinity", "abc", "-0.5", true, %{"v" => 1}, -3] do
      body = %{"results" => [%{"asset_code" => "BTC", key => bad}]}

      assert {:error, {:invalid_decimal, ^field, shown}} =
               Rest.get_balances(@credentials, opts(body))

      # The venue's own value, as sent (or inspected when it is not text or a number).
      assert shown == bad or shown == inspect(bad)
    end
  end

  test "a zero quantity is a real, empty holding, not a refusal" do
    body = %{
      "results" => [
        %{"asset_code" => "BTC", "total_quantity" => "0", "quantity_available_for_trading" => 0}
      ]
    }

    assert {:ok, [btc, _cash]} = Rest.get_balances(@credentials, opts(body))
    assert Decimal.equal?(btc.balance, Decimal.new(0))
    assert Decimal.equal?(btc.available_balance, Decimal.new(0))
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

    assert {:ok, [balance, cash]} = Rest.get_balances(@credentials, opts(body))
    assert balance.currency == "BTC"
    assert Decimal.equal?(balance.balance, Decimal.new("1.5"))
    assert Decimal.equal?(balance.available_balance, Decimal.new("1.0"))
    assert balance.provider == :robinhood

    # The account's cash — dp-exchange-core issue #35.
    assert cash.currency == "USD"
    assert cash.balance == nil
    assert Decimal.equal?(cash.available_balance, Decimal.new("1000.00"))
    assert cash.provider == :robinhood
  end
end
