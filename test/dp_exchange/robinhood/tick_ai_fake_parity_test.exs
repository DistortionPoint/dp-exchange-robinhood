defmodule DpExchange.Robinhood.TickAiFakeParityTest do
  @moduledoc """
  The Fake must answer every public function the real facade exposes, at the same arity.
  A Fake missing one makes a consumer's tier-1 test crash with `UndefinedFunctionError`
  where production answers.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Robinhood
  alias DpExchange.Robinhood.Fake

  test "every public facade function exists on the Fake at the same name and arity" do
    assert Robinhood.__info__(:functions) -- Fake.__info__(:functions) == []
  end

  test "venue_does_not_serve/0 is the real list, unchanged" do
    assert Fake.venue_does_not_serve() == Robinhood.venue_does_not_serve()
    assert is_list(Fake.venue_does_not_serve())
  end

  test "quotes/0 is the real vocabulary, unchanged" do
    assert Fake.quotes() == Robinhood.quotes()
    assert Enum.all?(Fake.quotes(), &is_binary/1)
    assert "USD" in Fake.quotes()
  end
end
