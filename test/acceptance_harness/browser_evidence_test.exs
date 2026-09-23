defmodule AcceptanceHarness.BrowserEvidenceTest do
  use ExUnit.Case, async: true

  alias AcceptanceHarness.BrowserEvidence

  test "captures loaded stylesheet rules into the DOM snapshot" do
    script = BrowserEvidence.page_content_script()

    assert script =~ "document.styleSheets"
    assert script =~ "sheet.cssRules"
    assert script =~ "data-acceptance-captured-styles"
    assert script =~ "document.documentElement.cloneNode(true)"
    assert script =~ ~S|.join("\n")|
  end

  test "ignores stylesheets whose CSS rules cannot be read" do
    script = BrowserEvidence.page_content_script()

    assert script =~ "catch (_error)"
    assert script =~ "return []"
  end

  test "measures review selectors as scale-safe document percentages" do
    script = BrowserEvidence.review_highlight_regions_script()

    assert script =~ "document.querySelectorAll(selector)"
    assert script =~ "rect.left + window.scrollX"
    assert script =~ "rect.top + window.scrollY"
    assert script =~ "left_percent"
    assert script =~ "height_percent"
    refute script =~ "element.style"
  end

  test "pins fixed and sticky elements to the document top for screenshots" do
    script = BrowserEvidence.pin_viewport_chrome_script()

    assert script =~ "acceptancePinnedScrollBehavior"
    assert script =~ "setProperty('scroll-behavior', 'auto', 'important')"
    assert script =~ "document.activeElement.blur()"
    assert script =~ "window.scrollTo(0, 0)"
    assert script =~ "requestAnimationFrame(() => requestAnimationFrame(resolve))"
    assert length(Regex.scan(~r/window\.scrollTo\(0, 0\)/, script)) == 4
    assert script =~ "return window.scrollY === 0"
    assert script =~ "getComputedStyle(element).position"
    assert script =~ "position !== 'fixed' && position !== 'sticky'"
    assert script =~ "element.dataset.acceptancePinnedPosition = element.style.position || ''"
    assert script =~ "position === 'fixed' ? 'absolute' : 'static'"
    assert script =~ "'important'"
  end

  test "restores pinned elements to their original inline position" do
    script = BrowserEvidence.unpin_viewport_chrome_script()

    assert script =~ "[data-acceptance-pinned-position]"
    assert script =~ "element.style.position = element.dataset.acceptancePinnedPosition"
    assert script =~ "delete element.dataset.acceptancePinnedPosition"
    assert script =~ "root.style.scrollBehavior = root.dataset.acceptancePinnedScrollBehavior"
    assert script =~ "delete root.dataset.acceptancePinnedScrollBehavior"
  end
end
