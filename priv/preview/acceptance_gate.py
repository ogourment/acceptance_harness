#!/usr/bin/env python3
"""Validate retained acceptance artifacts without Elixir or compilation."""
import argparse
import json
from pathlib import Path
import re
import sys


def check(status_path, report_path):
    errors = []
    try:
        status = Path(status_path).read_text()
        values = [line.split('=', 1)[1].strip() for line in status.splitlines() if '=' in line and line.split('=', 1)[0].strip() == 'ATDD_TEST_EXIT_CODE']
        value = values[0] if values else ''
        if not re.fullmatch(r'[0-9]+', value):
            errors.append('ATDD_TEST_EXIT_CODE is missing or invalid')
        elif value != '0':
            errors.append('ATDD_TEST_EXIT_CODE=' + value)
    except OSError:
        errors.append('missing status file: ' + str(status_path))
    try:
        report = Path(report_path).read_text()
        rows = [line for line in report.splitlines() if re.match(r'^\|\s*[0-9]+\s*\|', line)]
        if not rows:
            errors.append('evidence report has no scenario summary rows')
        for row in rows:
            parts = [p.strip() for p in row.split('|') if p]
            if len(parts) >= 2 and not any(mark in parts[1] for mark in ('✅', '🟠', '⬛')):
                errors.append(f'scenario {parts[0]} status {parts[1]}')
        if '## Test Failures' in report:
            errors.append('evidence report contains a Test Failures section')
        if any(heading in report for heading in ('## ❌ Scenario:', '## ⚪ Scenario:', '## ⏳ Scenario:')):
            errors.append('evidence report contains failed, missing, or running scenario sections')
    except OSError:
        errors.append('missing evidence report: ' + str(report_path))
    return errors


def check_manifest(evidence_path, manifest_path):
    evidence = json.loads(Path(evidence_path).read_text())
    manifest = json.loads(Path(manifest_path).read_text())
    required = manifest.get('all_ids')
    if not isinstance(required, list) or not required or any(not isinstance(id, str) or not id for id in required) or len(set(required)) != len(required):
        raise ValueError('Manifest requires unique, non-empty all_ids')
    scenarios = evidence.get('scenarios', [])
    ids = [s['id'] for s in scenarios]
    if len(set(ids)) != len(ids):
        raise ValueError('Evidence contains duplicate scenario IDs')
    by_id = {s['id']: s for s in scenarios}
    errors = []
    for id in required:
        scenario = by_id.get(id)
        if scenario is None:
            errors.append('missing required scenario: ' + id)
        elif scenario.get('status') == 'success':
            pass
        elif scenario.get('status') in ('ignored', 'skipped') and isinstance(scenario.get('status_reason'), str) and scenario['status_reason'].strip():
            pass
        else:
            errors.append('required scenario has no accepted terminal outcome: ' + id)
    for pending in evidence.get('pending_steps', []):
        owner = by_id.get(pending.get('scenario_id'), {})
        if owner.get('status') not in ('ignored', 'skipped') or not owner.get('status_reason', '').strip():
            errors.append('evidence contains an undeclared pending expectation')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('status', nargs='?', default='tmp/atdd/status.env')
    parser.add_argument('report', nargs='?', default='tmp/atdd/e2e.md')
    parser.add_argument('--evidence')
    parser.add_argument('--manifest')
    args = parser.parse_args()
    if bool(args.evidence) != bool(args.manifest):
        parser.error('--evidence and --manifest must be supplied together')
    try:
        errors = check(args.status, args.report)
        if args.manifest:
            errors += check_manifest(args.evidence, args.manifest)
    except (OSError, ValueError, KeyError, TypeError) as error:
        errors = ['invalid gate artifacts: ' + str(error)]
    if errors:
        print('ATDD gate failed:\n' + '\n'.join(errors), file=sys.stderr)
        return 1
    print('ATDD artifact gate passed')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
