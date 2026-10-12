defmodule DpExchange.Robinhood.AmountBoundsTest do
  @moduledoc """
  An order amount is refused when expanding it to full notation would build an enormous
  string, and the fake's order ids round-trip through its own reads and cancels.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Robinhood
  alias DpExchange.Robinhood.{Fake, Rest}

  @credentials %{api_key: "k", private_key: Base.encode64(:binary.copy(<<5>>, 32))}
  @account [account_number: "RH-1"]

  describe "scientific-notation amounts" do
    test "a huge exponent is refused instead of expanded into a giant string" do
      # Decimal 3.2's parser already refuses an exponent past 6144, so the strings here are
      # ones it DOES parse and the structs bypass it: only this package's own bound refuses.
      huge = [
        "1e50",
        "1E+500",
        "1e-50",
        "1e-500",
        %Decimal{sign: 1, coef: 1, exp: 999_999_999},
        %Decimal{sign: 1, coef: 1, exp: -999_999_999}
      ]

      for quantity <- huge do
        request = %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: quantity}

        assert Rest.normalize_order_request(request) == {:error, {:invalid_quantity, quantity}}
      end
    end

    test "a modest exponent is still accepted" do
      request = %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: "1e-8"}

      assert {:ok, %{quantity: "0.00000001"}} = Rest.normalize_order_request(request)
    end
  end

  describe "fake order ids round-trip" do
    test "operations that mint ids are declared unsupported, and the fake refuses them alike" do
      caps = Robinhood.capabilities()

      for {fun, args} <- [
            {:place_orders, [@credentials, [], @account]},
            {:replace_order, [@credentials, "id", %{}, @account]},
            {:close_position, [@credentials, "BTC-USD", @account]}
          ] do
        assert caps.endpoints[{fun, length(args)}] == :unsupported
        assert apply(Fake, fun, args) == {:error, :not_supported}
      end
    end

    test "a placed id is read back and cancelled by the same fake" do
      request = %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: "1"}

      assert {:ok, %{id: id}} = Fake.place_order(@credentials, request, @account)
      assert {:ok, %{id: ^id}} = Fake.get_order(@credentials, id, @account)
      assert {:ok, %{id: ^id, status: :cancelled}} = Fake.cancel_order(@credentials, id, [])
      assert {:ok, %{id: ^id, status: :cancelled}} = Fake.get_order(@credentials, id, @account)
    end
  end
end
