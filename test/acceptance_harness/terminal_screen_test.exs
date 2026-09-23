defmodule AcceptanceHarness.Terminal.ScreenTest do
  use ExUnit.Case, async: true

  alias AcceptanceHarness.FakeTerminalTransport
  alias AcceptanceHarness.Terminal.{Assertions, Screen}

  test "wraps transport snapshots and provides semantic visible-text and row assertions" do
    assert {:ok, session} =
             FakeTerminalTransport.start(
               snapshot: %{
                 rows: 4,
                 columns: 40,
                 text: "Repository health\n12 repositories checked\na55ist  dirty"
               }
             )

    assert_receive {:terminal_transport, ^session, {:started, 1234}}
    assert {:ok, screen} = Screen.snapshot(FakeTerminalTransport, session)

    assert screen.rows == 4
    assert screen.columns == 40
    assert :ok = Assertions.assert_visible!(screen, "12 repositories checked")
    assert Assertions.visible?(screen, "a55ist")
    assert Assertions.row(screen, 3) == "a55ist  dirty"
    assert :ok = Assertions.assert_row!(screen, 1, "Repository health")

    assert_raise Assertions.AssertionError, ~r/expected terminal to show/, fn ->
      Assertions.assert_visible!(screen, "all clean")
    end
  end

  test "fake transport exposes deterministic input resize and stop interactions" do
    assert {:ok, session} = FakeTerminalTransport.start([])
    assert :ok = FakeTerminalTransport.input(session, "r")
    assert_receive {:fake_terminal_input, ^session, "r"}

    assert :ok = FakeTerminalTransport.resize(session, 30, 100)
    assert_receive {:fake_terminal_resize, ^session, 30, 100}

    assert :ok = FakeTerminalTransport.stop(session, :done)
    assert_receive {:fake_terminal_stop, ^session, :done}
  end
end
