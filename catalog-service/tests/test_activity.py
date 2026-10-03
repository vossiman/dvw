from app.activity import ActivityObserver, ActivitySample
from app.models import Workspace


def ws(**kw):
    return Workspace(id='w', repo='r', branch='main', **kw)


def sample(**kw):
    values = dict(workspace_id='w', container_id='c', started_at='start',
                  running=True, signals=dict(tmux_sessions=0, terminals=0,
                  cursor_connections=0, vscode_connections=0, agents=0,
                  t3_servers=0))
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
                               cursor_connections=2, vscode_connections=1, agents=1,
                               t3_servers=0))
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


def test_discard_reason_is_logged_and_one_discard_keeps_earned_credit(caplog):
    o = ActivityObserver()
    tick(o, 0)
    tick(o, 30)
    with caplog.at_level('INFO', logger='app.activity'):
        tick(o, 60, samples=[sample(complete=False, note='partial probe report')])
        result = tick(o, 90)
    lines = [r.getMessage() for r in caplog.records]
    assert 'idle -> unknown' in lines[0] and 'partial probe report' in lines[0]
    assert 'unknown -> idle' in lines[1]
    assert result.idle_seconds == 30


def test_silent_countdown_reset_is_logged_even_though_the_state_is_unchanged(caplog):
    """A restarted container stays 'idle' but loses its accumulated time."""
    o = ActivityObserver()
    tick(o, 0)
    tick(o, 30)
    with caplog.at_level('INFO', logger='app.activity'):
        result = tick(o, 60, samples=[sample(started_at='restarted')])
    lines = [r.getMessage() for r in caplog.records]
    assert lines == ['activity w: idle countdown reset [agents=0, cursor_connections=0, '
                     't3_servers=0, terminals=0, tmux_sessions=0, vscode_connections=0]']
    assert result.state == 'idle' and result.idle_seconds == 0


def test_one_unknown_sample_keeps_earned_idle_credit_without_crediting_the_gap():
    o = ActivityObserver()
    for t in range(0, 601, 30):
        tick(o, t)
    assert tick(o, 630, [sample(signals={}, note='partial probe report')]).state == 'unknown'
    resumed = tick(o, 660)
    # 600s earned before the gap; 600..660 was not observed idle, so not credited.
    assert resumed.state == 'idle' and resumed.idle_seconds == 600
    assert resumed.idle_since == 10000
    assert tick(o, 690).idle_seconds == 630


def test_two_unknown_samples_in_a_row_still_reset():
    o = ActivityObserver()
    for t in range(0, 601, 30):
        tick(o, t)
    tick(o, 630, [sample(signals={})])
    tick(o, 660, [sample(signals={})])
    assert tick(o, 690).idle_seconds == 0


def test_unknown_carry_needs_the_same_container():
    o = ActivityObserver()
    for t in range(0, 601, 30):
        tick(o, t)
    tick(o, 630, [sample(signals={}, started_at='restarted')])
    assert tick(o, 660).idle_seconds == 0


def test_unknown_carry_is_dropped_by_active_stopped_or_missing_samples():
    busy = sample(signals=dict(tmux_sessions=1, terminals=0, cursor_connections=0,
                               vscode_connections=0, agents=0))
    for interrupt in ([busy], [sample(running=False)], []):
        o = ActivityObserver()
        for t in range(0, 601, 30):
            tick(o, t)
        tick(o, 630, [sample(signals={})])
        tick(o, 660, interrupt)
        assert tick(o, 690).idle_seconds == 0


def test_unknown_without_container_identity_never_carries():
    o = ActivityObserver()
    for t in range(0, 601, 30):
        tick(o, t)
    tick(o, 630, [sample(container_id=None, started_at=None, running=None, signals={},
                         note='2 running containers')])
    assert tick(o, 660).idle_seconds == 0


def signals(**kw):
    base = dict(tmux_sessions=0, terminals=0, cursor_connections=0,
                vscode_connections=0, agents=0, t3_servers=0)
    base.update(kw)
    return base


