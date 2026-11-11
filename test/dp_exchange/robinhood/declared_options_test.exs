defmodule DpExchange.Robinhood.DeclaredOptionsTest do
  # Core issue #43: `start_options/0` and `call_options/1` declare the option keys each call
  # accepts, so a consumer can `Keyword.take/2` instead of finding out by being refused
  # (Robinhood refused `:channels` and `:priority_symbols` at start, which a consumer had no
  # way to know). The declaration must equal what the check accepts, and it must be read from
  # the same list the check uses. No network: every call here is an option check.
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Capabilities, Venue}
  alias DpExchange.Robinhood
  alias DpExchange.Robinhood.{Fake, Rest}

  @venues [Robinhood, Fake]
  @probe :dp_contract_unknown_option

  # Functions that read no option, and the functions whose check is another function's.
  @no_options [
    :provider_name,
    :runtime_id,
    :asset_classes,
    :capabilities,
    :venue_does_not_serve,
    :quotes,
    :start_options,
    :call_options
  ]
  @groups %{child_spec: :start_link, coverage_by_kind: :coverage, wanted: :coverage}

  defp names(module), do: module.__info__(:functions) |> Keyword.keys() |> Enum.uniq()

  defp group(name), do: Map.get(@groups, name, name)

  defp declared(module, name), do: module.call_options(name)

  defp unique_atoms?(keys), do: Enum.all?(keys, &is_atom/1) and keys == Enum.uniq(keys)

  describe "start_options/0" do
    for module <- @venues do
      test "#{inspect(module)} lists unique atoms from the list the start check uses" do
        keys = unquote(module).start_options()

        assert unique_atoms?(keys)
        assert keys == Rest.allowed_options(:start_link)
        refute @probe in keys
      end

      test "#{inspect(module)}: every start key passes the start check with a nil value" do
        for key <- unquote(module).start_options() do
          assert Rest.validate_opts([{key, nil}], :start_link) == :ok, inspect(key)
        end
      end

      test "#{inspect(module)}: a key outside the list is refused at start" do
        refute @probe in unquote(module).start_options()

        assert unquote(module).start_link([{@probe, nil}]) ==
                 {:error, {:unknown_option, @probe}}
      end

      test "#{inspect(module)}: the keys Robinhood refused at start are not declared" do
        keys = unquote(module).start_options()

        for refused <- [:channels, :priority_symbols] do
          refute refused in keys

          assert unquote(module).start_link([{refused, nil}]) ==
                   {:error, {:unknown_option, refused}}
        end
      end
    end

    test "the transport keys the poll forwards and the tree's own keys are declared" do
      keys = Robinhood.start_options()

      assert :credentials in keys
      assert :base_url in keys
      assert :symbols in keys
      assert :subscriber in keys
      assert :interval_ms in keys
    end
  end

  describe "call_options/1" do
    for module <- @venues do
      test "#{inspect(module)}: every public function answers keys or not_supported" do
        for name <- names(unquote(module)) do
          case declared(unquote(module), name) do
            {:ok, keys} -> assert unique_atoms?(keys), inspect(name)
            {:error, :not_supported} -> :ok
            other -> flunk("#{name}: #{inspect(other)}")
          end
        end
      end

      test "#{inspect(module)}: a callback answers not_supported exactly when inactive" do
        caps = unquote(module).capabilities()

        for {name, arity} <- Venue.behaviour_info(:callbacks),
            function_exported?(unquote(module), name, arity) do
          result = declared(unquote(module), name)

          if Capabilities.active?(caps, {name, arity}) do
            assert match?({:ok, _keys}, result), inspect({name, arity, result})
          else
            assert result == {:error, :not_supported}, inspect({name, arity})
          end
        end
      end

      test "#{inspect(module)}: declared keys are the keys the call's check accepts" do
        for name <- names(unquote(module)),
            {:ok, keys} <- [declared(unquote(module), name)],
            name not in @no_options do
          assert keys == Rest.allowed_options(group(name)), inspect(name)
          refute @probe in keys, inspect(name)

          for key <- keys do
            assert Rest.validate_opts([{key, nil}], group(name)) == :ok, inspect({name, key})
          end

          assert Rest.validate_opts([{@probe, nil}], group(name)) ==
                   {:error, {:unknown_option, @probe}}
        end
      end

      test "#{inspect(module)}: functions that take no options answer an empty list" do
        for name <- @no_options do
          assert declared(unquote(module), name) == {:ok, []}, inspect(name)
        end
      end

      test "#{inspect(module)}: child_spec and start_link answer start_options" do
        start = unquote(module).start_options()

        assert declared(unquote(module), :child_spec) == {:ok, start}
        assert declared(unquote(module), :start_link) == {:ok, start}
      end

      test "#{inspect(module)}: an unknown name or a non-atom is unknown_function" do
        for name <- [:dp_contract_no_such_function, "get_top_of_book", 42, nil, {:a, 1}, []] do
          assert declared(unquote(module), name) == {:error, {:unknown_function, name}},
                 inspect(name)
        end
      end
    end

    test "an inactive endpoint is not_supported whatever the options" do
      assert Robinhood.call_options(:get_price) == {:error, :not_supported}
      assert Robinhood.call_options(:place_orders) == {:error, :not_supported}
      assert Fake.call_options(:get_price) == {:error, :not_supported}
    end

    test "the sent-once cancel declares neither retry key; place_order declares both" do
      {:ok, cancel} = Robinhood.call_options(:cancel_order)
      {:ok, place} = Robinhood.call_options(:place_order)

      refute :retry_attempts in cancel
      refute :retry_delay in cancel
      assert :retry_attempts in place
      assert :retry_delay in place
      assert :client_order_id in place
    end

    test "a call that sends no request declares credentials and its own keys only" do
      {:ok, keys} = Robinhood.call_options(:subscribe)

      assert :credentials in keys
      assert :to in keys
      assert :feed in keys
      refute :timeout in keys
      refute :environment in keys
    end

    test "coverage_by_kind, wanted and market_status declare what their check accepts" do
      assert Robinhood.call_options(:coverage_by_kind) == Robinhood.call_options(:coverage)
      assert Robinhood.call_options(:wanted) == Robinhood.call_options(:coverage)
      assert Robinhood.call_options(:market_status) == {:ok, [:credentials]}
    end
  end

  describe "the Fake accepts what the facade declares" do
    test "for every function, the facade's keys are a subset of the fake's" do
      for name <- names(Robinhood) do
        case {Robinhood.call_options(name), Fake.call_options(name)} do
          {{:ok, facade}, {:ok, fake}} -> assert facade -- fake == [], inspect(name)
          {same, same} -> :ok
          other -> flunk("#{name}: #{inspect(other)}")
        end
      end
    end

    test "start keys: the fake's list equals the facade's" do
      assert Fake.start_options() == Robinhood.start_options()
    end
  end
end
