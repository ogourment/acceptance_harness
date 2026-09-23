defmodule AcceptanceHarness.BrowserScreenshotTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AcceptanceHarness.BrowserScreenshot

  test "retries one transient Chromium capture failure" do
    test_pid = self()

    screenshot_fun = fn conn, name ->
      send(test_pid, {:attempt, name})

      case Process.get(:screenshot_attempt, 0) do
        0 ->
          Process.put(:screenshot_attempt, 1)

          raise MatchError,
            term:
              {:error,
               %{
                 error: %{
                   message:
                     "Protocol error (Page.captureScreenshot): Unable to capture screenshot"
                 }
               }}

        1 ->
          {:captured, conn, name}
      end
    end

    log =
      capture_log(fn ->
        assert BrowserScreenshot.capture(:conn, "step.png", screenshot_fun,
                 delay_ms: 0,
                 sleeper: fn _ -> :ok end
               ) == {:captured, :conn, "step.png"}
      end)

    assert_receive {:attempt, "step.png"}
    assert_receive {:attempt, "step.png"}
    assert log =~ "temporarily could not capture acceptance screenshot; retrying"
  end

  test "does not retry unrelated screenshot failures" do
    test_pid = self()

    screenshot_fun = fn _conn, _name ->
      send(test_pid, :attempt)
      raise "browser page is closed"
    end

    assert_raise RuntimeError, "browser page is closed", fn ->
      BrowserScreenshot.capture(:conn, "step.png", screenshot_fun,
        delay_ms: 0,
        sleeper: fn _ -> :ok end
      )
    end

    assert_receive :attempt
    refute_receive :attempt
  end
end
