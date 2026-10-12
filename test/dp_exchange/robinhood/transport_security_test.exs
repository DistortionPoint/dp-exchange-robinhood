defmodule DpExchange.Robinhood.TransportSecurityTest do
  @moduledoc """
  Tick Z security audit. A signed request never leaves over cleartext HTTP to a non-loopback
  host, a signature always covers the path that is sent, a raw credential never sits in a
  supervisor's start argument, and a venue's text is bounded on its way into an error tuple.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Robinhood.{Rest, Supervisor}

  @moduletag :capture_log

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

  @credentials %{
    api_key: "test-key-not-real",
    private_key: Base.encode64(:binary.copy(<<3>>, 32))
  }
  @pairs %{"results" => [%{"symbol" => "BTC-USD"}], "next" => nil}

  defp hitting(body, test_pid) do
    fn conn ->
      send(test_pid, {:hit, conn.scheme, conn.request_path})
      Req.Test.json(conn, body)
    end
  end

  describe "an authenticated call never goes out over cleartext HTTP" do
    test "a read with an http:// base_url is refused before anything is signed or sent" do
      assert {:error, {:insecure_base_url, "http"}} =
               Rest.get_symbols(@credentials,
                 base_url: "http://trading.example.test",
                 plug: hitting(@pairs, self()),
                 retry_attempts: 0
               )

      refute_received {:hit, _scheme, _path}
    end

    test "a base_url with no scheme is refused, naming the scheme and never the URL" do
      assert {:error, {:insecure_base_url, nil}} =
               Rest.get_symbols(@credentials,
                 base_url: "//trading.example.test",
                 plug: hitting(@pairs, self()),
                 retry_attempts: 0
               )

      refute_received {:hit, _scheme, _path}
    end

    test "a base_url that is not a string is refused, not raised on" do
      assert {:error, {:invalid_base_url, :not_a_string}} =
               Rest.get_symbols(@credentials,
                 base_url: 12_345,
                 plug: hitting(@pairs, self()),
                 retry_attempts: 0
               )
    end

    test "a write to an http:// base_url is a plain refusal, not an unconfirmed order" do
      request = %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: "0.5"}

      assert {:error, {:insecure_base_url, "http"}} =
               Rest.place_order(@credentials, request,
                 account_number: "RH-1",
                 base_url: "http://trading.example.test",
                 plug: hitting(%{"id" => "o-1"}, self()),
                 retry_attempts: 0
               )

      refute_received {:hit, _scheme, _path}
    end

    test "a cancel to an http:// base_url is refused before anything is sent" do
      assert {:error, {:insecure_base_url, "http"}} =
               Rest.cancel_order(@credentials, "o-1",
                 base_url: "http://trading.example.test",
                 plug: hitting(%{"id" => "o-1"}, self()),
                 retry_attempts: 0
               )

      refute_received {:hit, _scheme, _path}
    end

    test "a loopback host may use http, the seam for a local stub" do
      assert {:ok, ["BTC-USD"]} =
               Rest.get_symbols(@credentials,
                 base_url: "http://localhost:4000",
                 plug: hitting(@pairs, self()),
                 retry_attempts: 0
               )

      assert_received {:hit, :http, "/api/v2/crypto/trading/trading_pairs/"}
    end
  end

  describe "the signed path is the sent path" do
    test "a trailing slash on base_url does not send //api where /api was signed" do
      assert {:ok, ["BTC-USD"]} =
               Rest.get_symbols(@credentials,
                 base_url: "https://trading.example.test/",
                 plug: hitting(@pairs, self()),
                 retry_attempts: 0
               )

      assert_received {:hit, :https, "/api/v2/crypto/trading/trading_pairs/"}
    end
  end

  describe "a supervisor's start argument never holds a raw credential" do
    test "child_spec/1 wraps :credentials so OTP's Start Call line cannot print them" do
      credentials = %{api_key: "test-key-not-real", private_key: "test-secret-not-real"}

      assert %{start: {Supervisor, :start_link, [opts]}, type: :supervisor} =
               Supervisor.child_spec(credentials: credentials, symbols: [])

      printed = inspect(opts)
      refute printed =~ "test-key-not-real"
      refute printed =~ "test-secret-not-real"
    end
  end

  describe "a venue's text is bounded on its way into an error tuple" do
    test "an unknown order enum value is cut, not carried whole" do
      huge = String.duplicate("x", 5_000)

      assert {:error, {:unknown_enum, :side, shown}} =
               Rest.get_order(@credentials, "o-1",
                 account_number: "RH-1",
                 plug: hitting(%{"id" => "o-1", "side" => huge}, self()),
                 retry_attempts: 0
               )

      assert byte_size(shown) < 200
    end

    test "a foreign next-page host is cut, not carried whole" do
      host = String.duplicate("a", 5_000) <> ".example.com"
      next = "https://#{host}/api/v2/crypto/trading/trading_pairs/?cursor=2"

      assert {:error, {:foreign_next_url, shown}} =
               Rest.get_symbols(@credentials,
                 plug: hitting(%{"results" => [], "next" => next}, self()),
                 retry_attempts: 0
               )

      assert byte_size(shown) < 200
    end
  end
end
