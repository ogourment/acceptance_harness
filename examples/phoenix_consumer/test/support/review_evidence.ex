defmodule AcceptanceHarnessConsumer.ReviewEvidence do
  import PhoenixTest.Playwright
  alias AcceptanceHarness.{BrowserEvidence, BrowserScreenshot, Evidence}

  def start_run!(title, scenario) do
    harness = Application.fetch_env!(:acceptance_harness, :harness)
    browser = Application.fetch_env!(:phoenix_test, :playwright)
    base = Keyword.fetch!(harness, :evidence_dir) |> Path.expand()
    allowed = Path.expand("../../tmp/atdd", __DIR__)
    unless String.starts_with?(base, allowed <> "/"), do: raise("unsafe ATDD evidence root")
    root = Path.join(base, scenario.id <> "-#{System.unique_integer([:positive])}")
    if File.exists?(root), do: raise("ATDD evidence root must be fresh")

    paths = [
      evidence_dir: root,
      screenshot_dir: Path.join(root, "screenshots"),
      trace_dir: Path.join(root, "traces")
    ]

    Application.put_env(:acceptance_harness, :harness, Keyword.merge(harness, paths))

    Application.put_env(
      :phoenix_test,
      :playwright,
      Keyword.merge(browser, Keyword.delete(paths, :evidence_dir))
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:acceptance_harness, :harness, harness)
      Application.put_env(:phoenix_test, :playwright, browser)
    end)

    Evidence.reset!(title, [scenario])
    File.write!(Path.join(root, ".acceptance-harness-owned"), "isolated reviewer evidence\n")
    root
  end

  def capture(conn, scenario, id, title, action) do
    {:ok, snapshot} =
      PlaywrightEx.Frame.evaluate(conn.frame_id,
        expression: BrowserEvidence.page_content_script(),
        is_function: true,
        timeout: 10_000
      )

    html =
      snapshot["html"]
      |> String.replace(~r/<script\b[^>]*>.*?<\/script>/is, "")
      |> String.replace(
        ~r/(data-phx-session|data-phx-static|content|value)="[^"]*"/i,
        "\\1=\"[redacted]\""
      )

    dir = Application.fetch_env!(:phoenix_test, :playwright) |> Keyword.fetch!(:screenshot_dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, id <> ".html"), html)

    evaluate(conn, BrowserEvidence.pin_viewport_chrome_script(), [is_function: true], fn true ->
      :ok
    end)

    try do
      BrowserScreenshot.capture(conn, id <> ".png", fn current, name ->
        screenshot(current, name, full_page: true)
      end)
    after
      evaluate(
        conn,
        BrowserEvidence.unpin_viewport_chrome_script(),
        [is_function: true],
        fn true -> :ok end
      )
    end

    Evidence.record_step(id <> ".png", title, action, %{
      "scenario_id" => scenario.id,
      "step" => id,
      "click_target" => action,
      "device" => "LiveView desktop",
      "theme" => "light",
      "page_html" => html,
      "page_text" => snapshot["text"],
      "artifacts" => [%{"type" => "source_html", "path" => "screenshots/#{id}.html"}]
    })

    conn
  end
end
