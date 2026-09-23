from pathlib import Path
import json
import runpy
import pytest

GATE = runpy.run_path(str(Path(__file__).parents[2] / 'priv/preview/acceptance_gate.py'), run_name='gate_test')


def test_artifact_gate_rejects_incomplete_or_failed_delivery(tmp_path):
    status, report = tmp_path / 'status.env', tmp_path / 'e2e.md'
    status.write_text('ATDD_TEST_EXIT_CODE=0\n')
    report.write_text('| 1 | ✅ passed | A |\n| 2 | 🟠 ignored | B |\n| 3 | ⬛ skipped | C |\n')
    assert GATE['check'](status, report) == []
    status.write_text('ATDD_TEST_EXIT_CODE=2\n')
    assert GATE['check'](status, report)
    status.write_text('ATDD_TEST_EXIT_CODE=0\n')
    for text in ['# Empty report', '| 1 | ⚪ not run | A |', '| 1 | ✅ | A |\n## Test Failures', '| 1 | ✅ | A |\n## ⏳ Scenario: unfinished']:
        report.write_text(text)
        assert GATE['check'](status, report)


def test_required_manifest_cannot_be_satisfied_by_missing_or_duplicated_scenarios(tmp_path):
    evidence, manifest = tmp_path / 'evidence.json', tmp_path / 'manifest.json'
    manifest.write_text(json.dumps({'all_ids': ['first', 'second']}))
    data = {'scenarios': [{'id': 'first', 'status': 'success'}]}
    evidence.write_text(json.dumps(data))
    assert GATE['check_manifest'](evidence, manifest) == ['missing required scenario: second']
    data['scenarios'].append({'id': 'second', 'status': 'skipped', 'status_reason': 'Device unavailable'})
    evidence.write_text(json.dumps(data))
    assert GATE['check_manifest'](evidence, manifest) == []
    data['pending_steps'] = [{'id': 'unfinished'}]
    evidence.write_text(json.dumps(data))
    assert GATE['check_manifest'](evidence, manifest)
    data['scenarios'][1] = {'id': 'second', 'status': 'ignored', 'status_reason': 'Known product gap'}
    data['pending_steps'] = [{'id': 'unfinished', 'scenario_id': 'second'}]
    evidence.write_text(json.dumps(data))
    assert GATE['check_manifest'](evidence, manifest) == []
    data['scenarios'].append(data['scenarios'][0])
    evidence.write_text(json.dumps(data))
    with pytest.raises(ValueError, match='duplicate'):
        GATE['check_manifest'](evidence, manifest)
