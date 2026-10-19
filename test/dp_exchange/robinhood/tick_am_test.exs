defmodule DpExchange.Robinhood.TickAmTest do
  @moduledoc """
  Tick AM. A signing timestamp that is not whole seconds is refused before anything is signed
  (facade, `Rest`, `Auth` and Fake alike), and the Fake refuses a `:base_url` the real path
  would not sign for, in the real path's order.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Robinhood
  alias DpExchange.Robinhood.{Auth, Fake, Rest}

  @moduletag :capture_log

  @credentials %{
    api_key: "test-key-not-real",
    private_key: Base.encode64(:binary.copy(<<3>>, 32))
  }
  @insecure "http://trading.example.test"
  @request %{symbol: "BTC-USD", side: :buy, order_type: :market, quantity: "0.5"}
  @account [account_number: "RH-1"]
  @served ["BTC-USD", "DOGE-USD", "ETH-USD"]

  # Every facade call that sends a request.
  @calls [
    :get_top_of_book,
    :get_symbols,
    :list_instruments,
    :quantization,
    :get_accounts,
    :get_balances,
    :get_order,
    :get_orders,
    :cancel_order,
    :place_order,
    :get_estimated_price
  ]

  defp hitting(test_pid) do
    fn conn ->
      send(test_pid, {:hit, conn.request_path})
      Req.Test.json(conn, %{"results" => []})
    end
  end

  # The same call, with the same arguments, on `module` (the facade or the Fake).
  defp call(:get_top_of_book, module, creds, opts),
    do: module.get_top_of_book("BTC-USD", [credentials: creds] ++ opts)

  defp call(:get_symbols, module, creds, opts),
    do: module.get_symbols([credentials: creds] ++ opts)

  defp call(:list_instruments, module, creds, opts),
    do: module.list_instruments([credentials: creds] ++ opts)

  defp call(:quantization, module, creds, opts),
    do: module.quantization("BTC-USD", [credentials: creds] ++ opts)

  defp call(:get_accounts, module, creds, opts), do: module.get_accounts(creds, opts)

  defp call(:get_balances, module, creds, opts),
    do: module.get_balances(creds, @account ++ opts)

  defp call(:get_order, module, creds, opts),
    do: module.get_order(creds, "o-1", @account ++ opts)

  defp call(:get_orders, module, creds, opts), do: module.get_orders(creds, @account ++ opts)
  defp call(:cancel_order, module, creds, opts), do: module.cancel_order(creds, "o-1", opts)

  defp call(:place_order, module, creds, opts),
    do: module.place_order(creds, @request, @account ++ opts)

  defp call(:get_estimated_price, module, creds, opts),
    do: module.get_estimated_price("BTC-USD", :bid, 1, creds, opts)

  describe "a signing timestamp is whole seconds or it is refused" do
    test "Auth.headers refuses a float, a string, zero, a negative and a map" do
      for bad <- [1.7e9, "1700000000", 0, -5, %{}] do
        assert {:error, {:invalid_field, :timestamp}} =
                 Auth.headers("GET", "/p", "", @credentials, timestamp: bad)
      end

      assert {:ok, headers} =
               Auth.headers("GET", "/p", "", @credentials, timestamp: 1_700_000_000)

      assert {"x-timestamp", "1700000000"} in headers
    end

    test "credentials are checked before the timestamp" do
      assert {:error, {:missing_credentials, :robinhood}} =
               Auth.headers("GET", "/p", "", %{}, timestamp: 1.5)
    end

    test "every request call refuses a bad timestamp on the facade and the Fake alike" do
      for name <- @calls, module <- [Robinhood, Fake] do
        assert call(name, module, @credentials, timestamp: 1.7e9) ==
                 {:error, {:invalid_field, :timestamp}},
               "#{inspect(module)}.#{name}"
      end
    end

    test "nothing is sent for a bad timestamp" do
      assert {:error, {:invalid_field, :timestamp}} =
               Robinhood.get_symbols(
                 credentials: @credentials,
                 timestamp: "soon",
                 plug: hitting(self()),
                 retry_attempts: 0
               )

      refute_receive {:hit, _path}, 500
    end

    test "a direct Rest.place_order refuses it as a plain error, not an unconfirmed write" do
      assert {:error, {:invalid_field, :timestamp}} =
               Rest.place_order(@credentials, @request,
                 account_number: "RH-1",
                 timestamp: 1.5,
                 plug: hitting(self()),
                 retry_attempts: 0
               )

      refute_receive {:hit, _path}, 500
    end

    test "a forwarded nil timestamp is absent" do
      assert {:ok, @served} = Fake.get_symbols(credentials: @credentials, timestamp: nil)
    end
  end

  describe "the Fake refuses a base_url the real path would not sign for" do
    test "every request call answers what the facade answers, for an insecure url" do
      for name <- @calls, creds <- [@credentials, %{}] do
        real = call(name, Robinhood, creds, base_url: @insecure, plug: hitting(self()))
        fake = call(name, Fake, creds, base_url: @insecure)

        assert fake == real, "#{name}: fake #{inspect(fake)} real #{inspect(real)}"
      end

      refute_receive {:hit, _path}, 500
    end

    test "the url is checked before credentials, except on place_order where credentials win" do
      assert {:error, {:insecure_url, :robinhood}} =
               Fake.get_balances(%{}, account_number: "RH-1", base_url: @insecure)

      assert {:error, {:missing_credentials, :robinhood}} =
               Fake.place_order(%{}, @request, account_number: "RH-1", base_url: @insecure)
    end

    test "arguments and options are checked before the url" do
      assert {:error, {:missing_option, :account_number}} =
               Fake.get_orders(@credentials, base_url: @insecure)

      assert {:error, {:invalid_symbol, ""}} =
               Fake.get_top_of_book("", credentials: @credentials, base_url: @insecure)
    end

    test "a base_url that is not a string is refused by name" do
      assert {:error, {:invalid_base_url, :not_a_string}} =
               Fake.get_symbols(credentials: @credentials, base_url: 12_345)
    end

    test "an https url, a loopback http url and no url are all served" do
      variants = [
        [base_url: "https://trading.example.test"],
        [base_url: "http://localhost:4000"],
        [base_url: nil],
        []
      ]

      for opts <- variants do
        assert {:ok, @served} = Fake.get_symbols([credentials: @credentials] ++ opts)
      end
    end
  end
end
