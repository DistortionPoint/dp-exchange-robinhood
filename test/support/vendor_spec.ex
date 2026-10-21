defmodule DpExchange.Robinhood.Test.VendorSpec do
  @moduledoc false
  # The vendor's committed OpenAPI document (docs/reference/robinhood/openapi), read once, for
  # tests that walk its enums. Reading them from the document, not retyping them, is what
  # makes a word the vendor adds fail a test instead of reaching a caller as `nil`.

  @openapi_dir Path.expand("../../docs/reference/robinhood/openapi", __DIR__)
  @path Path.join(@openapi_dir, "crypto-trading.openapi.json")
  @external_resource @path
  @document @path |> File.read!() |> Jason.decode!()

  @doc "The `enum` of one property of the vendor's `OrderResponse` (`state`, `side`, `type`)."
  @spec order_enum(String.t()) :: [String.t()]
  def order_enum(field) do
    path = ["components", "schemas", "OrderResponse", "properties", field, "enum"]
    get_in(@document, path)
  end

  @doc "The vendor's `TimeInForce` enum."
  @spec time_in_force_enum() :: [String.t()]
  def time_in_force_enum do
    get_in(@document, ["components", "requestParameters", "TimeInForce", "enum"])
  end

  @doc "Every enum-valued query parameter of `GET /api/v2/crypto/trading/orders/`, by name."
  @spec list_filter_enums() :: %{String.t() => [String.t()]}
  def list_filter_enums do
    path = ["paths", "/api/v2/crypto/trading/orders/", "get", "parameters"]
    params = get_in(@document, path)

    for %{"name" => name, "schema" => %{"enum" => values}} <- params, into: %{} do
      {name, values}
    end
  end
end
