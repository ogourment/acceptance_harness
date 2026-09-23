defmodule AcceptanceHarness.Terminal.Assertions do
  @moduledoc "Semantic assertions for normalized terminal screens."

  alias AcceptanceHarness.Terminal.Screen

  defmodule AssertionError do
    defexception [:message]
  end

  @spec visible?(Screen.t(), String.t()) :: boolean()
  def visible?(%Screen{} = screen, expected), do: String.contains?(Screen.text(screen), expected)

  @spec assert_visible!(Screen.t(), String.t()) :: :ok
  def assert_visible!(%Screen{} = screen, expected) when is_binary(expected) do
    if visible?(screen, expected) do
      :ok
    else
      raise AssertionError,
        message: "expected terminal to show #{inspect(expected)}\n\n#{Screen.text(screen)}"
    end
  end

  @spec row(Screen.t(), pos_integer()) :: String.t()
  def row(%Screen{} = screen, number), do: Screen.row(screen, number)

  @spec assert_row!(Screen.t(), pos_integer(), String.t()) :: :ok
  def assert_row!(%Screen{} = screen, number, expected) when is_binary(expected) do
    actual = row(screen, number)

    if actual == expected do
      :ok
    else
      raise AssertionError,
        message:
          "expected terminal row #{number} to equal #{inspect(expected)}, got: #{inspect(actual)}"
    end
  end
end
