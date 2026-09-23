defmodule AcceptanceHarnessConsumerWeb.ReviewerCurrentEvidenceATDDTest do
  use AcceptanceHarness.Playwright.ATDDCase,
    async: false

  alias AcceptanceHarness.{AdminStore, BrowserEvidence, BrowserScreenshot, Evidence}
  alias AcceptanceHarnessConsumer.Repo

  @scenario %{
    id: "reviewer-inspects-imported-evidence",
    title: "Reviewer inspects imported acceptance evidence",
    metadata: %{role: "application owner/reviewer", tags: ["acceptance", "evidence-review"]}
  }

  setup do
    sandbox_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(sandbox_owner) end)

    source_dir =
      Path.join(
        System.tmp_dir!(),
        "acceptance-harness-reviewer-baseline-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(source_dir)
    File.write!(Path.join(source_dir, ".acceptance-harness-owned"), "reviewer baseline fixture\n")

    File.write!(
      Path.join(source_dir, "manifest.json"),
      Jason.encode!(%{
        purpose: "isolated imported fixture for AcceptanceHarness evidence-review navigation",
        run_kind: "harness review UI fixture, not product E2E evidence"
      })
    )

    run_id = "reviewer-current-evidence-#{System.system_time(:microsecond)}"

    prepare_owned_evidence_root!()

    Evidence.reset!("AcceptanceHarness imported evidence review", [@scenario], %{
      "browser" => "Chromium",
      "platform" => "Linux",
      "viewport" => "1280x720",
      "touch_points" => 0
    })

    mark_owned_evidence_root!()

    on_exit(fn -> remove_owned_fixture!(source_dir) end)
    {:ok, run_id: run_id, source_dir: source_dir}
  end

  @tag :atdd
  test "reviewer follows and inspects imported acceptance evidence", %{
    conn: conn,
    run_id: run_id,
    source_dir: source_dir
  } do
    login_url = url("/test/atdd/login")

    conn =
      conn
      |> visit(login_url)
      |> assert_has("h1", text: "ATDD reviewer sign in")
      |> assert_has("a", text: "Continue as isolated reviewer")
      |> capture_step(
        "01-fixture-login.png",
        "Open the isolated reviewer fixture login",
        "The local ATDD fixture identifies that it creates no external account before the reviewer enters Review runs.",
        "GET /test/atdd/login"
      )

    import_review_fixture!(run_id, source_dir)

    conn
    |> click_link("Continue as isolated reviewer")
    |> assert_has("h1", text: "Review runs")
    |> assert_has(".phx-connected")
    |> assert_has("a", text: "Imported acceptance evidence")
    |> capture_step(
      "02-reports-entry.png",
      "Open Review runs",
      "The connected LiveView reports entry shows the isolated imported evidence run after fixture sign in.",
      "Click fixture link: Continue as isolated reviewer"
    )
    |> assert_browser_state!("/admin/acceptance", run_id)
    |> add_reports_evidence!(run_id, source_dir)
    |> click("a[href='/admin/acceptance/runs/#{run_id}']")
    |> assert_has("h1", text: "Imported acceptance evidence")
    |> assert_has("label", text: "Search")
    |> assert_has("article.acceptance-scenario-card h2 a",
      text: "Reviewer inspects imported acceptance evidence"
    )
    |> assert_has(".acceptance-step-thumbnail")
    |> capture_step(
      "03-run-evidence.png",
      "Open the imported evidence run",
      "The run preserves searchable scenario identity and screenshot navigation.",
      "Click run link: Imported acceptance evidence"
    )
    |> click_link("Reviewer inspects imported acceptance evidence")
    |> assert_has("h1", text: "Reviewer inspects imported acceptance evidence")
    |> assert_has("article#step-imported-context", text: "Imported evidence context")
    |> assert_has("article#step-reports-entry", text: "Review runs entry")
    |> assert_has(".acceptance-failure")
    |> assert_has("label", text: "Screenshot")
    |> assert_has("label", text: "Rendered page")
    |> assert_images_loaded()
    |> capture_step(
      "04-scenario-evidence.png",
      "Inspect ordered scenario evidence",
      "The scenario preserves ordered steps, failure context, screenshots and rendered-page evidence.",
      "Click scenario link: Reviewer inspects imported acceptance evidence"
    )
    |> verify_text_selection()
    |> capture_step(
      "05-text-selection.png",
      "Select evidence text",
      "Ordinary browser text selection remains usable in the review page and rendered-page surface.",
      "Select visible evidence text in the page and rendered-page preview"
    )
    |> verify_screenshot_preview()
    |> capture_step(
      "06-screenshot-preview.png",
      "Inspect a screenshot in the evidence preview",
      "The preview retains evidence identity, sequential navigation, zoom, fit, clean-original and close controls.",
      "Click the visible screenshot for Imported evidence context"
    )
    |> close_preview_and_verify_stability()

    Evidence.mark_scenario_success!(@scenario)
    Evidence.record_current_scenario_runtime(@scenario)
    Evidence.finalize!()
  end

  defp assert_browser_state!(conn, expected_path_and_query, run_id) do
    {:ok, state} =
      PlaywrightEx.Frame.evaluate(conn.frame_id,
        expression: """
        () => ({
          pathAndQuery: window.location.pathname + window.location.search,
          links: Array.from(document.querySelectorAll("a")).map(link => ({
            text: (link.textContent || "").trim(),
            href: link.getAttribute("href")
          }))
        })
        """,
        is_function: true,
        timeout: 10_000
      )

    expected_href = "/admin/acceptance/runs/#{run_id}"
    assert state["pathAndQuery"] == expected_path_and_query

    assert Enum.any?(state["links"], &(&1["href"] == expected_href)),
           "expected #{expected_href} in browser state: #{inspect(state)}"

    conn
  end

  defp capture_step(conn, screenshot_name, title, description, action) do
    snapshot = page_snapshot(conn)
    assert_snapshot_sanitized!(snapshot.html)
    html_name = Path.rootname(screenshot_name) <> ".html"
    File.write!(Path.join(screenshot_dir(), html_name), snapshot.html)

    conn = pin_viewport_chrome(conn)

    try do
      BrowserScreenshot.capture(conn, screenshot_name, fn current_conn, name ->
        screenshot(current_conn, name, full_page: true)
      end)
    after
      unpin_viewport_chrome(conn)
    end

    Evidence.record_step(screenshot_name, title, description, %{
      "scenario_id" => @scenario.id,
      "scenario" => @scenario.title,
      "step" => Path.rootname(screenshot_name),
      "current_url" => snapshot.url,
      "click_target" => action,
      "user" => "application owner/reviewer",
      "device" => "LiveView desktop",
      "theme" => "light",
      "viewport" => "1280x720",
      "language" => "en",
      "tags" => ["acceptance", "comments", "baseline"],
      "page_text" => snapshot.text,
      "page_html" => snapshot.html,
      "artifacts" => [%{"type" => "source_html", "path" => "screenshots/#{html_name}"}]
    })

    conn
  end

  defp page_snapshot(conn) do
    {:ok, value} =
      PlaywrightEx.Frame.evaluate(conn.frame_id,
        expression: sanitized_page_content_script(),
        is_function: true,
        timeout: 10_000
      )

    {:ok, url} =
      PlaywrightEx.Frame.evaluate(conn.frame_id,
        expression: "() => window.location.href",
        is_function: true,
        timeout: 10_000
      )

    %{html: value["html"], text: value["text"], url: url}
  end

  defp sanitized_page_content_script do
    page_content_script = BrowserEvidence.page_content_script()

    """
    async () => {
      const capturePage = (#{page_content_script})
      const captured = await capturePage()
      const parsed = new DOMParser().parseFromString(captured.html, "text/html")

      parsed.querySelectorAll("script").forEach(element => element.remove())
      parsed.querySelectorAll("meta[http-equiv]").forEach(element => {
        if ((element.getAttribute("http-equiv") || "").toLowerCase() === "refresh") {
          element.remove()
        }
      })

      parsed.querySelectorAll("*").forEach(element => {
        Array.from(element.attributes).forEach(attribute => {
          const name = attribute.name.toLowerCase()
          const value = attribute.value

          if (name.startsWith("on")) element.removeAttribute(attribute.name)
          if (["href", "src", "action", "formaction"].includes(name) && /^\\s*javascript:/i.test(value)) {
            element.removeAttribute(attribute.name)
          }
          if (name === "srcdoc") element.removeAttribute(attribute.name)
          if (["data-phx-session", "data-phx-static"].includes(name)) {
            element.setAttribute(attribute.name, "[redacted]")
          }
        })
      })

      parsed.querySelectorAll('meta[name="csrf-token" i]').forEach(element => {
        element.setAttribute("content", "[redacted]")
      })
      parsed.querySelectorAll('[name="_csrf_token" i]').forEach(element => {
        element.setAttribute("value", "[redacted]")
      })

      captured.html = "<!DOCTYPE html>\\n" + parsed.documentElement.outerHTML
      return captured
    }
    """
  end

  defp assert_snapshot_sanitized!(html) do
    refute html =~ ~r/<script\b/i
    refute html =~ ~r/\son[a-z]+\s*=/i
    refute html =~ ~r/(?:href|src|action|formaction)\s*=\s*["']?\s*javascript:/i
    refute html =~ ~r/\ssrcdoc\s*=/i
    refute html =~ ~r/data-phx-(?:session|static)="(?!\[redacted\])/i
    refute html =~ ~r/<meta\b(?=[^>]*name="csrf-token")(?=[^>]*content="(?!\[redacted\]))/i
    refute html =~ ~r/name="_csrf_token"(?=[^>]*value="(?!\[redacted\]))/i
  end

  defp assert_images_loaded(conn) do
    {:ok, images} =
      PlaywrightEx.Frame.evaluate(conn.frame_id,
        expression: """
        async () => {
          const images = Array.from(document.images).filter(image => image.getAttribute("src"))
          await Promise.all(images.map(image => {
            if (image.complete) return
            return new Promise(resolve => {
              image.addEventListener('load', resolve, {once: true})
              image.addEventListener('error', resolve, {once: true})
            })
          }))
          return images.map(image => ({src: image.src, width: image.naturalWidth}))
        }
        """,
        is_function: true,
        timeout: 10_000
      )

    assert images != []

    assert Enum.all?(images, &(&1["width"] > 0)),
           "expected every evidence image to load: #{inspect(images)}"

    conn
  end

  defp verify_text_selection(conn) do
    conn = click(conn, "label[for='step-reports-entry-rendered']")

    {:ok, page_selection} =
      PlaywrightEx.Frame.evaluate(conn.frame_id,
        expression: """
        () => {
          const heading = document.querySelector("#step-imported-context h2")
          const range = document.createRange()
          range.selectNodeContents(heading)
          const pageSelection = window.getSelection()
          pageSelection.removeAllRanges()
          pageSelection.addRange(range)
          return pageSelection.toString().trim()
        }
        """,
        is_function: true,
        timeout: 10_000
      )

    {:ok, rendered_page} =
      PlaywrightEx.Frame.evaluate(conn.frame_id,
        expression: """
        () => {
          const frame = document.querySelector("#step-reports-entry iframe[data-acceptance-rendered-page]")
          frame.scrollIntoView({block: "center"})
          const rect = frame.getBoundingClientRect()
          return {
            sourceContainsHeading: frame.srcdoc.includes("Review runs"),
            startX: rect.left + 18,
            startY: rect.top + 48,
            endX: rect.left + Math.min(220, rect.width - 18),
            endY: rect.top + 48
          }
        }
        """,
        is_function: true,
        timeout: 10_000
      )

    assert page_selection == "Imported evidence context"
    assert rendered_page["sourceContainsHeading"]

    {:ok, _} =
      PlaywrightEx.Page.mouse_move(conn.page_id,
        x: rendered_page["startX"],
        y: rendered_page["startY"],
        timeout: 10_000
      )

    {:ok, _} = PlaywrightEx.Page.mouse_down(conn.page_id, timeout: 10_000)

    {:ok, _} =
      PlaywrightEx.Page.mouse_move(conn.page_id,
        x: rendered_page["endX"],
        y: rendered_page["endY"],
        timeout: 10_000
      )

    {:ok, _} = PlaywrightEx.Page.mouse_up(conn.page_id, timeout: 10_000)

    conn
  end

  defp verify_screenshot_preview(conn) do
    conn
    |> click("#step-imported-context a.acceptance-screenshot-link")
    |> assert_has("dialog[open][aria-label='Screenshot preview']")
    |> assert_has("[data-preview-title]", text: "Imported evidence context")
    |> assert_has("[data-preview-counter]", text: "1 / 2")
    |> assert_has("[data-preview-previous]", text: "Previous")
    |> assert_has("[data-preview-next]", text: "Next")
    |> assert_has("[data-preview-zoom-out]")
    |> assert_has("[data-preview-zoom-in]")
    |> assert_has("label", text: "Fit width")
    |> assert_has("label", text: "Fit window")
    |> assert_has("[data-preview-original]", text: "Clean original")
    |> assert_has("[data-preview-close]", text: "Close")
    |> click("input[value='width']")
    |> click("[data-preview-zoom-in]")
    |> click("[data-preview-next]")
    |> assert_has("[data-preview-title]", text: "Review runs entry")
    |> assert_has("[data-preview-counter]", text: "2 / 2")
  end

  defp close_preview_and_verify_stability(conn) do
    conn = click(conn, "[data-preview-close]")

    {:ok, state} =
      PlaywrightEx.Frame.evaluate(conn.frame_id,
        expression: """
        () => ({
          dialogOpen: document.querySelector("#acceptance-screenshot-preview dialog").open,
          focusedStep: document.activeElement.closest(".acceptance-step")?.id,
          stepOrder: Array.from(document.querySelectorAll(".acceptance-step")).map(step => step.id),
          path: window.location.pathname
        })
        """,
        is_function: true,
        timeout: 10_000
      )

    assert state == %{
             "dialogOpen" => false,
             "focusedStep" => "step-imported-context",
             "stepOrder" => ["step-imported-context", "step-reports-entry"],
             "path" => URI.parse(current_url(conn)).path
           }

    conn
    |> visit(current_url(conn))
    |> assert_has("#step-imported-context")
    |> assert_has("#step-reports-entry")
    |> assert_has("#step-imported-context .acceptance-screenshot-link")
    |> assert_has("#step-reports-entry .acceptance-screenshot-link")
  end

  defp current_url(conn) do
    {:ok, current_url} =
      PlaywrightEx.Frame.evaluate(conn.frame_id,
        expression: "() => window.location.href",
        is_function: true,
        timeout: 10_000
      )

    current_url
  end

  defp pin_viewport_chrome(conn) do
    evaluate(conn, BrowserEvidence.pin_viewport_chrome_script(), [is_function: true], fn true ->
      :ok
    end)
  end

  defp unpin_viewport_chrome(conn) do
    evaluate(conn, BrowserEvidence.unpin_viewport_chrome_script(), [is_function: true], fn true ->
      :ok
    end)
  end

  defp screenshot_dir do
    Application.fetch_env!(:phoenix_test, :playwright)
    |> Keyword.fetch!(:screenshot_dir)
  end

  defp evidence_root do
    Application.fetch_env!(:acceptance_harness, :harness)
    |> Keyword.fetch!(:evidence_dir)
  end

  defp mark_owned_evidence_root! do
    root = evidence_root()
    File.mkdir_p!(root)
    File.write!(Path.join(root, ".acceptance-harness-owned"), "reviewer baseline evidence\n")

    File.write!(
      Path.join(root, "manifest.json"),
      Jason.encode!(%{
        purpose: "harness-owned reviewer baseline evidence",
        cleanup_boundary: root,
        external_systems: []
      })
    )
  end

  defp prepare_owned_evidence_root! do
    root = Path.expand(evidence_root())
    allowed_root = Path.expand(Path.join([__DIR__, "..", "..", "tmp", "atdd"]))

    unless String.starts_with?(root, allowed_root <> "/") do
      raise "ATDD evidence root must be a run-specific child of #{allowed_root}: #{root}"
    end

    sentinel = Path.join(root, ".acceptance-harness-owned")

    if File.dir?(root) and not File.exists?(sentinel) do
      raise "refusing to reset ATDD evidence without ownership sentinel: #{root}"
    end

    File.mkdir_p!(root)
    File.write!(sentinel, "reviewer baseline evidence\n")
  end

  defp import_review_fixture!(run_id, source_dir) do
    source_screenshot = Path.join(screenshot_dir(), "01-fixture-login.png")
    imported_screenshot = Path.join([source_dir, "screenshots", "01-fixture-login.png"])
    source_html = Path.join(screenshot_dir(), "01-fixture-login.html")
    imported_html = Path.join([source_dir, "screenshots", "01-fixture-login.html"])
    File.mkdir_p!(Path.dirname(imported_screenshot))
    File.cp!(source_screenshot, imported_screenshot)
    File.cp!(source_html, imported_html)

    AdminStore.install!(repo: Repo)

    AdminStore.import_evidence_data!(
      imported_evidence(run_id, source_dir, false),
      repo: Repo,
      source_dir: source_dir
    )
  end

  defp add_reports_evidence!(conn, run_id, source_dir) do
    for filename <- ["02-reports-entry.png", "02-reports-entry.html"] do
      File.cp!(
        Path.join(screenshot_dir(), filename),
        Path.join([source_dir, "screenshots", filename])
      )
    end

    AdminStore.import_evidence_data!(
      imported_evidence(run_id, source_dir, true),
      repo: Repo,
      source_dir: source_dir
    )

    conn
  end

  defp remove_owned_fixture!(source_dir) do
    sentinel = Path.join(source_dir, ".acceptance-harness-owned")

    if File.exists?(sentinel) do
      File.rm_rf!(source_dir)
    else
      raise "refusing to remove fixture directory without harness ownership sentinel: #{source_dir}"
    end
  end

  defp url(path), do: Application.fetch_env!(:phoenix_test, :base_url) <> path

  defp imported_evidence(run_id, source_dir, include_reports?) do
    steps = [
      %{
        "id" => "imported-context",
        "scenario_id" => @scenario.id,
        "position" => 1,
        "sequence" => 1,
        "title" => "Imported evidence context",
        "description" =>
          "The captured fixture login establishes the reviewer role and known entry point.",
        "screenshot" => %{"name" => "01-fixture-login.png"},
        "page" => %{
          "html" => File.read!(Path.join([source_dir, "screenshots", "01-fixture-login.html"])),
          "text" => "ATDD reviewer sign in Continue as isolated reviewer"
        },
        "metadata" => %{"current_url" => url("/test/atdd/login")},
        "artifacts" => [
          %{"type" => "source_html", "path" => "screenshots/01-fixture-login.html"}
        ]
      }
    ]

    steps =
      if include_reports? do
        steps ++
          [
            %{
              "id" => "reports-entry",
              "scenario_id" => @scenario.id,
              "position" => 2,
              "sequence" => 2,
              "title" => "Review runs entry",
              "description" =>
                "The reviewer follows the visible fixture control and reaches the imported run list.",
              "screenshot" => %{"name" => "02-reports-entry.png"},
              "page" => %{
                "html" =>
                  File.read!(Path.join([source_dir, "screenshots", "02-reports-entry.html"])),
                "text" => "Review runs Imported acceptance evidence"
              },
              "metadata" => %{"current_url" => url("/admin/acceptance")},
              "artifacts" => [
                %{"type" => "source_html", "path" => "screenshots/02-reports-entry.html"}
              ]
            }
          ]
      else
        steps
      end

    %{
      "title" => "Imported acceptance evidence",
      "run" => %{"id" => run_id},
      "app" => %{"name" => "AcceptanceHarness browser fixture", "commit" => "fixture"},
      "scenarios" => [
        %{
          "id" => @scenario.id,
          "title" => @scenario.title,
          "status" => "failure",
          "failure" => %{
            "message" => "Example failure context remains inspectable.",
            "code" => "assert visible evidence",
            "location" => "test/reviewer_evidence_test.exs:42",
            "screenshots" => ["02-reports-entry.png"]
          },
          "steps" => steps
        }
      ]
    }
  end
end
