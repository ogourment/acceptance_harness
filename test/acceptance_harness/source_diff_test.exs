defmodule AcceptanceHarness.SourceDiffTest do
  use ExUnit.Case, async: true

  alias AcceptanceHarness.SourceDiff

  test "returns colored line changes with nearby context" do
    previous = Enum.join(["one", "two", "old", "four", "five", "six", "seven", "eight"], "\n")
    current = Enum.join(["one", "two", "new", "four", "five", "six", "seven", "eight"], "\n")

    diff = SourceDiff.compare(previous, current)

    assert diff.additions == 1
    assert diff.deletions == 1
    assert Enum.any?(diff.rows, &(&1.kind == :removed && &1.text == "old"))
    assert Enum.any?(diff.rows, &(&1.kind == :added && &1.text == "new"))
    refute Enum.any?(diff.rows, &(&1.text == "eight"))
  end
end
