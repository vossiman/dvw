import time
import pytest
from tests.test_resolver import FakeContainer, _inspector


def container(**changes):
    report = dict(schema=1, ts=int(time.time()), partial=False, agents=[],
                  activity=dict(tmux_sessions=0, terminals=0, cursor_connections=0,
                                vscode_connections=0, t3_servers=0))
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


def test_tmux_unmeasured_reason_becomes_the_note(monkeypatch):
    c = container(activity=dict(tmux_sessions=None, terminals=0, cursor_connections=0,
                                vscode_connections=0, tmux_unmeasured='list-sessions-timeout'))
    s, = _inspector([c], monkeypatch).activity_many(['w'])
    assert s.note == 'tmux unmeasured: list-sessions-timeout'
    assert 'tmux_unmeasured' not in s.signals and s.signals['tmux_sessions'] is None


def test_partial_note_outranks_tmux_unmeasured(monkeypatch):
    c = container(partial=True, activity=dict(tmux_sessions=None, tmux_unmeasured='proc-unreadable'))
    s, = _inspector([c], monkeypatch).activity_many(['w'])
    assert s.note == 'partial probe report'


@pytest.mark.parametrize('reason', ['Bad Reason', 'x' * 49, 7, '../etc', ''])
def test_malformed_tmux_unmeasured_is_dropped_not_fatal(monkeypatch, reason):
    c = container(activity=dict(tmux_sessions=0, terminals=0, cursor_connections=0,
                                vscode_connections=0, tmux_unmeasured=reason))
    s, = _inspector([c], monkeypatch).activity_many(['w'])
    assert s.note is None and s.signals['terminals'] == 0


def test_fresh_sample_bypasses_the_snapshot_cache(monkeypatch):
    import app.docker_inspect as di
    from app.config import Settings
    c = container()
    monkeypatch.setattr(di.docker, "DockerClient",
                        lambda base_url=None, timeout=None: __import__(
                            'tests.test_resolver', fromlist=['FakeClient']).FakeClient([c]))
    insp = di.DockerInspector(Settings(docker_host="unix:/nonexistent", probe_snapshot_ttl=60))
    insp.activity_many(['w'])
    insp.activity_many(['w'])
    assert len(c.exec_calls) == 1                      # second call was cached
    insp.activity_many(['w'], fresh=True)
    assert len(c.exec_calls) == 2


class FakeApi:
    def __init__(self):
        self.calls = []
        self.error = None
        self.inspect = {"State": {"Status": "running", "StartedAt": "s1"}}

    def stop(self, cid, timeout=None):
        self.calls.append((cid, timeout))
        if self.error:
            raise self.error

    def inspect_container(self, cid):
        if self.error:
            raise self.error
        return self.inspect


def _with_api(monkeypatch):
    from types import SimpleNamespace
    insp = _inspector([], monkeypatch)
    api = FakeApi()
    insp._client = SimpleNamespace(api=api)
    return insp, api


def test_stop_container_calls_docker_with_the_grace(monkeypatch):
    insp, api = _with_api(monkeypatch)
    insp.stop_container('c' * 64, 10)
    assert api.calls == [('c' * 64, 10)]


def test_stop_container_maps_an_api_error_to_refused(monkeypatch):
    import docker.errors
    from app.stopper import StopRefused
    insp, api = _with_api(monkeypatch)
    api.error = docker.errors.APIError('boom')
    with pytest.raises(StopRefused):
        insp.stop_container('c' * 64, 10)


def test_stop_container_maps_a_transport_error_to_uncertain(monkeypatch):
    import requests
    from app.stopper import StopUncertain
    insp, api = _with_api(monkeypatch)
    api.error = requests.exceptions.ReadTimeout('slow')
    with pytest.raises(StopUncertain):
        insp.stop_container('c' * 64, 10)


def test_container_state_reports_status_and_start(monkeypatch):
    import docker.errors
    insp, api = _with_api(monkeypatch)
    assert insp.container_state('c') == ('running', 's1')
    api.error = docker.errors.NotFound('gone')
    assert insp.container_state('c') is None
    api.error = RuntimeError('down')
    with pytest.raises(RuntimeError):
        insp.container_state('c')