def mature(observer, workspace=None):
    """Earn a full timeout of idle credit, ending at t=3600."""
    for t in range(0, 3601, 30):
        result = tick(observer, t, workspace=workspace)
    assert result.remaining_seconds == 0
    return result


def test_t3_server_makes_the_workspace_always_on_with_reason():
    o = ActivityObserver()
    r = tick(o, 0, [sample(signals=signals(t3_servers=1))])
    assert r.state == 'always-on' and r.reasons == ['t3']
    assert r.signals['t3_servers'] == 1
    assert r.idle_seconds is None


def test_t3_appearing_clears_earned_credit():
    o = ActivityObserver()
    mature(o)
    tick(o, 3630, [sample(signals=signals(t3_servers=1))])
    assert tick(o, 3660).remaining_seconds == 3600


def test_missing_t3_signal_is_unknown():
    o = ActivityObserver()
    old_probe = dict(tmux_sessions=0, terminals=0, cursor_connections=0,
                     vscode_connections=0, agents=0)
    assert tick(o, 0, [sample(signals=old_probe)]).state == 'unknown'
    assert tick(o, 30, [sample(signals=signals(t3_servers=None))]).state == 'unknown'


def test_stored_always_on_wins_over_t3():
    o = ActivityObserver()
    w = ws(always_on=True)
    r = tick(o, 0, [sample(signals=signals(t3_servers=1))], workspace=w)
    assert r.state == 'always-on' and r.reasons == []


def test_update_one_leaves_other_workspaces_untouched():
    o = ActivityObserver()
    a = Workspace(id='a', repo='r', branch='main')
    b = Workspace(id='b', repo='r', branch='main')
    for t in range(0, 601, 30):
        o.update([a, b], [sample(workspace_id='a'), sample(workspace_id='b')],
                 now=t, wall=10000 + t)
    o.update_one(a, sample(workspace_id='a', signals=signals(agents=1)),
                 now=610, wall=10610)
    va, vb = o.views([a, b], now=610)
    assert va.state == 'active'
    assert vb.state == 'idle' and vb.idle_seconds == 600


def test_reset_starts_a_new_countdown():
    o = ActivityObserver()
    mature(o)
    o.reset('w')
    assert o.credit('w') is None
    assert tick(o, 3630).remaining_seconds == 3600


def test_credit_identifies_the_countdown():
    o = ActivityObserver()
    tick(o, 0)
    first = o.credit('w')
    tick(o, 30)
    assert o.credit('w') == first                      # same countdown
    tick(o, 60, [sample(signals=signals(agents=1))])
    assert o.credit('w') is None                       # not idle
    tick(o, 90)
    assert o.credit('w') != first                      # a new countdown


def test_observation_only_reflects_the_enforce_switch():
    assert tick(ActivityObserver(), 0).observation_only is True
    assert tick(ActivityObserver(enforce=True), 0).observation_only is False
    # the fallback view for an unobserved workspace carries it too
    assert ActivityObserver(enforce=True).views([ws()], now=0)[0].observation_only is False


def test_record_stop_is_served_and_logged(tmp_path):
    from app.activity_history import ActivityHistory
    h = ActivityHistory(tmp_path / 'h.jsonl')
    o = ActivityObserver(history=h)
    mature(o)
    o.record_stop('w', 'stopped', at=13600.0, idle_seconds=3600)
    view = o.views([ws()], now=3600)[0]
    assert view.stop.result == 'stopped' and view.stop.at == 13600.0
    assert view.stop.idle_seconds == 3600
    events = [e for e in h.tail(50, 'w') if e.event == 'stop']
    assert len(events) == 1 and events[0].idle_seconds == 3600
    o.record_stop('w', 'failed', at=13700.0, idle_seconds=3600, note='docker: 500')
    assert o.views([ws()], now=3600)[0].stop.result == 'failed'
    assert [e.event for e in h.tail(50, 'w')][-1] == 'stop-failed'
