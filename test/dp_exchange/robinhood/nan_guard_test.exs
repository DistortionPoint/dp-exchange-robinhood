defmodule DpExchange.Robinhood.NaNGuardTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Robinhood.Rest

  # `Core.HttpClient` fails closed when no limiter is reachable, so a test that means to
  # exercise a decode path has to supply one or it never reaches the wire at all.
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

  # `Decimal.parse/1` requiring the whole string be consumed is not a sufficient guard on its
  # own: "NaN", "Inf" and "-Inf" all parse fully and case-insensitively, so each arrived as a
  # well-formed `Decimal` and flowed onward as a real bid or ask.
  #
  # That is worse than a raise, and it fails a long way from the cause. `Decimal.add(nan, 1)`
  # is NaN, so it poisons a consumer's arithmetic silently; `Decimal.compare(nan, _)` RAISES
  # `invalid_operation: operation on NaN`, in the consumer's own process, naming Decimal
  # rather than the venue that sent it. An Infinity is quieter still — it compares greater
  # than everything and never raises.
  #
  # `dp_exchange_webull` found this and guarded both of its copies. This package guarded its
  # one not at all.
  @credentials %{api_key: "k", private_key: Base.encode64(:binary.copy(<<3>>, 32))}

  # Lowercase and mixed forms included deliberately: `Decimal.parse/1` is case-insensitive
  # here, so a guard matching only the canonical spelling would let `"inf"` straight through.
  @poison ["NaN", "nan", "-NaN", "Inf", "inf", "-Inf", "Infinity", "-Infinity"]

  defp responding(body), do: fn conn -> Req.Test.json(conn, body) end

  defp book(bid),
    do: %{"results" => [%{"symbol" => "BTC-USD", "bid" => bid, "ask" => "77850.00"}]}

  describe "a NaN or Infinity from the venue is dropped, never admitted as a number" do
    for value <- @poison do
      test "#{value} as a bid is nil, not a Decimal" do
        assert {:ok, top} =
                 Rest.get_top_of_book("BTC-USD", @credentials,
                   plug: responding(book(unquote(value))),
                   retry_attempts: 0
                 )

        assert top.bid == nil
        # The ask beside it is untouched — one poisoned field must not discard a good one.
        assert Decimal.equal?(top.ask, Decimal.new("77850.00"))
      end
    end

    test "a real bid still decodes, so the guard has not eaten the happy path" do
      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(book("77840.00")),
                 retry_attempts: 0
               )

      assert Decimal.equal?(top.bid, Decimal.new("77840.00"))
    end

    test "what a NaN would have done downstream, stated rather than assumed" do
      {nan, ""} = Decimal.parse("NaN")

      assert Decimal.nan?(nan)
      assert nan |> Decimal.add(Decimal.new(1)) |> Decimal.nan?()
      assert_raise Decimal.Error, fn -> Decimal.compare(nan, Decimal.new(1)) end
    end
  end
end
