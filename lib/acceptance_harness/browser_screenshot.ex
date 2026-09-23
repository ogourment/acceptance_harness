defmodule AcceptanceHarness.BrowserScreenshot do
  @moduledoc """
  Adds a narrow retry around transient Chromium screenshot protocol failures.

  The caller supplies its browser driver's screenshot function, keeping this
  module independent of any particular Playwright wrapper.
  """

  require Logger

  @default_attempts 2
  @default_delay_ms 200

  def capture(conn, name, screenshot_fun, opts \\ [])
      when is_function(screenshot_fun, 2) do
    attempts = Keyword.get(opts, :attempts, @default_attempts)
    delay_ms = Keyword.get(opts, :delay_ms, @default_delay_ms)
    sleeper = Keyword.get(opts, :sleeper, &Process.sleep/1)

    do_capture(conn, name, screenshot_fun, attempts, delay_ms, sleeper)
  end

  def transient_capture_error?(error) do
    message = Exception.message(error)

    String.contains?(message, "Page.captureScreenshot") &&
      String.contains?(message, "Unable to capture screenshot")
  end

  defp do_capture(conn, name, screenshot_fun, attempts, delay_ms, sleeper) do
    screenshot_fun.(conn, name)
  rescue
    error ->
      if attempts > 1 && transient_capture_error?(error) do
        Logger.warning(
          "Chromium temporarily could not capture acceptance screenshot; retrying",
          screenshot: name,
          attempts_remaining: attempts - 1
        )

        sleeper.(delay_ms)
        do_capture(conn, name, screenshot_fun, attempts - 1, delay_ms, sleeper)
      else
        reraise error, __STACKTRACE__
      end
  end
end
