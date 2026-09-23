defmodule AcceptanceHarness.Terminal.Screen do
  @moduledoc """
  Normalized fixed-grid terminal snapshot produced by the native VT100 parser.

  `PortTransport` preserves raw output independently and delegates incremental
  UTF-8, ANSI, cursor, erase, scrolling, and alternate-screen handling to the
  maintained Rust `vt100` parser.
  """

  defstruct [:columns, :rows, :text]

  @type t :: %__MODULE__{columns: pos_integer(), rows: pos_integer(), text: String.t()}

  @spec snapshot(module(), pid()) :: {:ok, t()} | {:error, term()}
  def snapshot(transport, session) do
    case transport.snapshot(session) do
      {:ok, snapshot} -> {:ok, new(snapshot)}
      {:error, _reason} = error -> error
    end
  end

  @spec new(map()) :: t()
  def new(%{rows: rows, columns: columns, text: text})
      when is_integer(rows) and rows > 0 and is_integer(columns) and columns > 0 and
             is_binary(text) do
    %__MODULE__{rows: rows, columns: columns, text: text}
  end

  @spec text(t()) :: String.t()
  def text(%__MODULE__{text: text}), do: text

  @spec row(t(), pos_integer()) :: String.t()
  def row(%__MODULE__{} = screen, number)
      when is_integer(number) and number >= 1 and number <= screen.rows do
    screen.text |> String.split("\n") |> Enum.at(number - 1, "")
  end

  def row(%__MODULE__{rows: rows}, number) do
    raise ArgumentError, "terminal row must be between 1 and #{rows}, got: #{inspect(number)}"
  end
end
