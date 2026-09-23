(() => {
  const root = document.getElementById("acceptance-screenshot-preview");
  if (!root || root.dataset.initialized === "true") return;

  const dialog = root.querySelector("dialog");
  const image = root.querySelector("[data-preview-image]");
  const viewport = root.querySelector("[data-preview-viewport]");
  const title = root.querySelector("[data-preview-title]");
  const context = root.querySelector("[data-preview-context]");
  const counter = root.querySelector("[data-preview-counter]");
  const original = root.querySelector("[data-preview-original]");
  const zoomLevel = root.querySelector("[data-preview-zoom-level]");
  const zoomOut = root.querySelector("[data-preview-zoom-out]");
  const zoomIn = root.querySelector("[data-preview-zoom-in]");
  const previous = root.querySelector("[data-preview-previous]");
  const next = root.querySelector("[data-preview-next]");
  const close = root.querySelector("[data-preview-close]");
  const fitModes = Array.from(root.querySelectorAll('[name="acceptance-preview-fit"]'));

  if (!dialog || !image || !viewport || !title || !context || !counter ||
      !original || !zoomLevel || !zoomOut || !zoomIn || !previous || !next ||
      !close || fitModes.length !== 2 || typeof dialog.showModal !== "function") return;

  root.dataset.initialized = "true";
  let current = 0;
  let zoom = 1;
  let opener = null;
  let pageScrollY = 0;
  const links = () => Array.from(document.querySelectorAll(".acceptance-step a.acceptance-screenshot-link"));
  const selectedFit = () => fitModes.find((input) => input.checked)?.value || "window";
  const resetViewport = () => viewport.scrollTo(0, 0);

  const applyZoom = (value) => {
    if (!image.naturalWidth || !image.naturalHeight) return;
    zoom = Math.max(0.05, Math.min(4, value));
    image.style.width = `${Math.round(image.naturalWidth * zoom)}px`;
    image.style.height = `${Math.round(image.naturalHeight * zoom)}px`;
    zoomLevel.textContent = `${Math.round(zoom * 100)}%`;
    zoomOut.disabled = zoom <= 0.05;
    zoomIn.disabled = zoom >= 4;
  };

  const applyFit = () => {
    if (!image.naturalWidth || !image.naturalHeight) return;
    const width = Math.max(1, viewport.clientWidth - 32);
    const height = Math.max(1, viewport.clientHeight - 32);
    const value = selectedFit() === "width"
      ? width / image.naturalWidth
      : Math.min(1, width / image.naturalWidth, height / image.naturalHeight);
    applyZoom(value);
    resetViewport();
  };

  const show = (index) => {
    const available = links();
    if (available.length === 0) return;
    current = (index + available.length) % available.length;
    const link = available[current];
    const step = link.closest(".acceptance-step");
    dialog.dataset.reviewStepId = step?.dataset.acceptanceStepId || "";
    image.src = link.href;
    image.alt = link.dataset.previewTitle || link.querySelector("img")?.alt || "Evidence screenshot";
    title.textContent = link.dataset.previewTitle || image.alt;
    context.textContent = link.dataset.previewContext || step?.querySelector(".acceptance-step-position")?.textContent?.trim() || "";
    counter.textContent = `${current + 1} / ${available.length}`;
    original.href = link.href;
    if (!dialog.open) dialog.showModal();
    if (image.complete) applyFit();
  };

  const restorePage = () => {
    window.scrollTo(0, pageScrollY);
    if (opener?.isConnected) opener.focus({preventScroll: true});
  };

  document.addEventListener("click", (event) => {
    const link = event.target.closest?.("a.acceptance-screenshot-link");
    if (!link) return;
    event.preventDefault();
    opener = link;
    pageScrollY = window.scrollY;
    show(links().indexOf(link));
  });
  image.addEventListener("load", applyFit);
  zoomOut.addEventListener("click", () => applyZoom(zoom / 1.25));
  zoomIn.addEventListener("click", () => applyZoom(zoom * 1.25));
  fitModes.forEach((input) => input.addEventListener("change", applyFit));
  previous.addEventListener("click", () => show(current - 1));
  next.addEventListener("click", () => show(current + 1));
  close.addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", restorePage);
  dialog.addEventListener("click", (event) => { if (event.target === dialog) dialog.close(); });
  document.addEventListener("keydown", (event) => {
    if (!dialog.open) return;
    if (event.key === "ArrowLeft") show(current - 1);
    if (event.key === "ArrowRight") show(current + 1);
  });
})();
