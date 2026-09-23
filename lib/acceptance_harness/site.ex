defmodule AcceptanceHarness.Site do
  @moduledoc """
  Builds a static ATDD evidence site from the generated markdown and screenshots.
  """

  @screenshot_preview_script_path Path.expand(
                                    "../../priv/acceptance_harness/screenshot_preview.js",
                                    __DIR__
                                  )
  @external_resource @screenshot_preview_script_path
  @screenshot_preview_script File.read!(@screenshot_preview_script_path)

  @doc "Returns the shared screenshot-preview behavior for embedded review surfaces."
  def screenshot_preview_script, do: @screenshot_preview_script

  def build!(source_dir, output_dir) do
    report_path = report_path(source_dir)
    screenshots_source = Path.join(source_dir, "screenshots")
    screenshots_output = Path.join(output_dir, "screenshots")

    File.rm_rf!(output_dir)
    File.mkdir_p!(output_dir)

    markdown = File.read!(report_path)
    html = render_page(markdown)

    File.write!(Path.join(output_dir, "index.html"), html)
    File.cp!(report_path, Path.join(output_dir, "e2e.md"))
    File.cp!(report_path, Path.join(output_dir, "journeys.md"))
    evidence_path = Path.join(source_dir, "evidence.json")
    copy_if_exists(evidence_path, Path.join(output_dir, "evidence.json"))
    copy_declared_artifacts(source_dir, output_dir, evidence_path)

    if File.dir?(screenshots_source) do
      File.cp_r!(screenshots_source, screenshots_output)
    end

    :ok
  end

  defp report_path(source_dir) do
    e2e_path = Path.join(source_dir, "e2e.md")
    legacy_path = Path.join(source_dir, "journeys.md")

    cond do
      File.exists?(e2e_path) -> e2e_path
      File.exists?(legacy_path) -> legacy_path
      true -> raise File.Error, action: "read file", path: e2e_path, reason: :enoent
    end
  end

  defp copy_if_exists(source, destination) do
    if File.exists?(source) do
      File.cp!(source, destination)
    end
  end

  defp copy_declared_artifacts(source_dir, output_dir, evidence_path) do
    if File.regular?(evidence_path) do
      evidence_path
      |> File.read!()
      |> Jason.decode!()
      |> artifact_paths()
      |> Enum.each(&copy_artifact!(source_dir, output_dir, &1))
    end
  end

  defp artifact_paths(evidence) do
    run_artifacts = Map.get(evidence, "artifacts", [])

    step_artifacts =
      evidence
      |> Map.get("scenarios", [])
      |> Enum.flat_map(&Map.get(&1, "steps", []))
      |> Enum.flat_map(&Map.get(&1, "artifacts", []))

    (run_artifacts ++ step_artifacts)
    |> Enum.map(&Map.get(&1, "path"))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp copy_artifact!(source_dir, output_dir, relative_path) do
    source_root = Path.expand(source_dir)
    output_root = Path.expand(output_dir)
    source = Path.expand(relative_path, source_root)
    destination = Path.expand(relative_path, output_root)

    unless within?(source, source_root) and within?(destination, output_root) do
      raise ArgumentError,
            "artifact path must stay within the evidence directory: #{relative_path}"
    end

    reject_symlinked_artifact!(source_root, relative_path)

    if File.regular?(source) do
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(source, destination)
    end
  end

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp reject_symlinked_artifact!(source_root, relative_path) do
    relative_path
    |> Path.split()
    |> Enum.reduce(source_root, fn segment, parent ->
      path = Path.join(parent, segment)

      if match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path)) do
        raise ArgumentError, "artifact path must not contain symlinks: #{relative_path}"
      end

      path
    end)
  end

  defp render_page(markdown) do
    body =
      markdown
      |> AcceptanceHarness.Markdown.to_html()
      |> link_screenshots()
      |> add_heading_ids()

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{AcceptanceHarness.Config.site_title()}</title>
        <style>
          :root {
            color-scheme: dark;
            font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            background: #061019;
            color: #eef8ff;
          }

          body {
            margin: 0;
            background: linear-gradient(180deg, #081827, #040a11);
          }

          main {
            box-sizing: border-box;
            margin: 0 auto;
            max-width: none;
            min-height: 100vh;
            padding: clamp(1rem, 3vw, 2.5rem);
            width: 100%;
          }

          article {
            border: 1px solid rgb(49 209 224 / 26%);
            border-radius: 8px;
            box-shadow: 0 24px 70px rgb(0 0 0 / 30%);
            padding: clamp(1rem, 3vw, 2rem);
          }

          nav.contents {
            background: rgb(15 23 42 / 68%);
            border: 1px solid rgb(103 232 249 / 18%);
            border-radius: 8px;
            margin: 0 0 1.5rem;
            padding: 1rem;
          }

          nav.contents h2 {
            border-top: 0;
            font-size: 1rem;
            margin: 0 0 0.6rem;
            padding-top: 0;
          }

          nav.contents ul {
            margin: 0;
            padding-left: 1.1rem;
          }

          ol {
            display: grid;
            gap: 0.35rem;
            margin: 0.75rem 0 1.25rem;
            padding-left: 1.6rem;
          }

          li {
            color: #c8d8e5;
            line-height: 1.55;
            margin: 0.25rem 0;
          }

          h1, h2, h3 {
            font-weight: 600;
            line-height: 1.1;
          }

          h1 {
            font-size: clamp(2rem, 6vw, 3.5rem);
            margin: 0 0 1rem;
          }

          h2 {
            border-top: 1px solid rgb(148 163 184 / 18%);
            font-size: clamp(1.35rem, 4vw, 2rem);
            margin: 2rem 0 0.8rem;
            padding-top: 1.4rem;
          }

          p {
            color: #c8d8e5;
            line-height: 1.55;
            max-width: 72ch;
          }

          img {
            background: #0b1622;
            border: 1px solid rgb(148 163 184 / 20%);
            border-radius: 8px;
            box-sizing: border-box;
            display: block;
            height: auto;
            margin: 1rem 0 1.6rem;
            max-width: 100%;
          }

          .screenshot-thumb {
            cursor: zoom-in;
            display: inline-block;
            text-decoration: none;
          }

          .screenshot-thumb:focus-visible {
            border-radius: 8px;
            outline: 3px solid #67e8f9;
            outline-offset: 3px;
          }

          .screenshot-review-message {
            color: #eef8ff;
            display: block;
            font-weight: 700;
            margin: 0.65rem 0 0.35rem;
          }

          .presentation-entry {
            align-items: center;
            background: rgb(8 47 73 / 84%);
            border: 1px solid #67e8f9;
            border-radius: 8px;
            color: #eef8ff;
            cursor: pointer;
            display: inline-flex;
            font: inherit;
            font-weight: 800;
            gap: 0.5rem;
            margin: 0 0 1.5rem;
            padding: 0.7rem 1rem;
          }

          .failure-screenshot {
            background: rgb(127 29 29 / 24%);
            margin: 1rem 0 1.6rem;
            padding: 0;
          }

          .failure-screenshot .screenshot-thumb {
            display: block;
          }

          .failure-screenshot img {
            border: 5px solid #f87171;
            box-shadow: 0 0 0 4px rgb(127 29 29 / 50%);
            margin: 0;
          }

          .screenshot-dialog {
            background: #020617;
            border: 1px solid rgb(103 232 249 / 42%);
            border-radius: 8px;
            box-shadow: 0 30px 90px rgb(0 0 0 / 70%);
            color: #eef8ff;
            height: 94vh;
            max-height: 94vh;
            max-width: 94vw;
            padding: 0;
            width: 94vw;
          }

          .screenshot-dialog::backdrop {
            background: rgb(2 6 23 / 82%);
          }

          .screenshot-dialog-layout {
            display: grid;
            grid-template-rows: auto minmax(0, 1fr);
            height: 100%;
          }

          .screenshot-dialog-viewport {
            align-items: flex-start;
            background: #0b1622;
            display: flex;
            justify-content: flex-start;
            overflow: auto;
            padding: 1rem;
          }

          .screenshot-dialog img {
            border: 0;
            border-radius: 0;
            margin: 0;
            max-height: none;
            max-width: none;
            width: auto;
          }

          .screenshot-dialog-toolbar {
            align-items: center;
            background: rgb(2 6 23 / 92%);
            display: flex;
            flex-wrap: wrap;
            gap: 1rem;
            justify-content: space-between;
            padding: 0.7rem 0.9rem;
          }

          .screenshot-dialog-heading {
            flex: 1 1 28rem;
          }

          .screenshot-dialog-title {
            color: #eef8ff;
            display: block;
            font-size: 1.05rem;
            font-weight: 800;
          }

          .screenshot-dialog-context {
            color: #c8d8e5;
            display: block;
            font-size: 0.85rem;
            font-weight: 500;
            margin-top: 0.25rem;
          }

          .screenshot-dialog-message {
            flex: 1 1 28rem;
            font-weight: 700;
          }

          .screenshot-dialog-actions,
          .screenshot-dialog-zoom {
            align-items: center;
            display: flex;
            gap: 0.5rem;
          }

          .screenshot-dialog-fit-modes {
            align-items: center;
            border: 0;
            display: flex;
            gap: 0.65rem;
            margin: 0;
            padding: 0;
          }

          .screenshot-dialog-fit-modes legend {
            color: #c8d8e5;
            float: left;
            font-size: 0.75rem;
            margin-right: 0.15rem;
          }

          .screenshot-dialog-fit-modes label {
            align-items: center;
            cursor: pointer;
            display: flex;
            font-size: 0.82rem;
            font-weight: 700;
            gap: 0.25rem;
          }

          #screenshot-dialog-zoom-level {
            min-width: 3.5rem;
            text-align: center;
          }

          .screenshot-dialog button {
            background: #67e8f9;
            border: 0;
            border-radius: 6px;
            color: #082f49;
            cursor: pointer;
            font: inherit;
            font-weight: 700;
            padding: 0.35rem 0.65rem;
          }

          .screenshot-dialog button:focus-visible,
          .screenshot-dialog a:focus-visible {
            outline: 3px solid #fbbf24;
            outline-offset: 2px;
          }

          a {
            color: #67e8f9;
          }

          code {
            background: rgb(255 255 255 / 8%);
            border-radius: 4px;
            padding: 0.1rem 0.3rem;
          }

          .inline-help {
            color: #67e8f9;
            cursor: help;
            display: inline-block;
            font-weight: 700;
            margin-left: 0.15rem;
            text-decoration: none;
          }

          table {
            border-collapse: collapse;
            margin: 1rem 0 1.5rem;
            max-width: none;
            width: max-content;
          }

          th, td {
            border: 1px solid rgb(148 163 184 / 20%);
            padding: 0.6rem 0.75rem;
            text-align: left;
            vertical-align: top;
          }

          td img {
            margin: 0.25rem 0;
            max-width: clamp(220px, 18vw, 340px);
          }

          th {
            background: rgb(15 23 42 / 68%);
            color: #eef8ff;
          }
        </style>
      </head>
      <body>
        <main>
          <article>
            <button type="button" class="presentation-entry" id="screenshot-presentation-start">
              ▶ Start presentation
            </button>
            #{body}
          </article>
          <dialog class="screenshot-dialog" id="screenshot-dialog" aria-label="Screenshot preview">
            <div class="screenshot-dialog-layout">
              <div class="screenshot-dialog-toolbar">
                <button type="button" id="screenshot-dialog-previous">← Previous</button>
                <span id="screenshot-dialog-counter" aria-live="polite"></span>
                <span class="screenshot-dialog-heading">
                  <span class="screenshot-dialog-title" id="screenshot-dialog-title"></span>
                  <span class="screenshot-dialog-context" id="screenshot-dialog-context"></span>
                </span>
                <span class="screenshot-dialog-message" id="screenshot-dialog-message"></span>
                <div class="screenshot-dialog-zoom" aria-label="Image zoom controls">
                  <button type="button" id="screenshot-dialog-zoom-out" aria-label="Zoom out">−</button>
                  <span id="screenshot-dialog-zoom-level" aria-live="polite">100%</span>
                  <button type="button" id="screenshot-dialog-zoom-in" aria-label="Zoom in">+</button>
                  <fieldset class="screenshot-dialog-fit-modes">
                    <legend>Default fit</legend>
                    <label>
                      <input type="radio" name="screenshot-dialog-fit" value="width">
                      Fit width
                    </label>
                    <label>
                      <input type="radio" name="screenshot-dialog-fit" value="window" checked>
                      Fit window
                    </label>
                  </fieldset>
                </div>
                <div class="screenshot-dialog-actions">
                  <a id="screenshot-dialog-original" href="#" target="_blank" rel="noopener">Open original</a>
                  <button type="button" id="screenshot-dialog-close">Close</button>
                </div>
                <button type="button" id="screenshot-dialog-next">Next →</button>
              </div>
              <div class="screenshot-dialog-viewport" id="screenshot-dialog-viewport">
                <img id="screenshot-dialog-image" alt="">
              </div>
            </div>
          </dialog>
        </main>
        <script>
          (() => {
            const dialog = document.getElementById("screenshot-dialog");
            const image = document.getElementById("screenshot-dialog-image");
            const startPresentation = document.getElementById("screenshot-presentation-start");
            const title = document.getElementById("screenshot-dialog-title");
            const context = document.getElementById("screenshot-dialog-context");
            const message = document.getElementById("screenshot-dialog-message");
            const previous = document.getElementById("screenshot-dialog-previous");
            const next = document.getElementById("screenshot-dialog-next");
            const counter = document.getElementById("screenshot-dialog-counter");
            const close = document.getElementById("screenshot-dialog-close");
            const viewport = document.getElementById("screenshot-dialog-viewport");
            const zoomOut = document.getElementById("screenshot-dialog-zoom-out");
            const zoomIn = document.getElementById("screenshot-dialog-zoom-in");
            const zoomFitModes = Array.from(
              document.querySelectorAll('input[name="screenshot-dialog-fit"]')
            );
            const zoomLevel = document.getElementById("screenshot-dialog-zoom-level");
            const original = document.getElementById("screenshot-dialog-original");

            if (!dialog || !image || !startPresentation || !title || !context || !message ||
                !previous || !next || !counter || !close ||
                !viewport || !zoomOut || !zoomIn ||
                zoomFitModes.length !== 2 || !zoomLevel || !original ||
                typeof dialog.showModal !== "function") {
              return;
            }

            let zoom = 1;
            let currentScreenshot = 0;
            const allScreenshotLinks = Array.from(document.querySelectorAll("a.screenshot-thumb"));
            const screenshotLinks = Array.from(
              allScreenshotLinks.reduce((links, link) => links.set(link.href, link), new Map()).values()
            );

            const precedingElements = (link, selector) =>
              Array.from(document.querySelectorAll(selector)).filter((element) =>
                Boolean(element.compareDocumentPosition(link) & Node.DOCUMENT_POSITION_FOLLOWING)
              );

            const slideMetadata = (link) => {
              const heading = precedingElements(link, "h2, h3, h4").at(-1);
              const paragraphs = precedingElements(link, "p, blockquote")
                .filter((element) =>
                  !heading || Boolean(heading.compareDocumentPosition(element) & Node.DOCUMENT_POSITION_FOLLOWING)
                )
                .map((element) => element.textContent.trim())
                .filter(Boolean);
              const reviewMessage = paragraphs[0] || link.dataset.reviewMessage || link.dataset.alt || link.href;

              return {
                title: heading?.textContent.trim() || link.dataset.alt || "Evidence",
                reviewMessage,
                context: paragraphs.slice(1, 4).join(" · ")
              };
            };

            allScreenshotLinks.forEach((link) => {
              const metadata = slideMetadata(link);
              link.dataset.reviewMessage = metadata.reviewMessage;
              const visibleMessage = link.previousElementSibling;
              if (visibleMessage?.classList.contains("screenshot-review-message")) {
                visibleMessage.textContent = metadata.reviewMessage;
              }
            });

            startPresentation.hidden = screenshotLinks.length === 0;
            const applyZoom = (nextZoom) => {
              if (!image.naturalWidth || !image.naturalHeight) return;
              zoom = Math.max(0.05, Math.min(4, nextZoom));
              image.style.width = `${Math.round(image.naturalWidth * zoom)}px`;
              image.style.height = `${Math.round(image.naturalHeight * zoom)}px`;
              zoomLevel.textContent = `${Math.round(zoom * 100)}%`;
              zoomOut.disabled = zoom <= 0.05;
              zoomIn.disabled = zoom >= 4;
            };

            const resetViewport = () => viewport.scrollTo(0, 0);

            const fitWidth = () => {
              if (!image.naturalWidth) return;
              const availableWidth = Math.max(1, viewport.clientWidth - 32);
              applyZoom(availableWidth / image.naturalWidth);
              resetViewport();
            };

            const fitWindow = () => {
              if (!image.naturalWidth || !image.naturalHeight) return;
              const availableWidth = Math.max(1, viewport.clientWidth - 32);
              const availableHeight = Math.max(1, viewport.clientHeight - 32);
              const fitZoom = Math.min(
                1,
                availableWidth / image.naturalWidth,
                availableHeight / image.naturalHeight
              );
              applyZoom(fitZoom);
              resetViewport();
            };

            const selectedFitMode = () =>
              zoomFitModes.find((input) => input.checked)?.value || "window";

            const applyFitMode = () => {
              if (selectedFitMode() === "width") fitWidth();
              else fitWindow();
            };

            image.addEventListener("load", applyFitMode);
            zoomOut.addEventListener("click", () => applyZoom(zoom / 1.25));
            zoomIn.addEventListener("click", () => applyZoom(zoom * 1.25));
            zoomFitModes.forEach((input) => input.addEventListener("change", applyFitMode));

            const showScreenshot = (index) => {
              if (screenshotLinks.length === 0) return;
              currentScreenshot = (index + screenshotLinks.length) % screenshotLinks.length;
              const link = screenshotLinks[currentScreenshot];
              const metadata = slideMetadata(link);
              image.src = link.href;
              image.alt = link.dataset.alt || "";
              title.textContent = metadata.title;
              context.textContent = metadata.context;
              context.hidden = metadata.context === "";
              message.textContent = metadata.reviewMessage;
              counter.textContent = `${currentScreenshot + 1} / ${screenshotLinks.length}`;
              original.href = link.href;
              if (!dialog.open) dialog.showModal();
              if (image.complete) applyFitMode();
            };

            allScreenshotLinks.forEach((link) => {
              link.addEventListener("click", (event) => {
                event.preventDefault();
                const index = screenshotLinks.findIndex((candidate) => candidate.href === link.href);
                showScreenshot(index);
              });
            });

            startPresentation.addEventListener("click", () => showScreenshot(0));

            previous.addEventListener("click", () => showScreenshot(currentScreenshot - 1));
            next.addEventListener("click", () => showScreenshot(currentScreenshot + 1));

            document.addEventListener("keydown", (event) => {
              if (!dialog.open) return;
              if (event.key === "ArrowLeft") showScreenshot(currentScreenshot - 1);
              if (event.key === "ArrowRight") showScreenshot(currentScreenshot + 1);
            });

            close.addEventListener("click", () => dialog.close());

            dialog.addEventListener("click", (event) => {
              if (event.target === dialog) {
                dialog.close();
              }
            });
          })();
        </script>
      </body>
    </html>
    """
  end

  defp link_screenshots(html) do
    Regex.replace(~r/<img src="([^"]+)" alt="([^"]*)">/, html, fn match, src, alt ->
      if String.starts_with?(src, "screenshots/") do
        ~s(<span class="screenshot-review-message">#{alt}</span><a class="screenshot-thumb" href="#{src}" target="_blank" data-alt="#{alt}" data-review-message="#{alt}" title="Open screenshot preview">#{match}</a>)
      else
        match
      end
    end)
  end

  defp add_heading_ids(html) do
    Regex.replace(~r/<h2>(.*?)<\/h2>/, html, fn _match, title ->
      ~s(<h2 id="#{heading_id(title)}">#{title}</h2>)
    end)
  end

  defp heading_id(title) do
    title
    |> strip_tags()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9 -]/, "")
    |> String.replace(~r/\s+/, "-")
  end

  defp strip_tags(html), do: Regex.replace(~r/<[^>]*>/, html, "")
end
