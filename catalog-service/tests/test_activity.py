from app.activity import ActivityObserver, ActivitySample
from app.models import Workspace


def ws(**kw):
    return Workspace(id='w', repo='r', branch='main', **kw)


def sample(**kw):
    values = dict(workspace_id='w', container_id='c', started_at='start',
                  running=True, signals=dict(tmux_sessions=0, terminals=0,
                  cursor_connections=0, vscode_connections=0, agents=0))
    values.update(kw)
    return ActivitySample(**values)


def tick(observer, seconds, samples=None, workspace=None):
    observer.update([workspace or ws()], samples if samples is not None else [sample()],
                    now=seconds, wall=10000 + seconds)
    return observer.views([workspace or ws()], now=seconds)[0]


def test_idle_expires_without_stop_action_and_uses_monotonic_time():
    o = ActivityObserver()
    first = tick(o, 0)
    assert first.state == 'idle' and first.remaining_seconds == 3600
    for t in range(30, 3601, 30):
        result = tick(o, t)
    assert result.remaining_seconds == 0
    assert result.idle_since == 10000
    assert result.observation_only is True


def test_active_resets_countdown_and_includes_all_reasons():
    o = ActivityObserver()
    tick(o, 0)
    active = sample(signals=dict(tmux_sessions=1, terminals=1,
                               cursor_connections=2, vscode_connections=1, agents=1))
    r = tick(o, 30, [active])
    assert r.state == 'active'
    assert set(r.reasons) == {'tmux', 'terminal', 'cursor', 'vscode', 'agent'}
    assert r.idle_since is None
    assert tick(o, 60).remaining_seconds == 3600


def test_unknown_missing_partial_and_gaps_never_accrue_idle_credit():
    o = ActivityObserver()
    tick(o, 0)
    assert tick(o, 30, [sample(signals={})]).state == 'unknown'
    assert tick(o, 60).remaining_seconds == 3600
    assert tick(o, 200).remaining_seconds == 3600
    assert o.views([ws()], now=300)[0].state == 'unknown'
    assert tick(o, 310).remaining_seconds == 3600
    assert tick(o, 320, []).state == 'unknown'


def test_restart_and_identity_change_reset_countdown():
    o = ActivityObserver()
    tick(o, 0)
    assert tick(o, 30, [sample(started_at='new')]).remaining_seconds == 3600
    assert tick(o, 60, [sample(container_id='other')]).remaining_seconds == 3600
    assert tick(o, 90, [sample(running=False)]).state == 'stopped'
    assert tick(o, 120).remaining_seconds == 3600


def test_policy_override_and_deleted_workspace():
    o = ActivityObserver()
    assert tick(o, 0, workspace=ws(always_on=True)).state == 'always-on'
    r = tick(o, 30, workspace=ws(idle_timeout_minutes=30))
    assert r.remaining_seconds == 1800
    o.update([], [], now=60, wall=10060)
    assert o.views([], now=60) == []
    assert tick(o, 90).remaining_seconds == 3600


def test_positive_evidence_preserved_when_other_signals_unknown():
    o = ActivityObserver()
    r = tick(o, 0, [sample(signals={'tmux_sessions': 1})])
    assert r.state == 'active' and r.reasons == ['tmux']


def test_partial_empty_sample_is_unknown():
    assert tick(ActivityObserver(), 0, [sample(complete=False)]).state == 'unknown'


def test_workspace_policy_validation(client):
    client.post('/v1/workspaces', json={'id': 'w', 'repo': 'r', 'branch': 'main'})
    r = client.patch('/v1/workspaces/w', json={'always_on': True, 'idle_timeout_minutes': 30})
    assert r.status_code == 200 and r.json()['always_on'] is True
    for value in [0, -1, None, True, '60', 10081]:
        assert client.patch('/v1/workspaces/w', json={'idle_timeout_minutes': value}).status_code == 422


def test_activity_api_reads_shared_cache_without_probing(client, store):
    from app.deps import get_activity_observer
    o = ActivityObserver()
    client.app.dependency_overrides[get_activity_observer] = lambda: o
    client.post('/v1/workspaces', json={'id': 'w', 'repo': 'r', 'branch': 'main'})
    assert client.get('/v1/containers/activity').json()[0]['state'] == 'unknown'
    o.update(store.list_workspaces(), [sample()])
    first = client.get('/v1/containers/activity').json()[0]
    second = client.get('/v1/containers/activity').json()[0]
    assert first == second and first['state'] == 'idle'
    client.patch('/v1/workspaces/w', json={'always_on': True})
    assert client.get('/v1/containers/activity').json()[0]['state'] == 'always-on'


