#!/usr/bin/env python3
"""Portable evidence review with SQLite receipts and the shared browser observer."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import html
import http.server
import json
from pathlib import Path
import re
import runpy
import sqlite3
import tempfile
import threading
from types import SimpleNamespace
from urllib.parse import parse_qs, quote, unquote, urlsplit

PACKAGE = Path(__file__).resolve().parents[1]
PREVIEW = runpy.run_path(str(PACKAGE / 'preview/linux/live-preview'), run_name='preview_library')
FIELDS = ('id', 'project', 'target', 'revision', 'environment', 'run_id', 'source', 'viewed_at')


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


class Review:
    def __init__(self, manifest, store, environment):
        self.manifest = Path(manifest).resolve()
        self.root = self.manifest.parent
        self.store = Path(store).resolve()
        if self.store == self.root or self.root in self.store.parents:
            raise ValueError('Keep the receipt database outside the served evidence directory')
        self.environment = environment
        self.store.parent.mkdir(parents=True, exist_ok=True)
        with self.connection() as db:
            db.execute('CREATE TABLE IF NOT EXISTS receipts (project TEXT NOT NULL, id TEXT NOT NULL, target TEXT NOT NULL, revision TEXT NOT NULL, receipt TEXT NOT NULL, PRIMARY KEY(project,id))')
            db.execute('CREATE INDEX IF NOT EXISTS review_target ON receipts(project,target,revision)')
        self.data()  # Fail early for an invalid manifest.

    def connection(self):
        return sqlite3.connect(self.store, timeout=5)

    def data(self):
        data = json.loads(self.manifest.read_text())
        if not data.get('run', {}).get('id') or not data.get('app', {}).get('name'):
            raise ValueError('Evidence requires stable run.id and app.name')
        return data

    def asset(self, name):
        path = (self.root / name).resolve()
        if self.root not in path.parents or any(p.startswith('.') for p in Path(name).parts) or not path.is_file():
            raise ValueError('Unknown evidence asset')
        return path

    def step_content(self, step, run_id):
        screenshot = step.get('screenshot') or {}
        metadata = step.get('metadata') or {}
        image = None
        if screenshot.get('name'):
            try:
                image = hashlib.sha256(self.asset('screenshots/' + screenshot['name']).read_bytes()).hexdigest().upper()
            except (ValueError, OSError):
                image = ['unavailable', run_id]
        return [step.get('title', 'Step'), step.get('description', ''),
                (step.get('page') or {}).get('html') or metadata.get('page_html'),
                step.get('surface', {'kind': 'browser'}), image,
                metadata.get('source_checksum'), metadata.get('source_sha256')]

    def resolve(self, params):
        data = self.data()
        run_id = data['run']['id']
        if params.get('run_id') != run_id:
            raise ValueError('Unknown run')
        scenario_id, step_id = params.get('scenario_id'), params.get('step_id')
        target = {'project': data['app']['name'], 'run_id': run_id}
        if scenario_id:
            scenario = next(s for s in data['scenarios'] if s['id'] == scenario_id)
            steps = sorted(scenario.get('steps', []), key=lambda s: (s.get('sequence') or 0, s.get('title', '')))
            if step_id:
                step = next(s for s in steps if s['id'] == step_id)
                stable = (step.get('metadata') or {}).get('review_id') or (step.get('screenshot') or {}).get('name') or step['id']
                target.update(target=f'step/{scenario_id}/{stable}', revision=fingerprint(self.step_content(step, run_id)))
            else:
                target.update(target=f'scenario/{scenario_id}', revision=fingerprint([scenario['title'], [self.step_content(s, run_id) for s in steps]]))
        elif step_id:
            raise ValueError('Step requires scenario')
        else:
            commit = data['app'].get('commit')
            target.update(target='run/' + (commit or run_id), revision=fingerprint([commit, data.get('title')]))
        return target

    def import_receipts(self, receipts):
        project = self.data()['app']['name']
        safe = []
        for receipt in receipts:
            if not isinstance(receipt, dict) or any(not isinstance(receipt.get(k), str) or not 1 <= len(receipt[k].encode()) <= 512 for k in FIELDS):
                raise ValueError('Invalid receipt')
            if receipt['project'] != project or receipt['source'] not in ('human', 'automated', 'unattributed') or not re.fullmatch('[a-f0-9]{64}', receipt['id']):
                raise ValueError('Invalid or cross-project receipt')
            timestamp = datetime.fromisoformat(receipt['viewed_at'].replace('Z', '+00:00'))
            if timestamp.tzinfo is None:
                raise ValueError('Receipt requires timezone')
            safe.append({k: receipt[k] for k in FIELDS})
        with self.connection() as db:
            before = db.total_changes
            db.executemany('INSERT OR IGNORE INTO receipts VALUES (?,?,?,?,?)', [(r['project'], r['id'], r['target'], r['revision'], json.dumps(r)) for r in safe])
            return db.total_changes - before

    def export(self):
        with self.connection() as db:
            return [json.loads(row[0]) for row in db.execute('SELECT receipt FROM receipts WHERE project=? ORDER BY id', (self.data()['app']['name'],))]

    def summary(self, target):
        with self.connection() as db:
            rows = [json.loads(row[0]) for row in db.execute('SELECT receipt FROM receipts WHERE project=? AND target=?', (target['project'], target['target']))]
        human = [r for r in rows if r['source'] == 'human']
        current = [r for r in human if r['revision'] == target['revision']]
        return dict(reads=len(current), historical_reads=len(human), environments=dict(Counter(r['environment'] for r in current)), automated=sum(r['source'] == 'automated' for r in rows), state='reviewed' if current else 'changed_unreviewed' if human else 'no_recorded_review')

    def record(self, params):
        target = self.resolve(params)
        session = params.get('session')
        if not isinstance(session, str) or not 16 <= len(session.encode()) <= 128:
            raise ValueError('Invalid review session')
        receipt = dict(target, environment=self.environment, source=params.get('source') if params.get('source') in ('human', 'automated') else 'unattributed', viewed_at=datetime.now(timezone.utc).isoformat())
        receipt['id'] = fingerprint([session, target['project'], target['target'], target['revision']])
        self.import_receipts([receipt])
        return self.summary(target)

    def page(self, scenario_id, token):
        data = self.data()
        esc = html.escape
        rid = esc(data['run']['id'], quote=True)
        scope = f'data-review-run="{rid}" data-review-endpoint="/review-activity"'
        if scenario_id is None:
            body = '<h1>Review runs</h1><p>Local evidence · portable review</p><a href="/review/run">' + esc(data.get('title') or 'Open evidence run') + '</a>'
        elif scenario_id == '':
            body = f'<section {scope}><header data-review-target="run"><h1>{esc(data.get("title") or "Evidence run")}</h1></header><h2>Scenarios</h2><ul>'
            body += ''.join(f'<li><a href="/review/scenarios/{quote(s["id"], safe="")}">{esc(s["title"])}</a></li>' for s in data['scenarios']) + '</ul></section>'
        else:
            scenario = next(s for s in data['scenarios'] if s['id'] == scenario_id)
            body = f'<main {scope} data-review-scenario="{esc(scenario_id, quote=True)}"><a href="/review/run">Run</a><header data-review-target="scenario"><h1>{esc(scenario["title"])}</h1></header>'
            for step in sorted(scenario.get('steps', []), key=lambda s: (s.get('sequence') or 0, s.get('title', ''))):
                sid = esc(step['id'], quote=True)
                body += f'<article class="acceptance-step" id="step-{sid}" data-acceptance-step-id="{sid}"><h2>{esc(step.get("title", "Step"))}</h2><p>{esc(step.get("description") or "")}</p>'
                name = (step.get('screenshot') or {}).get('name')
                if name:
                    url = '/assets/screenshots/' + quote(name, safe='')
                    body += f'<a class="acceptance-screenshot-link" href="{url}"><img src="{url}" alt="{esc(step.get("title", "Step"), quote=True)}"></a>'
                else:
                    text = (step.get('surface') or {}).get('text') or (step.get('page') or {}).get('text') or 'No image captured for this step.'
                    body += '<pre class="acceptance-terminal-evidence">' + esc(text) + '</pre>'
                body += '</article>'
            body += '</main>'
        return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta name="csrf-token" content="' + token + '"><title>Harness evidence review</title><style>body{font:16px system-ui;margin:0 auto;max-width:1100px;padding:24px;background:#edf0ec;color:#19343b}a{color:#096577}header,article,section{background:white;padding:20px;margin:16px 0;border:1px solid #c9d5d2;border-radius:10px}h1{font-size:26px}h2{font-size:20px}img{max-width:100%;height:auto}pre{white-space:pre-wrap}.acceptance-review-count{padding:10px;background:#eaf3ee;color:#096577;border-left:3px solid #298467}</style></head><body><nav><a href="/">Review runs</a></nav>' + body + '<p>Visibility is not approval. History before collection is unknown. Receipt exchange is explicit; this store is not automatically synchronized.</p><script src="/review-activity.js"></script></body></html>'


def handler(review, preview):
    base = PREVIEW['make_handler'](preview)
    class Handler(base):
        def reply(self, code, data, kind='application/json'):
            data = (json.dumps(data) if kind == 'application/json' else data).encode()
            self.send_response(code)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            parsed = urlsplit(self.path)
            try:
                if parsed.path == '/review-activity':
                    params = {k: v[-1] for k, v in parse_qs(parsed.query).items()}
                    return self.reply(200, review.summary(review.resolve(params)))
                if parsed.path == '/review-activity.js':
                    return self.reply(200, (PACKAGE / 'acceptance_harness/review_activity.js').read_text(), 'text/javascript')
                if parsed.path.startswith('/assets/'):
                    # The existing preview handler enforces the served-root boundary.
                    self.path = '/' + parsed.path.removeprefix('/assets/')
                    return super().do_GET()
                if parsed.path in ('/', '/index.html', '/review/run') or parsed.path.startswith('/review/scenarios/'):
                    scenario = None if parsed.path in ('/', '/index.html') else '' if parsed.path == '/review/run' else unquote(parsed.path.removeprefix('/review/scenarios/'))
                    return self.reply(200, preview.decorate(review.page(scenario, preview.shutdown_token), revision=hashlib.sha256(review.manifest.read_bytes()).hexdigest()), 'text/html; charset=utf-8')
                return super().do_GET()
            except (ValueError, KeyError, StopIteration):
                self.reply(422, {'error': 'Invalid review target'})
            except (OSError, sqlite3.Error):
                self.reply(503, {'error': 'Review tracking incomplete'})

        def do_POST(self):
            if self.path != '/review-activity':
                return super().do_POST()
            if self.headers.get('x-csrf-token') != preview.shutdown_token:
                return self.reply(403, {'error': 'Invalid review token'})
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 8192:
                    raise ValueError('Invalid event size')
                self.reply(200, review.record(json.loads(self.rfile.read(size))))
            except (ValueError, KeyError, TypeError, StopIteration):
                self.reply(422, {'error': 'Invalid review event'})
            except (OSError, sqlite3.Error):
                self.reply(503, {'error': 'Review tracking incomplete'})
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', action='version', version=PREVIEW['VERSION'])
    parser.add_argument('manifest', type=Path)
    parser.add_argument('--store', required=True, type=Path, help='SQLite path outside the served evidence directory')
    parser.add_argument('--environment', required=True)
    parser.add_argument('--bind', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8767)
    parser.add_argument('--import-receipts', type=Path)
    parser.add_argument('--export-receipts', type=Path)
    args = parser.parse_args()
    review = Review(args.manifest, args.store, args.environment)
    if args.import_receipts:
        print(f'Imported {review.import_receipts(json.loads(args.import_receipts.read_text()))} receipts')
    if args.export_receipts:
        args.export_receipts.write_text(json.dumps(review.export(), indent=2) + '\n')
        return
    with tempfile.TemporaryDirectory(prefix='acceptance-review-') as temporary:
        preview = PREVIEW['Preview'](SimpleNamespace(source=str(review.manifest), output=None, serve_root=str(review.root), css=None, source_label=None, fallback_title='Harness review', path_boundary_regex='tmp', mode='html', ready=temporary+'/ready', pidfile=temporary+'/pid', idle_timeout=86400, startup_timeout=86400))
        preview.refresh()
        watcher = threading.Thread(target=PREVIEW['watch'], args=(preview,), daemon=True)
        watcher.start()
        server = http.server.ThreadingHTTPServer((args.bind, args.port), handler(review, preview))
        server.daemon_threads = True
        print(f'Review: http://{args.bind}:{server.server_port}/', flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            preview.shutdown_requested.set()
            server.server_close()


if __name__ == '__main__':
    main()
