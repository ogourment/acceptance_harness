defmodule AcceptanceHarness.BrowserEvidence do
  @moduledoc "Browser-side capture helpers for portable acceptance evidence."

  @doc "Returns JavaScript that captures visible text and a styled, inert DOM snapshot."
  def page_content_script do
    """
    () => {
      const capturedRules = Array.from(document.styleSheets).flatMap(sheet => {
        try {
          return Array.from(sheet.cssRules || [], rule => rule.cssText)
        } catch (_error) {
          return []
        }
      }).join("\\n")

      const documentClone = document.documentElement
        ? document.documentElement.cloneNode(true)
        : null

      if (documentClone && capturedRules) {
        const head = documentClone.querySelector("head") || documentClone
        const style = document.createElement("style")
        style.setAttribute("data-acceptance-captured-styles", "true")
        style.textContent = capturedRules
        head.appendChild(style)
      }

      return {
        text: document.body ? document.body.innerText : "",
        html: documentClone ? documentClone.outerHTML : ""
      }
    }
    """
  end

  @doc """
  Returns JavaScript that measures review-highlight selectors against the full
  document and returns normalized coordinates that remain aligned when the
  screenshot is scaled.

  The script expects an array of `%{selector: ..., label: ...}`-shaped objects.
  It never alters the page or the captured screenshot.
  """
  def review_highlight_regions_script do
    """
    (specs) => {
      const root = document.documentElement;
      const body = document.body;
      const documentWidth = Math.max(
        root?.scrollWidth || 0,
        root?.offsetWidth || 0,
        body?.scrollWidth || 0,
        body?.offsetWidth || 0
      );
      const documentHeight = Math.max(
        root?.scrollHeight || 0,
        root?.offsetHeight || 0,
        body?.scrollHeight || 0,
        body?.offsetHeight || 0
      );

      if (!documentWidth || !documentHeight) return [];

      return (specs || []).flatMap(({selector, label}) =>
        Array.from(document.querySelectorAll(selector)).map((element) => {
          const rect = element.getBoundingClientRect();
          return {
            selector,
            label,
            left_percent: ((rect.left + window.scrollX) / documentWidth) * 100,
            top_percent: ((rect.top + window.scrollY) / documentHeight) * 100,
            width_percent: (rect.width / documentWidth) * 100,
            height_percent: (rect.height / documentHeight) * 100
          };
        })
      );
    }
    """
  end

  @doc """
  Returns JavaScript that pins `position: fixed`/`sticky` elements for a
  full-page screenshot.

  Full-page captures paint fixed and sticky elements at the current scroll
  offset, which lands site headers mid-image. The script disables smooth
  scrolling, scrolls synchronously to the document top, rewrites computed
  `fixed` -> `absolute` and `sticky` ->
  `static` with `!important`, and remembers each element's original inline
  position in `data-acceptance-pinned-position` so
  `unpin_viewport_chrome_script/0` can restore it after the shot.
  """
  @pin_viewport_chrome_path Path.expand(
                              "../../priv/acceptance_harness/pin_viewport_chrome.js",
                              __DIR__
                            )
  @external_resource @pin_viewport_chrome_path
  @pin_viewport_chrome_script File.read!(@pin_viewport_chrome_path)
  def pin_viewport_chrome_script, do: @pin_viewport_chrome_script

  @doc """
  Returns JavaScript that restores elements pinned by
  `pin_viewport_chrome_script/0` to their original inline position.
  """
  @unpin_viewport_chrome_path Path.expand(
                                "../../priv/acceptance_harness/unpin_viewport_chrome.js",
                                __DIR__
                              )
  @external_resource @unpin_viewport_chrome_path
  @unpin_viewport_chrome_script File.read!(@unpin_viewport_chrome_path)
  def unpin_viewport_chrome_script, do: @unpin_viewport_chrome_script
end