async def test_background_observer_runs_without_client_and_cancels():
    import asyncio
    class Store:
        def list_workspaces(self): return [ws()]
    class Inspector:
        def activity_many(self, ids): return [sample()]
    o = ActivityObserver()
    task = asyncio.create_task(o.run(Store(), Inspector(), interval=0.01))
    for _ in range(100):
        if o.views([ws()])[0].state == 'idle': break
        await asyncio.sleep(0.01)
    task.cancel()
    try: await task
    except asyncio.CancelledError: pass
    assert o.views([ws()])[0].state == 'idle'


async def test_failed_background_pass_clears_idle():
    import asyncio
    class Store:
        def list_workspaces(self): return [ws()]
    class Inspector:
        def activity_many(self, ids): raise RuntimeError('unavailable')
    o = ActivityObserver()
    o.update([ws()], [sample()])
    task = asyncio.create_task(o.run(Store(), Inspector(), interval=0.01))
    for _ in range(100):
        if o.views([ws()])[0].state == 'unknown': break
        await asyncio.sleep(0.01)
    task.cancel()
    try: await task
    except asyncio.CancelledError: pass
    assert o.views([ws()])[0].state == 'unknown'


def test_lifespan_starts_and_stops_observer(monkeypatch, settings):
    from fastapi.testclient import TestClient
    import app.main as main
    import asyncio
    events = []
    class Observer(ActivityObserver):
        async def run(self, store, inspector):
            events.append('started')
            try: await asyncio.Event().wait()
            finally: events.append('stopped')
    monkeypatch.setattr(main, 'get_settings', lambda: settings)
    monkeypatch.setattr(main, 'DockerInspector', lambda _: object())
    monkeypatch.setattr(main, 'ActivityObserver', Observer)
    with TestClient(main.create_app()) as c:
        assert c.get('/v1/containers/activity').json() == []
        assert events == ['started']
    assert events == ['started', 'stopped']


def test_slow_batch_does_not_retimestamp_old_sample_as_fresh():
    o = ActivityObserver()
    s = sample(sampled_at=1)
    assert tick(o, 100, [s]).state == 'unknown'


def test_delayed_sample_expires_from_collection_not_batch_completion():
    o = ActivityObserver()
    r = tick(o, 50, [sample(sampled_at=1)])
    assert r.state == 'idle' and r.observed_at == 10001
    assert o.views([ws()], now=92)[0].state == 'unknown'


def test_state_change_is_logged_once_and_names_the_reason(caplog):
    o = ActivityObserver()
    with caplog.at_level('INFO', logger='app.activity'):
        tick(o, 0)
        tick(o, 30)
        tick(o, 60, samples=[sample(signals=dict(tmux_sessions=0, terminals=1,
                                                 cursor_connections=0,
                                                 vscode_connections=0, agents=0))])
    lines = [r.getMessage() for r in caplog.records]
    assert len(lines) == 2, lines
    assert lines[0].startswith('activity w: new -> idle')
    assert 'idle -> active (terminal)' in lines[1]
    assert 'terminals=1' in lines[1]


def test_discard_reason_is_logged_and_clears_the_countdown(caplog):
    o = ActivityObserver()
    tick(o, 0)
    tick(o, 30)
    with caplog.at_level('INFO', logger='app.activity'):
        tick(o, 60, samples=[sample(complete=False, note='partial probe report')])
        result = tick(o, 90)
    lines = [r.getMessage() for r in caplog.records]
    assert 'idle -> unknown' in lines[0] and 'partial probe report' in lines[0]
    assert 'unknown -> idle' in lines[1]
    assert result.idle_seconds == 0


def test_silent_countdown_reset_is_logged_even_though_the_state_is_unchanged(caplog):
    """A restarted container stays 'idle' but loses its accumulated time."""
    o = ActivityObserver()
    tick(o, 0)
    tick(o, 30)
    with caplog.at_level('INFO', logger='app.activity'):
        result = tick(o, 60, samples=[sample(started_at='restarted')])
    lines = [r.getMessage() for r in caplog.records]
    assert lines == ['activity w: idle countdown reset [agents=0, cursor_connections=0, '
                     'terminals=0, tmux_sessions=0, vscode_connections=0]']
    assert result.state == 'idle' and result.idle_seconds == 0
