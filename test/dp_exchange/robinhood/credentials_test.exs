defmodule DpExchange.Robinhood.CredentialsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DpExchange.Robinhood.Credentials

  @api_key "LEAK_PROOF_API_KEY_abc123"
  @private_key "LEAK_PROOF_PRIVATE_KEY_SEED_def456"

  describe "wrap/1" do
    test "a raw credentials map is struct-ified" do
      wrapped = Credentials.wrap(%{api_key: @api_key, private_key: @private_key})

      assert %Credentials{api_key: @api_key, private_key: @private_key} = wrapped
    end

    test "already-wrapped credentials pass through unchanged" do
      wrapped = Credentials.wrap(%{api_key: @api_key, private_key: @private_key})

      assert Credentials.wrap(wrapped) == wrapped
    end

    test "an empty map wraps to a struct whose fields are all nil — the shape " <>
           "Auth.headers/5's catch-all clause refuses" do
      assert Credentials.wrap(%{}) == %Credentials{}
    end

    test "an unrelated extra key is ignored, matching how Auth.headers/5 already reads " <>
           "this map — pattern-matching only the keys it needs" do
      wrapped = Credentials.wrap(%{api_key: @api_key, private_key: @private_key, extra: "x"})

      assert wrapped.api_key == @api_key
      assert wrapped.private_key == @private_key
    end
  end

  describe "Inspect redaction" do
    test "neither secret field appears in the struct's own inspected output" do
      wrapped = Credentials.wrap(%{api_key: @api_key, private_key: @private_key})
      rendered = inspect(wrapped)

      refute rendered =~ @api_key
      refute rendered =~ @private_key
      assert rendered =~ "DpExchange.Robinhood.Credentials<...>"
    end

    test "the secret stays redacted nested inside an ordinary map — the exact shape " <>
           "Feed's state takes" do
      state = %{credentials: Credentials.wrap(%{private_key: @private_key})}

      refute inspect(state) =~ @private_key
    end
  end

  describe "crash-report proof" do
    # Mirrors the exact state-construction idiom `Feed.init/1` (feed.ex) uses:
    # credentials wrapped via `Credentials.wrap/1` and stored as a top-level field of a
    # GenServer's state. Before this fix, the equivalent state shape — a PLAIN map, not
    # this struct — printed the raw Ed25519 seed in full on a crash of `Feed`; this
    # proves the wrapping mechanism it now relies on. `async: false`: a
    # `CaptureLog`-content assertion under `async: true` was already found
    # non-concurrency-safe once in this family.
    defmodule LeakyProbe do
      use GenServer

      @spec start_link(map()) :: GenServer.on_start()
      def start_link(credentials), do: GenServer.start_link(__MODULE__, credentials)

      @spec init(map()) :: {:ok, map()}
      def init(credentials) do
        {:ok, %{credentials: DpExchange.Robinhood.Credentials.wrap(credentials), symbols: []}}
      end

      @spec boom(pid()) :: any()
      def boom(pid), do: GenServer.call(pid, :boom)

      @spec handle_call(:boom, GenServer.from(), map()) :: no_return()
      def handle_call(:boom, _from, _state), do: raise("simulated crash for leak-proof test")
    end

    test "a crash of a process holding wrapped credentials never prints the secrets" do
      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          {:ok, pid} = LeakyProbe.start_link(%{api_key: @api_key, private_key: @private_key})
          ref = Process.monitor(pid)

          try do
            LeakyProbe.boom(pid)
          catch
            :exit, _reason -> :ok
          end

          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
        end)

      assert log =~ "simulated crash for leak-proof test"
      refute log =~ @api_key
      refute log =~ @private_key
      assert log =~ "DpExchange.Robinhood.Credentials<...>"
    end
  end
end
