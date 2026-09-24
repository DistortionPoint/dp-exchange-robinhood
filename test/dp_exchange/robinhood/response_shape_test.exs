defmodule DpExchange.Robinhood.ResponseShapeTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Config

  # **A response of the wrong JSON shape is an answer, never a raise.**
  #
  # `Core.Venue`'s error discipline is that a facade call answers — `{:ok, _}`,
  # `{:error, _}`, `{:refused, _}` — and does not raise in the caller's process. These are
  # the calls that did, found by feeding every active facade callback a set of plausible
  # but wrong bodies: `[]`, `null`, `{}`, an object whose list fields are all `null`, and
  # `{"data": {}}`. Each row below is one body that used to raise, and the exception it
  # raised. Driven through the FACADE, with the HTTP layer replaced by a `plug:`, so what
  # is measured is exactly the decode path a consumer reaches.
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

  @credentials %{api_key: "k", private_key: Base.encode64(:crypto.strong_rand_bytes(32))}

  defp answering(body), do: fn conn -> Req.Test.json(conn, body) end

  defp base(body) do
    [
      plug: answering(body),
      retry_attempts: 0,
      credentials: @credentials,
      account_id: "acct",
      account_number: "acct",
      account_hash: "acct"
    ]
  end

  defp answers_without_raising(label, fun) do
    result =
      try do
        fun.()
      rescue
        error -> {:raised, error}
      end

    refute match?({:raised, _error}, result),
           "robinhood: #{label} raised #{inspect(result)} — a response shape it did not " <>
             "expect must be refused, not raised in the caller's process"

    result
  end

  # Not a raise here — a PHANTOM. `get_orders/2` read its rows through the accounts
  # helper, whose bare-object clause turned `{}` into `{:ok, [%Order{id: nil, …}]}`, and
  # `get_order/3` accepted any map as an order.
  test "an empty object is not an order, in the list or on its own" do
    v = DpExchange.Robinhood

    assert {:error, :unexpected_response_shape} =
             answers_without_raising("get_orders/2", fn ->
               v.get_orders(@credentials, base(%{}))
             end)

    assert {:error, {:missing_required_field, :id}} =
             answers_without_raising("get_order/3", fn ->
               v.get_order(@credentials, "o-1", base(%{}))
             end)
  end

  test "a page with an id-less order refuses the page — this module's own rule" do
    # `to_orders/1` refuses the whole batch on one unreadable row, because a list with an
    # order silently missing reads as complete.
    page = %{"results" => [%{"id" => "o-1", "symbol" => "BTC-USD"}, %{"symbol" => "ETH-USD"}]}

    assert {:error, {:missing_required_field, :id}} =
             answers_without_raising("get_orders/2", fn ->
               DpExchange.Robinhood.get_orders(@credentials, base(page))
             end)
  end

  test "a real page still decodes" do
    page = %{"results" => [%{"id" => "o-1", "symbol" => "BTC-USD", "side" => "buy"}]}

    assert {:ok, [%{id: "o-1"}]} = DpExchange.Robinhood.get_orders(@credentials, base(page))
  end
end
