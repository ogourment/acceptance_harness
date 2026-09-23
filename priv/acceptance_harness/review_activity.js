(() => {
  if (window.acceptanceReviewActivity) return;
  window.acceptanceReviewActivity = true;
  const pending = new WeakMap(), sent = new WeakMap(), retryAt = new WeakMap(), inFlight = new WeakSet();
  function session(touch = false) {
    const key = 'acceptance-review-session';
    const now = Date.now();
    let state;
    try { state = JSON.parse(sessionStorage.getItem(key)); } catch (_) {}
    if (!state || now - state.last > 1800000) {
      state = {last: now, id: Array.from(crypto.getRandomValues(new Uint8Array(24)), x => x.toString(16).padStart(2,'0')).join('')};
    }
    if (touch) state.last = now;
    sessionStorage.setItem(key, JSON.stringify(state));
    return state.id;
  }
  function params(el) {
    const scope = el.closest('[data-review-run]');
    const data = {run_id: scope.dataset.reviewRun};
    if (scope.dataset.reviewScenario) data.scenario_id = scope.dataset.reviewScenario;
    if (el.dataset.acceptanceStepId) data.step_id = el.dataset.acceptanceStepId;
    return data;
  }
  function status(el, text) {
    let label = el.querySelector(':scope > [data-review-count]');
    if (!label) { label = document.createElement('p'); label.dataset.reviewCount = ''; label.className='acceptance-review-count'; el.prepend(label); }
    if (label.textContent !== text) label.textContent = text;
  }
  async function request(el, record) {
    if (inFlight.has(el)) return;
    inFlight.add(el);
    const scope = el.closest('[data-review-run]');
    const endpoint = scope.dataset.reviewEndpoint;
    try {
      const data = params(el);
      const sessionId = record ? session(true) : null;
      const response = record ? await fetch(endpoint, {
        method:'POST', credentials:'same-origin', headers:{'Content-Type':'application/json','Accept':'text/html',
          'x-csrf-token':document.querySelector('meta[name="csrf-token"]')?.content || ''},
        body:JSON.stringify({...data, session:sessionId, source:navigator.webdriver ? 'automated':'human'})
      }) : await fetch(endpoint+'?'+new URLSearchParams(data), {credentials:'same-origin',headers:{'Accept':'text/html'}});
      if (!response.ok) throw new Error('unavailable');
      const result = await response.json();
      const origins = Object.entries(result.environments).map(([env,n])=>`${env} ${n}`).join(' · ');
      const state = result.state === 'changed_unreviewed' ? 'Changed since human review' : result.reads ? 'Current revision viewed' : 'No recorded human review';
      status(el, `${state} · ${result.reads} cumulative reads${origins ? ' · '+origins:''} · ${result.automated} automated`);
      if(record) sent.set(el,sessionId);
    } catch (_) { retryAt.set(el,Date.now()+30000); status(el,'Review tracking incomplete — evidence remains available'); }
    finally { inFlight.delete(el); if(!record) scan(); }
  }
  function visible(el) {
    const preview = document.querySelector('#acceptance-screenshot-preview dialog[open]');
    const link = el.querySelector('.acceptance-screenshot-link');
    if (preview) {
      const image = preview.querySelector('[data-preview-image]');
      return !document.hidden && Boolean(link) && preview.dataset.reviewStepId === el.dataset.acceptanceStepId && image?.complete && image.naturalWidth > 0;
    }
    const heading = el.querySelector('h2,h1') || el;
    const r=heading.getBoundingClientRect();
    const evidence = el.querySelector('.acceptance-screenshot-link, iframe, .acceptance-terminal-evidence');
    const imageRect = evidence?.getBoundingClientRect();
    const image = evidence?.querySelector('img');
    const evidenceVisible = !evidence || (imageRect.bottom > 0 && imageRect.top < innerHeight && (!image || (image.complete && image.naturalWidth > 0)));
    return !document.hidden && r.top >= 0 && r.bottom <= innerHeight && evidenceVisible;
  }
  function scan() {
    let sessionId;
    try { sessionId = session(); } catch (_) {
      document.querySelectorAll('[data-review-run] [data-review-target], [data-review-run] .acceptance-step').forEach(el => status(el,'Review tracking incomplete — browser session storage unavailable'));
      return;
    }
    document.querySelectorAll('[data-review-run] [data-review-target], [data-review-run] .acceptance-step').forEach(el=>{
      if (!el.dataset.reviewInitialized) { el.dataset.reviewInitialized='true'; request(el,false); }
      if(sent.get(el) === sessionId || inFlight.has(el) || Date.now() < (retryAt.get(el)||0)) return;
      if(!visible(el)) { clearTimeout(pending.get(el)); pending.delete(el); return; }
      if(!pending.has(el)) pending.set(el,setTimeout(()=>{
        pending.delete(el); if(visible(el)) request(el,true);
      },1000));
    });
  }
  function activity() { try { session(true); } catch (_) {} scan(); }
  document.addEventListener('scroll',activity,true);
  document.addEventListener('pointerdown',activity,true);
  document.addEventListener('keydown',activity,true);
  document.addEventListener('visibilitychange',scan);
  document.addEventListener('load',scan,true);
  window.addEventListener('resize',scan);
  new MutationObserver(scan).observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['open','src','data-review-step-id']});
  scan();
})();
