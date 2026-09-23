defmodule AcceptanceHarnessWeb.AdminAssets do
  @moduledoc false
  use Phoenix.Component

  @admin_css_path Path.expand("../../priv/acceptance_harness/admin.css", __DIR__)
  @external_resource @admin_css_path
  @admin_css File.read!(@admin_css_path)
  @screenshot_preview_script AcceptanceHarness.Site.screenshot_preview_script()

  @review_script_path Path.expand("../../priv/acceptance_harness/review_activity.js", __DIR__)
  @external_resource @review_script_path
  @review_script File.read!(@review_script_path)

  def review_activity(assigns) do
    assigns = assign(assigns, :script, @review_script)

    ~H"""
    <script id="acceptance-review-activity-script" phx-update="ignore"><%= Phoenix.HTML.raw(@script) %></script>
    """
  end

  def styles(assigns) do
    assigns = assign(assigns, :admin_css, @admin_css)

    ~H"""
    <style id="acceptance-harness-admin-styles" phx-update="ignore"><%= Phoenix.HTML.raw(@admin_css) %></style>
    """
  end

  def screenshot_preview(assigns) do
    assigns = assign(assigns, :script, @screenshot_preview_script)

    ~H"""
    <div id="acceptance-screenshot-preview" phx-update="ignore">
      <dialog class="acceptance-preview-dialog" aria-label="Screenshot preview">
        <div class="acceptance-preview-layout">
          <div class="acceptance-preview-toolbar">
            <button type="button" data-preview-previous>← Previous</button>
            <span data-preview-counter aria-live="polite"></span>
            <span class="acceptance-preview-heading">
              <strong data-preview-title></strong>
              <span data-preview-context></span>
            </span>
            <div class="acceptance-preview-zoom" aria-label="Image zoom controls">
              <button type="button" data-preview-zoom-out aria-label="Zoom out">−</button>
              <span data-preview-zoom-level aria-live="polite">100%</span>
              <button type="button" data-preview-zoom-in aria-label="Zoom in">+</button>
              <fieldset>
                <legend>Default fit</legend>
                <label><input type="radio" name="acceptance-preview-fit" value="width" /> Fit width</label>
                <label><input type="radio" name="acceptance-preview-fit" value="window" checked /> Fit window</label>
              </fieldset>
            </div>
            <div class="acceptance-preview-actions">
              <a data-preview-original href="#" target="_blank" rel="noopener">Clean original</a>
              <button type="button" data-preview-close>Close</button>
            </div>
            <button type="button" data-preview-next>Next →</button>
          </div>
          <div class="acceptance-preview-viewport" data-preview-viewport>
            <img data-preview-image alt="" />
          </div>
        </div>
      </dialog>
      <script id="acceptance-harness-screenshot-preview-script"><%= Phoenix.HTML.raw(@script) %></script>
    </div>
    """
  end
end
