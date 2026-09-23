import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import pytest

ROOT = Path(__file__).parents[2]
spec = importlib.util.spec_from_file_location('harness_review', ROOT / 'priv/preview/review_server.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def capture_page(page, artifacts, stable):
    import re
    content = page.content()
    content = re.sub(r'<script\b[^>]*>.*?</script>', '', content, flags=re.S|re.I)
    content = re.sub(r'(<meta name="csrf-token" content=")[^"]*', r'\1[redacted]', content)
    (artifacts / (stable + '.html')).write_text(content)
    scripts = ROOT / 'priv/acceptance_harness'
    page.evaluate((scripts / 'pin_viewport_chrome.js').read_text())
    try:
        page.screenshot(path=str(artifacts / (stable + '.png')), full_page=True)
    finally:
        page.evaluate((scripts / 'unpin_viewport_chrome.js').read_text())


def fixture(tmp_path):
    directory = tmp_path / 'evidence'
    directory.mkdir()
    source = directory / 'evidence.json'
    data = {'run': {'id': 'portable-run'}, 'title': 'Portable review', 'app': {'name': 'Standalone acceptance', 'commit': 'same-commit'}, 'scenarios': [{'id': 'inspect', 'title': 'Inspect evidence', 'steps': [{'id': 'first', 'sequence': 1, 'title': 'First outcome', 'description': 'A visible result', 'surface': {'kind': 'terminal', 'text': 'A meaningful result'}}, {'id': 'second', 'sequence': 2, 'title': 'Second outcome', 'description': 'Another visible result', 'surface': {'kind': 'terminal', 'text': 'Another result'}}]}]}
    source.write_text(json.dumps(data))
    return source, data


def test_sqlite_receipts_survive_promotion_without_false_revision_coverage(tmp_path):
    source, data = fixture(tmp_path)
    dev = module.Review(source, tmp_path / 'dev.sqlite3', 'dev')
    params = dict(run_id='portable-run', scenario_id='inspect', step_id='first', session='session-for-portable-human', source='human')
    assert dev.record(params)['reads'] == 1
    assert dev.record(params)['reads'] == 1
    staging = module.Review(source, tmp_path / 'staging.sqlite3', 'staging')
    assert staging.import_receipts(dev.export()) == 1
    assert staging.import_receipts(dev.export()) == 0
    assert staging.summary(staging.resolve(params))['environments'] == {'dev': 1}
    data['scenarios'][0]['steps'][0]['description'] = 'Changed result'
    source.write_text(json.dumps(data))
    assert staging.summary(staging.resolve(params))['state'] == 'changed_unreviewed'
    assert staging.summary(staging.resolve(params))['reads'] == 0
    assert staging.record(dict(params, source='automated'))['reads'] == 0
    assert staging.summary(staging.resolve(params))['automated'] == 1
    invalid = dict(dev.export()[0], project='another-project')
    with pytest.raises(ValueError):
        staging.import_receipts([invalid])
    with pytest.raises(ValueError):
        module.Review(source, source.parent / 'exposed.sqlite3', 'dev')
    with pytest.raises(ValueError):
        staging.resolve(dict(params, run_id='unknown'))


def test_portable_fingerprint_matches_json_contract():
    # Same vector is checked by Elixir, including non-ASCII and object ordering.
    assert module.fingerprint(['é', {'z': 1, 'a': ['x', None]}]) == '3e5d097d75cd30b5e6ce88d19622fa8ea150ed2805e4fbf80a60d7d9581c5c6c'


def test_browser_standalone_review_records_real_navigation_and_refresh(tmp_path):
    playwright = pytest.importorskip('playwright.sync_api')
    source, data = fixture(tmp_path)
    store = tmp_path / 'receipts.sqlite3'
    process = subprocess.Popen([str(ROOT / 'bin/acceptance-review'), str(source), '--store', str(store), '--environment', 'dev', '--port', '0'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    artifacts = Path(os.environ.get('HARNESS_STANDALONE_EVIDENCE', str(tmp_path / 'captures')))
    artifacts.mkdir(parents=True, exist_ok=True)
    steps = []
    def capture(page, stable, action, title):
        capture_page(page, artifacts, stable)
        steps.append(dict(id=stable, action=action, title=title, screenshot=stable+'.png', html=stable+'.html'))
    try:
        url = process.stdout.readline().strip().removeprefix('Review: ')
        assert url.startswith('http://127.0.0.1:')
        with playwright.sync_playwright() as pw:
            browser = pw.chromium.launch()
            context = browser.new_context(viewport={'width': 1280, 'height': 720})
            context.add_init_script("Object.defineProperty(navigator, 'webdriver', {get: () => false})")
            page = context.new_page()
            page.goto(url)
            playwright.expect(page.get_by_role('heading', name='Review runs')).to_be_visible()
            capture(page, 'OPEN-01', 'Open the printed local review URL', 'Enter standalone review')
            page.get_by_role('link', name='Portable review').click()
            playwright.expect(page.locator('[data-review-target] > [data-review-count]')).to_contain_text('1 cumulative reads', timeout=10000)
            capture(page, 'OPEN-02', 'Choose Portable review', 'Count the opened run')
            page.get_by_role('link', name='Inspect evidence').click()
            playwright.expect(page.locator('[data-review-target] > [data-review-count]')).to_contain_text('1 cumulative reads', timeout=10000)
            playwright.expect(page.locator('#step-first > [data-review-count]')).to_contain_text('1 cumulative reads', timeout=10000)
            capture(page, 'OPEN-03', 'Choose Inspect evidence and view its first outcome', 'Count visible evidence')
            page.reload()
            playwright.expect(page.locator('#step-first > [data-review-count]')).to_contain_text('1 cumulative reads')
            data['scenarios'][0]['title'] = 'Inspect revised evidence'
            source.write_text(json.dumps(data))
            playwright.expect(page.get_by_role('heading', name='Inspect revised evidence', exact=True)).to_be_visible(timeout=10000)
            capture(page, 'OPEN-04', 'Edit the same manifest while the viewer stays open', 'Refresh the canonical page automatically')
            page.get_by_role('button', name='Close preview and stop live preview server').click()
            playwright.expect(page.get_by_text('Preview closed. You can close this tab.')).to_be_visible()
            capture(page, 'OPEN-05', 'Close preview', 'Stop the standalone server')
            browser.close()
        assert process.wait(timeout=10) == 0
        receipts = module.Review(source, store, 'dev').export()
        assert any(r['target'] == 'step/inspect/first' and r['source'] == 'human' for r in receipts)
        (artifacts / 'journey.json').write_text(json.dumps(dict(steps=steps, receipt_count=len(receipts), mode='isolated human-classification simulation; real UI events', external_systems=[]), indent=2))
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)


def test_browser_hidden_tab_does_not_claim_reviews(tmp_path):
    playwright = pytest.importorskip('playwright.sync_api')
    source, _ = fixture(tmp_path)
    store = tmp_path / 'receipts.sqlite3'
    review = module.Review(source, store, 'dev')
    process = subprocess.Popen([str(ROOT / 'bin/acceptance-review'), str(source), '--store', str(store), '--environment', 'dev', '--port', '0'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    artifacts = Path(os.environ.get('HARNESS_STANDALONE_EVIDENCE', str(tmp_path / 'captures')))
    artifacts.mkdir(parents=True, exist_ok=True)
    try:
        url = process.stdout.readline().strip().removeprefix('Review: ')
        with playwright.sync_playwright() as pw:
            browser = pw.firefox.launch(headless=False)
            context = browser.new_context(viewport={'width': 1280, 'height': 720})
            context.add_init_script("Object.defineProperty(navigator, 'webdriver', {get: () => false})")
            page = context.new_page()
            page.goto(url)
            page.get_by_role('link', name='Portable review').click()
            playwright.expect(page.locator('[data-review-target] > [data-review-count]')).to_contain_text('1 cumulative reads', timeout=10000)
            # Require real visibility; never fake the browser-owned property.
            other = context.new_page()
            other.set_content('<h1>Another task is in the foreground</h1>')
            page.bring_to_front()
            page.get_by_role('link', name='Inspect evidence').click()
            other.bring_to_front()
            if page.evaluate('document.hidden') is not True:
                pytest.skip('This browser/Xvfb combination keeps both pages visible; real background-tab evaluation is unavailable')
            other.wait_for_timeout(1200)
            target = review.resolve(dict(run_id='portable-run', scenario_id='inspect'))
            assert review.summary(target)['reads'] == 0
            capture_page(other, artifacts, 'READ-HIDDEN-01')
            page.bring_to_front()
            playwright.expect(page.locator('[data-review-target] > [data-review-count]')).to_contain_text('1 cumulative reads', timeout=10000)
            assert review.summary(target)['reads'] == 1
            capture_page(page, artifacts, 'READ-HIDDEN-02')
            browser.close()
        (artifacts / 'measurement-boundaries.json').write_text(json.dumps(dict(hidden_tab_before_threshold=0, visible_after_return=1, browser_mode='headed Firefox under Xvfb', external_systems=[]), indent=2))
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)


def test_browser_blocked_session_storage_preserves_evidence(tmp_path):
    playwright = pytest.importorskip('playwright.sync_api')
    source, _ = fixture(tmp_path)
    process = subprocess.Popen([str(ROOT / 'bin/acceptance-review'), str(source), '--store', str(tmp_path / 'receipts.sqlite3'), '--environment', 'dev', '--port', '0'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    artifacts = Path(os.environ.get('HARNESS_STANDALONE_EVIDENCE', str(tmp_path / 'captures')))
    artifacts.mkdir(parents=True, exist_ok=True)
    try:
        url = process.stdout.readline().strip().removeprefix('Review: ')
        with playwright.sync_playwright() as pw:
            browser = pw.chromium.launch()
            context = browser.new_context()
            context.add_init_script("Object.defineProperty(window, 'sessionStorage', {get: () => {throw new Error('disabled')}})")
            page = context.new_page()
            errors = []
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.goto(url)
            capture_page(page, artifacts, 'STORAGE-01')
            page.get_by_role('link', name='Portable review').click()
            playwright.expect(page.get_by_role('heading', name='Portable review')).to_be_visible()
            playwright.expect(page.locator('[data-review-count]')).to_contain_text('browser session storage unavailable')
            capture_page(page, artifacts, 'STORAGE-02')
            page.get_by_role('link', name='Inspect evidence').click()
            playwright.expect(page.get_by_role('heading', name='First outcome')).to_be_visible()
            playwright.expect(page.locator('#step-first > [data-review-count]')).to_contain_text('browser session storage unavailable')
            capture_page(page, artifacts, 'STORAGE-03')
            assert errors == []
            browser.close()
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
