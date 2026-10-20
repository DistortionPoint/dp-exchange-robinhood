defmodule DpExchange.Robinhood.TickAoTest do
  # Tick AO: secret hygiene in the error tuples and start arguments a mistaken call produces,
  # and two instances of the tree in one VM.
  use ExUnit.Case, async: true

  alias DpExchange.Core.DefaultRateLimiter
  alias DpExchange.Robinhood
  alias DpExchange.Robinhood.{Credentials, Fake, Feed, Rest}
  alias DpExchange.Robinhood.Supervisor, as: RobinhoodSupervisor

  @api_key "AO_LEAK_PROOF_API_KEY_abc123"
  @private_key Base.encode64(:binary.copy(<<7>>, 32))

  defmodule HostCredentials do
    @moduledoc false
    defstruct [:api_key, :private_key]
  end

  defp raw, do: %{api_key: @api_key, private_key: @private_key}

  defp refute_secret(term) do
    rendered = inspect(term, limit: :infinity, printable_limit: :infinity)
    refute rendered =~ @api_key
    refute rendered =~ @private_key
  end

  describe "options that are not a keyword list never carry a credential into the error" do
    test "a map of options" do
      assert {:error, {:invalid_options, shown}} =
               Robinhood.get_symbols(%{credentials: raw(), timeout: 1})

      refute_secret(shown)
      assert shown =~ "credentials"
    end

    test "the credentials map itself, passed where the options go" do
      assert {:error, {:invalid_options, shown}} = Robinhood.get_top_of_book("BTC-USD", raw())

      refute_secret(shown)
      assert shown =~ "api_key"
    end

    test "a list that is not a keyword list, with the credentials nested inside it" do
      for bad <- [
            [{:credentials, raw()}, :oops],
            [[credentials: raw()]],
            [{:nested, %{private_key: @private_key}}, "x"],
            [{"api_key", @api_key} | :improper]
          ] do
        assert {:error, {:invalid_options, shown}} = Rest.validate_opts(bad, :get_symbols)
        refute_secret(shown)
      end
    end

    test "the Fake renders the same bounded, redacted value when it raises" do
      error = assert_raise ArgumentError, fn -> Fake.coverage(%{credentials: raw()}) end

      refute_secret(Exception.message(error))
    end

    test "a keyword list is still checked by key, and the value is not echoed" do
      assert Rest.validate_opts([credentials: raw()], :get_symbols) == :ok

      assert {:error, {:unknown_option, :limt}} =
               Rest.validate_opts([limt: 1, credentials: raw()], :get_symbols)
    end
  end

  describe "credentials in a shape the package does not read" do
    test "a host's own credentials struct is wrapped without raising" do
      wrapped = Credentials.wrap(%HostCredentials{api_key: @api_key, private_key: @private_key})

      assert %Credentials{api_key: @api_key, private_key: @private_key} = wrapped
      refute_secret(wrapped)
    end

    test "wrap_opt replaces a keyword list or a string with a marker that carries nothing" do
      for bad <- [[api_key: @api_key, private_key: @private_key], @private_key, {@api_key, 1}] do
        opts = Credentials.wrap_opt(name: :x, credentials: bad)

        assert opts[:credentials] == :invalid
        refute_secret(opts)
      end
    end

    test "wrap_opt leaves an absent or nil credential alone" do
      assert Credentials.wrap_opt(name: :x) == [name: :x]
      assert Credentials.wrap_opt(credentials: nil) == [credentials: nil]
    end

    test "the child specs of the facade and of the tree hold no raw secret" do
      opts = [credentials: [api_key: @api_key, private_key: @private_key]]

      refute_secret(Robinhood.child_spec(opts))
      refute_secret(RobinhoodSupervisor.child_spec(opts))
      refute_secret(Feed.child_spec(opts))
    end

    test "a feed started with credentials in the wrong shape is refused, not crashed in init" do
      Process.flag(:trap_exit, true)

      for bad <- [[api_key: @api_key, private_key: @private_key], @private_key, :invalid] do
        assert {:error, {:invalid_option, :credentials}} =
                 Feed.start_link(
                   name: :"feed_ao_#{System.unique_integer([:positive])}",
                   credentials: bad,
                   symbols: [],
                   start_delay_ms: 60_000
                 )
      end
    end

    test "a feed given a host's credentials struct starts" do
      Process.flag(:trap_exit, true)

      assert {:ok, feed} =
               Feed.start_link(
                 name: :"feed_ao_#{System.unique_integer([:positive])}",
                 credentials: %HostCredentials{api_key: @api_key, private_key: @private_key},
                 symbols: [],
                 start_delay_ms: 60_000
               )

      refute_secret(:sys.get_state(feed))
      GenServer.stop(feed)
    end
  end

  describe "two instances in one VM" do
    defp start_named_tree(name) do
      {:ok, sup} =
        RobinhoodSupervisor.start_link(
          name: name,
          credentials: raw(),
          symbols: [],
          start_delay_ms: 600_000,
          interval_ms: 60_000
        )

      sup
    end

    test "two trees started with only distinct names run side by side and answer separately" do
      Process.flag(:trap_exit, true)
      one = :"rh_ao_one_#{System.unique_integer([:positive])}"
      two = :"rh_ao_two_#{System.unique_integer([:positive])}"

      first = start_named_tree(one)
      second = start_named_tree(two)

      assert first != second
      refute RobinhoodSupervisor.feed_name(name: one) == RobinhoodSupervisor.feed_name(name: two)

      refute RobinhoodSupervisor.limiter_name(name: one) ==
               RobinhoodSupervisor.limiter_name(name: two)

      # The facade resolves the same derived names from the tree's name alone.
      assert :ok = Robinhood.update_symbols(["BTC-USD"], name: one)
      assert Robinhood.wanted(name: one) == ["BTC-USD"]
      assert Robinhood.wanted(name: two) == []
      assert Robinhood.coverage(name: two) == %{}
      assert :ok = Robinhood.subscribe_notices(name: two)

      # Each feed polls through its own tree's limiter.
      feed = Process.whereis(RobinhoodSupervisor.feed_name(name: two))
      limiter = RobinhoodSupervisor.limiter_name(name: two)
      assert :sys.get_state(feed).request_opts[:limiter] == limiter
      assert is_pid(Process.whereis(limiter))

      Supervisor.stop(first)
      Supervisor.stop(second)
    end

    test "the default tree, an explicit feed or limiter, and an unnameable name keep their names" do
      assert RobinhoodSupervisor.feed_name([]) == Feed
      assert RobinhoodSupervisor.limiter_name([]) == DpExchange.Robinhood.RateLimiter
      assert RobinhoodSupervisor.feed_name(name: RobinhoodSupervisor) == Feed
      assert RobinhoodSupervisor.feed_name(name: nil) == Feed
      assert RobinhoodSupervisor.feed_name(name: {:global, :rh}) == Feed
      assert RobinhoodSupervisor.feed_name(name: :rh, feed: :mine) == :mine
      assert RobinhoodSupervisor.limiter_name(name: :rh, limiter: :mine) == :mine
      assert RobinhoodSupervisor.limiter_name(name: :rh, limiter: nil) != nil
    end
  end

  describe "remembered-refused symbols cost one request each, never a bisection" do
    # Refuses any request that names a bad symbol (400 for a batch, 404 alone) and answers
    # every other symbol.
    defp refusing_plug(bad, test_pid) do
      fn conn ->
        symbols =
          conn.query_string
          |> URI.query_decoder()
          |> Enum.filter(fn {key, _value} -> key == "symbol" end)
          |> Enum.map(fn {_key, value} -> value end)

        send(test_pid, {:request, symbols})
        conn = Plug.Conn.put_resp_content_type(conn, "application/json")

        case {Enum.any?(symbols, &MapSet.member?(bad, &1)), symbols} do
          {true, [_one, _two | _rest]} ->
            Plug.Conn.resp(conn, 400, Jason.encode!(%{"detail" => "Invalid symbol"}))

          {true, _single} ->
            Plug.Conn.resp(conn, 404, Jason.encode!(%{"detail" => "Symbol not found"}))

          {false, _symbols} ->
            rows = for s <- symbols, do: %{"symbol" => s, "bid" => 1.0, "ask" => 2.0}
            Plug.Conn.resp(conn, 200, Jason.encode!(%{"results" => rows}))
        end
      end
    end

    # Requests seen up to (not including) the next book for `symbol`. A cycle's books are
    # published only after its whole fetch returned, so every request of that cycle precedes it.
    defp requests_until_book(symbol, acc \\ []) do
      receive do
        {:request, symbols} ->
          requests_until_book(symbol, [symbols | acc])

        {:dp_exchange, :robinhood, %DpExchange.Core.Types.TopOfBook{symbol: ^symbol}} ->
          Enum.reverse(acc)

        {:dp_exchange, :robinhood, _other} ->
          requests_until_book(symbol, acc)
      after
        5_000 -> flunk("no book for #{symbol} within 5000ms")
      end
    end

    test "M refused symbols are M single requests plus one bulk request a cycle" do
      limiter = :"rh_ao_limiter_#{System.unique_integer([:positive])}"

      {:ok, _limiter} =
        DefaultRateLimiter.start_link(
          name: limiter,
          limits: %{default: %{limit: 10_000, per_ms: 1_000, burst: 10_000}}
        )

      symbols = for n <- 1..40, do: "S#{n}-USD"
      bad = MapSet.new(for n <- 1..10, do: "S#{n}-USD")

      {:ok, feed} =
        Feed.start_link(
          name: :"rh_ao_feed_#{System.unique_integer([:positive])}",
          credentials: raw(),
          symbols: symbols,
          subscriber: self(),
          limiter: limiter,
          start_delay_ms: 0,
          interval_ms: 1_500,
          retry_attempts: 0,
          plug: refusing_plug(bad, self())
        )

      on_exit(fn ->
        try do
          GenServer.stop(feed)
        catch
          :exit, _reason -> :ok
        end
      end)

      # Cycle one finds the refusals by bisection, whatever that costs.
      _first_cycle = requests_until_book("S40-USD")

      # Cycle two: the 30 live symbols in one request, and each remembered symbol alone.
      second_cycle = requests_until_book("S40-USD")

      assert length(second_cycle) == 11
      assert Enum.count(second_cycle, &(length(&1) == 1)) == 10
      assert Enum.count(second_cycle, &(length(&1) == 30)) == 1
    end
  end
end
