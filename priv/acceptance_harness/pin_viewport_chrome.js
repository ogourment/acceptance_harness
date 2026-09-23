async () => {
  const root = document.documentElement;
  root.dataset.acceptancePinnedScrollBehavior = root.style.scrollBehavior || '';
  root.style.setProperty('scroll-behavior', 'auto', 'important');
  window.scrollTo(0, 0);
  await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  window.scrollTo(0, 0);
  for (const element of document.querySelectorAll('body *')) {
    const position = getComputedStyle(element).position;
    if (position !== 'fixed' && position !== 'sticky') continue;
    element.dataset.acceptancePinnedPosition = element.style.position || '';
    element.style.setProperty(
      'position',
      position === 'fixed' ? 'absolute' : 'static',
      'important'
    );
  }
  if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
  window.scrollTo(0, 0);
  await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  window.scrollTo(0, 0);
  return window.scrollY === 0;
}
