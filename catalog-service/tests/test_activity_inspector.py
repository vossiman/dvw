import time
import pytest
from tests.test_resolver import FakeContainer, _inspector


def container(**changes):
    report = dict(schema=1, ts=int(time.time()), partial=False, agents=[],
                  activity=dict(tmux_sessions=0, terminals=0, cursor_connections=0, vscode_connections=0))
    report.update(changes)
    c = FakeContainer('c', 'n', 'u', '/workspaces/w', probe=report)
    c.attrs['State']['StartedAt'] = '2026-09-09T01:00:00Z'
    return c


def test_collects_single_fresh_probe(monkeypatch):
    c = container()
    s, = _inspector([c], monkeypatch).activity_many(['w'])
    assert s.running is True and s.signals['terminals'] == 0 and s.signals['agents'] == 0
    assert c.exec_calls == [['dvw-probe']]


@pytest.mark.parametrize('changes', [{'activity': None}, {'ts': 1}, {'partial': True}, {'agents': None}])
def test_incomplete_evidence_cannot_be_idle(monkeypatch, changes):
    from app.activity import ActivityObserver
    from app.models import Workspace
    o = ActivityObserver()
    w = Workspace(id='w', repo='r', branch='main')
    o.update([w], _inspector([container(**changes)], monkeypatch).activity_many(['w']))
    assert o.views([w])[0].state == 'unknown'


def test_duplicate_running_containers_unknown_without_guessing(monkeypatch):
    c, d = container(), container()
    d.id = 'd'
    s, = _inspector([c, d], monkeypatch).activity_many(['w'])
    assert s.running is None and s.signals == {}
    assert not c.exec_calls and not d.exec_calls


def test_stopped_and_absent(monkeypatch):
    c = container()
    c.status = 'exited'
    rows = _inspector([c], monkeypatch).activity_many(['w', 'absent'])
    assert all(s.running is False for s in rows)
    assert c.exec_calls == []


def test_hostile_counts_rejected(monkeypatch):
    c = container(activity=dict(tmux_sessions=-1))
    assert _inspector([c], monkeypatch).activity_many(['w'])[0].signals == {}


@pytest.mark.parametrize('changes, note', [
    ({'partial': True}, 'partial probe report'),
    ({'activity': None}, 'probe reports no activity block'),
    ({'ts': 1}, 'probe report out of time window'),
])
def test_discarded_evidence_names_its_reason(monkeypatch, changes, note):
    s, = _inspector([container(**changes)], monkeypatch).activity_many(['w'])
    assert s.note == note


def test_duplicate_running_containers_name_the_reason(monkeypatch):
    c, d = container(), container()
    d.id = 'd'
    s, = _inspector([c, d], monkeypatch).activity_many(['w'])
    assert s.note == '2 running containers'
