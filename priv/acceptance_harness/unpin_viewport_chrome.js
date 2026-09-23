() => {
  for (const element of document.querySelectorAll('[data-acceptance-pinned-position]')) {
    element.style.position = element.dataset.acceptancePinnedPosition;
    delete element.dataset.acceptancePinnedPosition;
  }
  const root = document.documentElement;
  root.style.scrollBehavior = root.dataset.acceptancePinnedScrollBehavior || '';
  delete root.dataset.acceptancePinnedScrollBehavior;
  return true;
}
