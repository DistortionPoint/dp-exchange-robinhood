defmodule DpExchange.Robinhood.Test.AmbiguousWrite do
  @moduledoc false
  # The seam for Core conformance group 42: runs the REAL `Rest.place_order/3` (not the Fake)
  # with a 503 injected on every attempt, i.e. after the request was signed and sent.

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

  @credentials %{api_key: "rh-key", private_key: Base.encode64(:binary.copy(<<7>>, 32))}

  @doc """
  Places `request` through the real path against a plug answering 503 to every attempt.
  The request is passed as the contract builds it; `Rest.place_order/3` already accepts the
  canonical symbol, so no mapping is needed.
  """
  @spec place(map()) :: term()
  def place(request) do
    # Process-scoped override: the contract runs this in the test's own process.
    Config.put_override(:rate_limit_module, PermissiveLimiter)

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(503, "down")
    end

    Rest.place_order(@credentials, request,
      account_number: "RH-1",
      plug: plug,
      retry_attempts: 2,
      retry_delay: 1
    )
  end
end
